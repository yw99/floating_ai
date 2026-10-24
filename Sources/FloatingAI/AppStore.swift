import AppKit
import Combine
import FloatingAICore
import UniformTypeIdentifiers

struct CodexCLILocator {
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    func localInstallation() -> URL? {
        let candidates = [homeDirectory.appendingPathComponent(".local/bin/codex").path,
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] +
            searchPath.split(separator: ":").map { "\($0)/codex" }
                .filter { !$0.contains(".app/Contents/") }
        return firstExecutable(in: candidates)
    }

    func resolve(savedPath: String) -> URL? {
        if !savedPath.isEmpty {
            let path = NSString(string: savedPath).expandingTildeInPath
            return firstExecutable(in: [path])
        }
        return localInstallation() ?? firstExecutable(in: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path
        ])
    }

    private func firstExecutable(in candidates: [String]) -> URL? {
        // Keep stable symlink paths so future CLI upgrades are picked up on reconnect.
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

@MainActor final class AppStore: ObservableObject {
    @Published var notes: [NoteState] = []
    @Published var models: [CodexModel] = []
    @Published var claudeModels: [CodexModel] = []
    @Published var claudeCLIPath = ""
    @Published var claudeEnabled = true
    @Published var claudeConnectionStatus = "Not connected to Claude"
    @Published var claudeIsConnected = false
    @Published var claudeIsLoggedIn = false
    @Published var claudeIsConnecting = false
    @Published var claudeError: String?
    @Published var requestedNoteID: UUID?
    @Published var connectionStatus = "Not connected to Codex"
    @Published var isConnected = false
    @Published var isLoggedIn = false
    @Published var isConnecting = false
    @Published private(set) var authenticationMode: AuthenticationMode = .codexSignIn
    @Published private(set) var accountKind: CodexAccountKind = .none
    @Published private(set) var hasSavedAPIKey = false
    @Published private(set) var isUpdatingAuthentication = false
    @Published private(set) var isDeletingNotes = false
    @Published private(set) var noteDeletionSummary: String?
    @Published private var activeTurnRequests = 0
    @Published private var claudeActiveTurnRequests = 0
    @Published var error: String?
    @Published var cliPath = ""
    @Published var defaultModelID = ""
    @Published var defaultProvider: ChatProvider = .codex
    @Published var defaultEffort = ""
    @Published var keepNotesExpanded = false {
        didSet { scheduleSave() }
    }
    @Published var keyboardShortcuts = KeyboardShortcutSettings() {
        didSet { scheduleSave() }
    }
    @Published var recentNoteIDs: [UUID] = [] {
        didSet { scheduleSave() }
    }
    @Published var shortcutError: String?
    @Published var openNoteShortcutError: String?
    @Published var openNoteShortcutActive = false
    @Published var isRecordingShortcut = false
    // The application installs native registration; offline stores never register keys.
    var configureKeyboardShortcuts: ((KeyboardShortcutSettings) throws -> Void)?
    var disableGlobalShortcut: (() -> Void)?
    var retryGlobalShortcut: (() throws -> Void)?
    @Published var inactiveNoteOpacity = 0.6 {
        didSet {
            let normalized = AppDocument.normalizedInactiveNoteOpacity(inactiveNoteOpacity)
            if inactiveNoteOpacity != normalized { inactiveNoteOpacity = normalized }
            scheduleSave()
        }
    }

    private let client: CodexClient
    private let claudeClient: ClaudeClient
    private let apiKeyStore: any APIKeyStore
    private let cliLocator: CodexCLILocator
    private let persistence: NotePersistence
    private let fileToolURL: URL
    private var importingNotes: [UUID: Int] = [:]
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var attachmentStore: AttachmentStore { AttachmentStore(directory: persistence.directory) }
    private var noteSubscriptions: [UUID: Set<AnyCancellable>] = [:]
    private var saveTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var claudeEventTask: Task<Void, Never>?
    private var claudeConnectionTask: Task<Void, Never>?
    private var claudeConnectionRevision = UUID()
    private var connectionTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var connectionRevision = UUID()
    private var resumedThreadIDs: Set<String> = []
    private var completedTurnIDs: Set<String> = []
    private var activeNoteRequests: [UUID: Int] = [:]
    private var batchDeletionTask: Task<Void, Never>?
    private var canPersist = true
    private var shuttingDown = false
    private var loginInProgress = false

    var canChangeAuthentication: Bool {
        !isConnecting && !isUpdatingAuthentication && !shuttingDown && activeTurnRequests == 0 && !notes.contains(where: { $0.provider == .codex && ($0.isBusy || $0.isDeleting) })
    }

    var canChangeClaudeConnection: Bool {
        !claudeIsConnecting && !shuttingDown && claudeActiveTurnRequests == 0 && !notes.contains(where: { $0.provider == .claude && ($0.isBusy || $0.isDeleting) })
    }

    var mergedModels: [ChatModel] {
        (isConnected && isLoggedIn ? models.map { ChatModel(provider: .codex, model: $0) } : []) +
        (claudeIsConnected && claudeIsLoggedIn ? claudeModels.map { ChatModel(provider: .claude, model: $0) } : [])
    }
    var defaultModelSelectionID: String { ChatModel.selectionID(provider: defaultProvider, modelID: defaultModelID) }
    var hasConnectedProvider: Bool { isReady(provider: .codex) || isReady(provider: .claude) }
    func isReady(for note: NoteState) -> Bool { isReady(provider: note.provider) }
    private func isReady(provider: ChatProvider) -> Bool {
        guard !shuttingDown else { return false }
        return provider == .codex ? isConnected && isLoggedIn && !isConnecting && !isUpdatingAuthentication :
            claudeEnabled && claudeIsConnected && claudeIsLoggedIn && !claudeIsConnecting
    }
    func connectionStatus(for note: NoteState) -> String {
        note.provider == .codex ? connectionStatus : claudeConnectionStatus
    }
    func model(for note: NoteState) -> ChatModel? { mergedModels.first { $0.id == note.modelSelectionID } }

    init(directory: URL? = nil, apiKeyStore: any APIKeyStore = KeychainAPIKeyStore(),
         client: CodexClient = CodexClient(),
         claudeClient: ClaudeClient = ClaudeClient(),
         cliLocator: CodexCLILocator = CodexCLILocator(),
         previewAuthentication: (mode: AuthenticationMode, hasSavedAPIKey: Bool)? = nil,
         fileToolURL: URL? = nil) {
        self.client = client
        self.claudeClient = claudeClient
        self.apiKeyStore = apiKeyStore
        self.cliLocator = cliLocator
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatingAI", isDirectory: true)
        persistence = NotePersistence(directory: root)
        self.fileToolURL = fileToolURL ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("FloatingAIFileTool")
        do {
            let document = try persistence.load()
            authenticationMode = document.authenticationMode ?? .codexSignIn
            cliPath = document.cliPath
            claudeCLIPath = document.claudeCLIPath ?? ""
            claudeEnabled = document.claudeEnabled ?? true
            defaultModelID = document.defaultModelID
            defaultProvider = document.defaultProvider ?? .codex
            defaultEffort = document.defaultEffort
            inactiveNoteOpacity = AppDocument.normalizedInactiveNoteOpacity(document.inactiveNoteOpacity)
            keepNotesExpanded = document.keepNotesExpanded ?? false
            keyboardShortcuts = document.keyboardShortcuts ?? KeyboardShortcutSettings()
            let savedNoteIDs = Set(document.notes.map(\.id))
            var seenRecentIDs = Set<UUID>()
            recentNoteIDs = (document.recentNoteIDs ?? []).filter {
                savedNoteIDs.contains($0) && seenRecentIDs.insert($0).inserted
            }
            notes = document.notes.map { stored in
                let note = NoteState(id: stored.id, title: stored.title, model: stored.model, effort: stored.effort,
                                     provider: stored.provider ?? .codex)
                note.threadID = stored.threadID
                note.activeTurnID = stored.activeTurnID
                note.draft = stored.draft
                note.attachments = stored.attachments
                note.fileLibrary = stored.fileLibrary ?? []
                note.hasImages = stored.hasImages
                note.hasFiles = stored.hasFiles ?? false
                note.retainedImagePaths = Set(stored.referencedImagePaths ?? [])
                note.imageReferencesKnown = stored.referencedImagePaths != nil || !stored.hasImages
                note.deletionPending = stored.deletionPending ?? false
                note.isVisible = stored.isVisible
                note.compactX = stored.compactX
                note.compactY = stored.compactY
                note.compactWidth = StoredNote.normalizedCompactWidth(stored.compactWidth)
                note.compactHeight = StoredNote.normalizedCompactHeight(stored.compactHeight)
                note.expandedWidth = stored.expandedWidth
                note.expandedHeight = stored.expandedHeight
                note.composerHeight = StoredNote.normalizedComposerHeight(stored.composerHeight)
                note.displayID = stored.displayID
                note.pendingSubmission = stored.pendingSubmission
                note.needsReconciliation = stored.needsReconciliation ?? (stored.activeTurnID != nil || stored.pendingSubmission != nil)
                if stored.activeTurnID != nil || stored.pendingSubmission != nil {
                    note.error = "The previous session ended unexpectedly. Reconnecting will check the history without resending messages."
                }
                if note.deletionPending {
                    note.error = "Deletion was not completed. Reconnect if needed, then delete this note again to finish removing its history."
                }
                return note
            }
            for note in notes { recoverFileLibrary(note) }
            notes.forEach(observe)
        } catch {
            canPersist = false
            self.error = "Could not load notes. The original file has been preserved: \(error.localizedDescription)"
        }
        // Rendering previews never reads the user's Keychain or starts Codex.
        if let previewAuthentication {
            authenticationMode = previewAuthentication.mode
            hasSavedAPIKey = previewAuthentication.hasSavedAPIKey
        }
        eventTask = Task { [weak self, client] in
            for await event in client.events {
                guard !Task.isCancelled else { return }
                self?.handle(event, provider: .codex)
            }
        }
        claudeEventTask = Task { [weak self, claudeClient] in
            for await event in claudeClient.events {
                guard !Task.isCancelled else { return }
                self?.handle(event, provider: .claude)
            }
        }
    }

    func connectAll() {
        connect()
        if claudeEnabled { connectClaude() }
    }

    func connect() {
        guard canChangeAuthentication else { return }
        isConnecting = true
        resetConnectionState()
        error = nil
        connectionStatus = "Connecting to Codex…"
        persist()
        connectionTask = Task { [weak self] in
            await self?.performConnection()
        }
    }

    private func performConnection() async {
        defer { isConnecting = false }
        // Even a missing/unreadable key must terminate the previous authenticated
        // child rather than leave it usable under a different billing mode.
        await client.disconnect()
        do {
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            let authentication: CodexAuthentication
            if authenticationMode == .openAIAPIKey {
                let keyStore = apiKeyStore
                let key = try await Task.detached { try keyStore.read() }.value
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    hasSavedAPIKey = false
                    connectionStatus = "API key not configured"
                    error = "Add your OpenAI API key in Settings to connect."
                    return
                }
                hasSavedAPIKey = true
                authentication = .apiKey(key)
            } else {
                authentication = .codexSignIn
            }
            guard let executable = resolveCLI() else {
                throw AppError.message("Codex CLI was not found. Install it or choose the codex executable in Settings.")
            }
            let work = persistence.directory.appendingPathComponent("Chat", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let info = try await client.connect(executableURL: executable, workingDirectory: work, authentication: authentication)
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            cliPath = executable.path
            models = info.models
            accountKind = info.accountKind
            isConnected = true
            isLoggedIn = info.isLoggedIn
            switch info.accountKind {
            case .chatGPT: connectionStatus = "Connected · ChatGPT · Codex \(info.version)"
            case .apiKey: connectionStatus = "API key configured · Codex \(info.version)"
            case .none: connectionStatus = "Connected to Codex. Choose a sign-in method in Settings."
            case .unsupported: connectionStatus = "The current Codex account type is not supported."
            }
            applyDefaults()
            if isLoggedIn { await restoreConversations(provider: .codex) }
            for note in notes where note.provider == .codex && note.error == nil { validateSelection(note) }
            if isLoggedIn && models.isEmpty { error = "Codex returned no available models. Refresh Models or check your account access." }
            persist()
        } catch {
            await client.disconnect()
            guard !shuttingDown else { return }
            isConnected = false
            isLoggedIn = false
            accountKind = .none
            connectionStatus = "Connection failed"
            self.error = requestFailureDescription(error.localizedDescription)
        }
    }

    func selectAuthenticationMode(_ mode: AuthenticationMode) {
        guard canChangeAuthentication, mode != authenticationMode else { return }
        authenticationMode = mode
        persist()
        connect()
    }

    func saveAPIKey(_ rawKey: String) {
        guard canChangeAuthentication, authenticationMode == .openAIAPIKey else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            error = "Enter an OpenAI API key without spaces or line breaks."
            return
        }
        isUpdatingAuthentication = true
        resetConnectionState()
        error = nil
        connectionStatus = "Saving API key to Keychain…"
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            await client.disconnect()
            let keyStore = apiKeyStore
            do {
                try Task.checkCancellation()
                try await Task.detached { try keyStore.save(key) }.value
                try Task.checkCancellation()
                guard !shuttingDown else { isUpdatingAuthentication = false; return }
                hasSavedAPIKey = true
                isUpdatingAuthentication = false
                connect()
            } catch {
                isUpdatingAuthentication = false
                guard !shuttingDown else { return }
                connectionStatus = "Could not save API key"
                // A storage backend must not echo its credential in user-facing errors.
                self.error = error.localizedDescription.replacingOccurrences(of: key, with: "[REDACTED]")
            }
        }
    }

    func removeAPIKey() {
        guard canChangeAuthentication, authenticationMode == .openAIAPIKey else { return }
        isUpdatingAuthentication = true
        resetConnectionState()
        error = nil
        connectionStatus = "Removing API key…"
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { isUpdatingAuthentication = false }
            // No account/logout: terminating the ephemeral child only affects us.
            await client.disconnect()
            let keyStore = apiKeyStore
            do {
                try Task.checkCancellation()
                try await Task.detached { try keyStore.delete() }.value
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                hasSavedAPIKey = false
                connectionStatus = "API key removed. Add a key to connect."
                persist()
            } catch {
                guard !shuttingDown else { return }
                connectionStatus = "Could not remove API key"
                self.error = error.localizedDescription
            }
        }
    }

    private func resetConnectionState() {
        connectionRevision = UUID()
        isConnected = false
        isLoggedIn = false
        accountKind = .none
        models = []
        clearRoutingState(provider: .codex)
        loginInProgress = false
    }

    private func clearRoutingState(provider: ChatProvider) {
        let prefix = provider.rawValue + ":"
        resumedThreadIDs = resumedThreadIDs.filter { !$0.hasPrefix(prefix) }
        completedTurnIDs = completedTurnIDs.filter { !$0.hasPrefix(prefix) }
    }

    private func routingKey(_ id: String, provider: ChatProvider) -> String { provider.rawValue + ":" + id }

    func connectClaude() {
        guard canChangeClaudeConnection else { return }
        claudeEnabled = true
        claudeIsConnecting = true
        claudeIsConnected = false
        claudeIsLoggedIn = false
        claudeModels = []
        claudeError = nil
        claudeConnectionStatus = "Connecting to Claude…"
        claudeConnectionRevision = UUID()
        clearRoutingState(provider: .claude)
        persist()
        claudeConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer { claudeIsConnecting = false }
            await claudeClient.disconnect()
            do {
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                guard let executable = resolveClaudeCLI() else {
                    throw AppError.message("Claude Code CLI was not found. Install it or choose the claude executable in Settings.")
                }
                let work = persistence.directory.appendingPathComponent("ClaudeChat", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let info = try await claudeClient.connect(executableURL: executable, workingDirectory: work)
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                claudeCLIPath = executable.path
                claudeModels = info.models
                claudeIsConnected = true
                claudeIsLoggedIn = info.isLoggedIn
                claudeConnectionStatus = info.isLoggedIn ? "Connected · \(info.accountDescription) · Claude \(info.version)" :
                    "Claude is not signed in. Sign in, then reconnect."
                applyDefaults()
                if info.isLoggedIn { await restoreConversations(provider: .claude) }
                if info.isLoggedIn && info.models.isEmpty { claudeError = "Claude returned no available models. Reconnect or check your account access." }
                persist()
            } catch {
                await claudeClient.disconnect()
                guard !shuttingDown else { return }
                claudeIsConnected = false
                claudeIsLoggedIn = false
                claudeModels = []
                claudeConnectionStatus = "Claude connection failed"
                claudeError = error.localizedDescription
            }
        }
    }

    func disconnectClaude() {
        guard canChangeClaudeConnection else { return }
        claudeEnabled = false
        claudeIsConnecting = true
        claudeConnectionRevision = UUID()
        claudeIsConnected = false
        claudeIsLoggedIn = false
        claudeModels = []
        claudeError = nil
        claudeConnectionStatus = "Claude disconnected"
        clearRoutingState(provider: .claude)
        persist()
        claudeConnectionTask = Task { [weak self] in
            guard let self else { return }
            await claudeClient.disconnect()
            claudeIsConnecting = false
        }
    }

    private func resolveClaudeCLI(useSavedPath: Bool = true) -> URL? {
        if useSavedPath && !claudeCLIPath.isEmpty {
            let path = NSString(string: claudeCLIPath).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func useLocalClaudeCLI() {
        guard canChangeClaudeConnection else { return }
        guard let executable = resolveClaudeCLI(useSavedPath: false) else {
            claudeError = "No local Claude Code CLI was found. Install Claude Code or choose its executable."; return
        }
        claudeCLIPath = executable.path
        connectClaude()
    }

    func chooseClaudeCLI() {
        guard canChangeClaudeConnection else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Claude Code CLI Executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            guard canChangeClaudeConnection else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                claudeError = "The selected file is not executable."; return
            }
            claudeCLIPath = url.path
            connectClaude()
        }
    }

    func loginClaude() {
        guard canChangeClaudeConnection else { return }
        guard let executable = resolveClaudeCLI() else {
            claudeError = "Choose or install the Claude Code CLI before signing in."; return
        }
        do {
            // The user initiates the official interactive CLI flow in Terminal.
            // The script contains only an executable path, never credentials.
            let script = persistence.directory.appendingPathComponent("ClaudeSignIn.command")
            let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try FileManager.default.createDirectory(at: persistence.directory, withIntermediateDirectories: true)
            try ("#!/bin/sh\nexec " + quoted + " auth login\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.claudeError = error.localizedDescription } }
            }
            claudeConnectionStatus = "Complete Claude sign-in in Terminal, then click Reconnect."
        } catch { claudeError = error.localizedDescription }
    }

    func refreshAllModels() {
        refreshModels()
        if claudeEnabled && canChangeClaudeConnection { connectClaude() }
    }

    func refreshModels() {
        guard !isUpdatingAuthentication else { return }
        guard isConnected, !isConnecting else { connect(); return }
        let revision = connectionRevision
        Task {
            do {
                let refreshed = try await client.refreshModels()
                guard connectionRevision == revision, !shuttingDown else { return }
                models = refreshed
                applyDefaults()
                for note in notes where note.provider == .codex { validateSelection(note) }
            } catch {
                guard connectionRevision == revision, !shuttingDown else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func login() {
        guard authenticationMode == .codexSignIn, canChangeAuthentication, isConnected, !loginInProgress else { return }
        loginInProgress = true
        let revision = connectionRevision
        Task {
            do {
                let url = try await client.login()
                guard connectionRevision == revision, !shuttingDown else { return }
                NSWorkspace.shared.open(url)
                connectionStatus = "Complete ChatGPT sign-in in your browser"
            } catch {
                guard connectionRevision == revision, !shuttingDown else { return }
                loginInProgress = false
                self.error = error.localizedDescription
            }
        }
    }

    func chooseCLI() {
        guard canChangeAuthentication else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex CLI Executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            guard canChangeAuthentication else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                error = "The selected file is not executable. Choose your installed codex executable."; return
            }
            cliPath = url.path
            persist()
            connect()
        }
    }

    func useLocalCLI() {
        guard canChangeAuthentication else { return }
        guard let executable = cliLocator.localInstallation() else {
            error = "No local Codex CLI was found. Install Codex or choose its executable in Settings. Your current path has been kept."
            return
        }
        cliPath = executable.path
        persist()
        connect()
    }

    func createNote(title: String, model: String, effort: String) -> NoteState {
        let selected = mergedModels.first { $0.id == model }
        // Native Codex IDs remain accepted for older callers and persisted defaults.
        let qualifiedProvider = ChatProvider.allCases.first { model.hasPrefix($0.rawValue + ":") }
        let provider = selected?.provider ?? qualifiedProvider ?? .codex
        let nativeID = selected?.nativeID ?? qualifiedProvider.map { String(model.dropFirst($0.rawValue.count + 1)) } ?? model
        return createNote(title: title, nativeModel: nativeID, effort: effort, provider: provider)
    }

    private func createNote(title: String, nativeModel nativeID: String, effort: String, provider: ChatProvider) -> NoteState {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = NoteState(title: cleanTitle.isEmpty ? "Ask Me Anything" : cleanTitle, model: nativeID, effort: effort, provider: provider)
        notes.append(note)
        observe(note)
        defaultProvider = provider
        defaultModelID = nativeID
        defaultEffort = effort
        persist()
        return note
    }

    func availableModels(for note: NoteState) -> [ChatModel] {
        let needsImages = note.hasImages || note.attachments.contains(where: \.isImage)
        return mergedModels.filter { !needsImages || $0.supportsImages }
    }

    func selectModel(_ modelID: String, for note: NoteState) {
        guard !note.isBusy, !note.isDeleting, !note.deletionPending, note.pendingSubmission == nil, !note.needsReconciliation,
              let model = availableModels(for: note).first(where: { $0.id == modelID || ($0.provider == .codex && $0.nativeID == modelID) }) else { return }
        if note.provider != model.provider && (note.threadID != nil || !note.messages.isEmpty) {
            let alert = NSAlert()
            alert.messageText = "Start a new note with \(model.displayName)?"
            alert.informativeText = "Copy History includes the conversation, draft, and independent copies of its attachments for review before sending. Start Fresh opens an empty note. Your original note keeps its model and history."
            alert.addButton(withTitle: "Copy History")
            alert.addButton(withTitle: "Start Fresh")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
            guard !note.isDeleting, !note.deletionPending, notes.contains(where: { $0.id == note.id }) else { return }
            let copy = copyConversation(note, to: model, includeHistory: response == .alertFirstButtonReturn)
            requestedNoteID = copy.id
            return
        }
        note.provider = model.provider
        note.model = model.nativeID
        if !model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == note.effort }) {
            note.effort = model.defaultReasoningEffort
        }
        note.error = nil
        defaultProvider = model.provider
        defaultModelID = model.nativeID
        defaultEffort = note.effort
        persist()
    }

    /// Creates a separate note, optionally copying context into its draft.
    /// Never reuses the original thread ID or sends a message automatically.
    @discardableResult func copyConversation(_ note: NoteState, to model: ChatModel, includeHistory: Bool = true) -> NoteState {
        // The selected backend may disconnect while the confirmation is open.
        // Keep the captured identity instead of resolving a now-missing menu item.
        let copy = createNote(title: note.title, nativeModel: model.nativeID, effort: model.defaultReasoningEffort, provider: model.provider)
        guard includeHistory else { return copy }
        let history = note.messages.map { "\($0.role == "user" ? "User" : "Assistant"):\n\($0.text)" }.joined(separator: "\n\n")
        copy.draft = history.isEmpty ? note.draft : "Previous conversation copied from \(note.provider.displayName):\n\n\(history)\n\n" +
            (note.draft.isEmpty ? "Continue this conversation." : note.draft)
        var paths: Set<String> = []
        let files = (note.attachments + note.messages.flatMap(\.fileAttachments) + note.messages.flatMap { $0.imagePaths }.map {
            Attachment(id: UUID(), path: $0, name: URL(fileURLWithPath: $0).lastPathComponent)
        }).filter { paths.insert($0.path).inserted }
        // Explicit Copy History creates new owned files; notes never share paths.
        for file in files where attachmentStore.owns(file, noteID: note.id) {
            do {
                let imported = try attachmentStore.importFile(URL(fileURLWithPath: file.path), noteID: copy.id,
                    name: file.name, kind: file.isImage ? .image : .file)
                copy.attachments.append(imported); copy.fileLibrary.append(imported)
            } catch { copy.error = "An attachment could not be copied: \(error.localizedDescription)" }
        }
        if copy.attachments.count > 20 {
            copy.attachments = Array(copy.attachments.prefix(20))
            copy.error = "The first 20 files were added to this message. The remaining copies are available in Note Files."
        }
        persist()
        return copy
    }

    func canDeleteNote(_ note: NoteState) -> Bool {
        guard !shuttingDown, !isDeletingNotes, canPersist, notes.contains(where: { $0 === note }),
              !note.isBusy, !note.isImportingFiles, !note.isDeleting, activeNoteRequests[note.id] == nil else { return false }
        return note.provider == .codex ? !isConnecting && !isUpdatingAuthentication : !claudeIsConnecting
    }

    func deletionUnavailableReason(for selected: [NoteState]) -> String? {
        guard !selected.isEmpty else { return "Select notes to delete." }
        guard !shuttingDown else { return "Floating AI is quitting." }
        guard !selected.contains(where: { $0.isImportingFiles }) else { return "Wait for files to finish importing." }
        guard canPersist else { return "Notes could not be loaded. Resolve the storage error before deleting." }
        guard !isDeletingNotes, !selected.contains(where: { $0.isDeleting }) else { return "Deletion is in progress." }
        guard selected.allSatisfy({ candidate in notes.contains(where: { $0 === candidate }) }) else {
            return "Some selected notes are no longer available. Select them again."
        }
        guard !selected.contains(where: { $0.isBusy || activeNoteRequests[$0.id] != nil }) else {
            return "Stop the selected notes and wait for their requests to finish before deleting."
        }
        guard selected.allSatisfy({ $0.provider == .codex ? !isConnecting && !isUpdatingAuthentication : !claudeIsConnecting }) else {
            return "Wait for the selected accounts to finish connecting or updating before deleting."
        }
        return nil
    }

    func requestDeleteNote(_ note: NoteState) { requestDeleteNotes([note]) }

    func requestDeleteNotes(_ candidates: [NoteState]) {
        let selected = uniqueNotes(candidates)
        guard batchDeletionTask == nil, deletionUnavailableReason(for: selected) == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if selected.count == 1, let note = selected.first {
            alert.messageText = "Delete “\(note.title)” permanently?"
            alert.informativeText = "This deletes the note, its draft, its attached files, and its saved \(note.provider.displayName) conversation history on this Mac. This cannot be undone."
        } else {
            alert.messageText = "Delete \(selected.count) notes permanently?"
            let names = selected.prefix(6).map { "• " + String($0.title.prefix(80)) }.joined(separator: "\n")
            let more = selected.count > 6 ? "\n…and \(selected.count - 6) more." : ""
            alert.informativeText = "This deletes the selected notes, their drafts, attached files, and saved Codex / Claude conversation histories on this Mac. This cannot be undone.\n\n" + names + more
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: selected.count == 1 ? "Delete Note" : "Delete \(selected.count) Notes")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn, deletionUnavailableReason(for: selected) == nil else { return }
        batchDeletionTask = Task { [weak self] in
            guard let self else { return }
            await deleteNotes(selected)
            batchDeletionTask = nil
        }
    }

    private func uniqueNotes(_ candidates: [NoteState]) -> [NoteState] {
        var seen: Set<UUID> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// Confirmation covers the selected snapshot once. Reserve all targets before
    /// yielding, so a queued note cannot start sending while an earlier one deletes.
    /// Each note keeps its own durable journal and error if only part of a batch succeeds.
    func deleteNotes(_ candidates: [NoteState]) async {
        let selected = uniqueNotes(candidates)
        if let reason = deletionUnavailableReason(for: selected) { noteDeletionSummary = reason; return }
        isDeletingNotes = true
        noteDeletionSummary = nil
        for note in selected { note.isDeleting = true }
        defer {
            for note in selected { note.isDeleting = false }
            isDeletingNotes = false
        }
        for note in selected {
            guard !shuttingDown, !Task.isCancelled else { break }
            await performDeleteNote(note)
        }
        let remaining = selected.filter { candidate in notes.contains(where: { $0 === candidate }) }.count
        let deleted = selected.count - remaining
        let result = "Deleted \(deleted) \(deleted == 1 ? "note" : "notes")."
        noteDeletionSummary = remaining == 0 ? result : result + " \(remaining) \(remaining == 1 ? "note remains" : "notes remain"); review the errors and retry."
    }

    /// Called only after confirmation; the durable marker prevents an interrupted
    /// deletion from resuming or re-sending a conversation on the next launch.
    func deleteNote(_ note: NoteState) async {
        guard canDeleteNote(note) else { return }
        await performDeleteNote(note)
    }

    private func performDeleteNote(_ note: NoteState) async {
        guard !shuttingDown, canPersist, notes.contains(where: { $0 === note }) else { return }
        note.isDeleting = true
        defer { note.isDeleting = false }
        if let id = note.threadID {
            guard !notes.contains(where: { $0.id != note.id && $0.provider == note.provider && $0.threadID == id }) else {
                note.error = "Another note uses this same conversation. Deletion was stopped to preserve that note."
                return
            }
            let connected = note.provider == .codex ? isConnected : claudeIsConnected
            guard connected else {
                note.error = "Reconnect \(note.provider.displayName) in Settings before deleting this note and its conversation history."
                return
            }
        }
        let wasPending = note.deletionPending
        var markerSaved = false
        do {
            note.deletionPending = true
            note.error = nil
            try persistence.save(documentSnapshot())
            markerSaved = true
            if let id = note.threadID {
                switch note.provider {
                case .codex: try await client.deleteThread(id: id)
                case .claude: try await claudeClient.deleteThread(id: id)
                }
            }
            try Task.checkCancellation()
            guard !shuttingDown else { return }
            let remaining = documentSnapshot(excluding: note.id)
            try persistence.removeUnusedAttachments(for: note.id, referencedPaths: note.fileLibrary.map(\.path) + Array(note.retainedImagePaths)
                + note.attachments.map(\.path) + (note.pendingSubmission?.attachments.map(\.path) ?? [])
                + note.messages.flatMap(\.imagePaths), remainingNotes: remaining.notes, ownedAttachments: note.fileLibrary)
            // Commit to disk before removing the visible note. A save failure
            // keeps the deletion marker and a retry entry instead of losing it.
            try persistence.save(remaining)
            if let thread = note.threadID {
                let key = routingKey(thread, provider: note.provider)
                resumedThreadIDs.remove(key)
                completedTurnIDs = completedTurnIDs.filter { !$0.hasPrefix(key + ":") }
            }
            noteSubscriptions.removeValue(forKey: note.id)
            notes.removeAll { $0.id == note.id }
            if requestedNoteID == note.id { requestedNoteID = nil }
        } catch {
            if !markerSaved { note.deletionPending = wasPending }
            note.error = markerSaved
                ? "Deletion did not finish: \(error.localizedDescription)\nThe note has been kept for retry. Some history may already have been removed; no messages will be sent or resumed."
                : "Could not save the deletion request: \(error.localizedDescription)\nThe conversation has not been deleted."
        }
    }

    func selectEffort(_ effort: String, for note: NoteState) {
        guard !note.isBusy, !note.isDeleting, !note.deletionPending, let model = model(for: note),
              model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) else { return }
        note.effort = effort
        note.error = nil
        defaultProvider = note.provider
        defaultModelID = note.model
        defaultEffort = effort
        persist()
    }

    func send(_ note: NoteState) {
        guard !shuttingDown, !note.isBusy, !note.isImportingFiles, !note.isDeleting, !note.deletionPending, notes.contains(where: { $0.id == note.id }) else { return }
        guard canPersist else {
            note.error = "Message was not sent because saving notes is unavailable. Your draft and attachments have been kept."; return
        }
        guard !note.needsReconciliation else {
            note.error = "The previous request has an unknown status. Reconnect in Settings to check the conversation history first."; return
        }
        guard note.pendingSubmission == nil else {
            note.error = "Check the history, then recover or dismiss the previous unconfirmed message."; return
        }
        guard isReady(for: note) else {
            note.error = "Connect and sign in to \(note.provider.displayName) in Settings first."; return
        }
        guard validateSelection(note) else { return }
        guard note.attachments.count <= 20 else { note.error = "Attach up to 20 files per message."; return }
        let text = note.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !note.attachments.isEmpty else { return }
        guard note.attachments.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            note.error = "An attachment file is missing. Remove it and add it again."; return
        }
        guard note.attachments.allSatisfy({ attachmentStore.owns($0, noteID: note.id) }) else {
            note.error = "An attachment does not belong to this note. Remove it and add a new copy."; return
        }
        let fileAccess: FileAccessContext?
        do { fileAccess = try fileAccessContext(for: note) }
        catch { note.error = error.localizedDescription; return }
        let submission = PendingSubmission(text: note.draft, attachments: note.attachments, model: note.model,
                                           effort: note.effort, previousUserMessageID: note.messages.last(where: { $0.role == "user" })?.id)
        let provider = note.provider
        note.pendingSubmission = submission
        note.isBusy = true
        note.isStopping = false
        note.error = nil
        guard persist() else {
            abandonUnsentSubmission(submission, for: note, reason: "Could not save the message.")
            return
        }
        changeActiveRequests(provider: provider, by: 1, noteID: note.id)
        Task {
            defer { changeActiveRequests(provider: provider, by: -1, noteID: note.id) }
            var didDispatch = false
            do {
                try checkSubmissionPreparation()
                let threadID: String
                if let existing = note.threadID {
                    threadID = existing
                    try await configureFileAccess(fileAccess, threadID: existing, provider: provider)
                    try checkSubmissionPreparation()
                    if !resumedThreadIDs.contains(routingKey(existing, provider: provider)) {
                        let response = try await resumeThread(existing, provider: provider)
                        try checkSubmissionPreparation()
                        note.messages = localizedMessages(Transcript.messages(from: response), for: note)
                        note.retainedImagePaths.formUnion(note.messages.flatMap(\.imagePaths))
                        note.imageReferencesKnown = true
                        resumedThreadIDs.insert(routingKey(existing, provider: provider))
                    }
                } else {
                    threadID = try await createThread(model: submission.model, provider: provider, fileAccess: fileAccess)
                    note.threadID = threadID
                    resumedThreadIDs.insert(routingKey(threadID, provider: provider))
                }
                try checkSubmissionPreparation()
                let beforeDispatch: @Sendable () async throws -> Void = { @MainActor in
                    try self.checkSubmissionPreparation()
                    // The adapters call this after their asynchronous model and
                    // session preparation, immediately before sending content.
                    guard self.persist() else { throw SubmissionPreparationError.persistence }
                    try self.checkSubmissionPreparation()
                    let localID = "pending-\(UUID().uuidString)"
                    note.pendingUserMessageID = localID
                    note.messages.append(ChatMessage(id: localID, role: "user", text: submission.text,
                                                     imagePaths: submission.attachments.filter(\.isImage).map(\.path),
                                                     fileAttachments: submission.attachments.filter { !$0.isImage }))
                    didDispatch = true
                }
                let turnID = try await sendSubmission(submission, threadID: threadID, provider: provider,
                                                      beforeDispatch: beforeDispatch)
                guard !shuttingDown else { return }
                // A tiny response can finish before the request's continuation resumes.
                if note.isBusy { note.activeTurnID = turnID }
                if note.pendingSubmission == submission { acceptSubmission(note, submission) }
                persistAfterDispatch(note)
                if note.isStopping && note.isBusy {
                    try await interrupt(threadID: threadID, turnID: turnID, provider: provider)
                }
            } catch {
                if error is SubmissionPreparationError {
                    abandonUnsentSubmission(submission, for: note, reason: "Could not save the conversation.")
                    return
                }
                // After the save callback allows dispatch, the adapters also
                // check cancellation and connection identity. Keep the journal
                // conservatively if that final actor hop fails during shutdown.
                if !didDispatch && (shuttingDown || error is CancellationError) {
                    abandonUnsentSubmission(submission, for: note, reason: "Sending was cancelled before dispatch.")
                    persist()
                    return
                }
                guard !shuttingDown else { return }
                note.isBusy = false
                note.isStopping = false
                if case CodexError.server = error {
                    if let pendingID = note.pendingUserMessageID {
                        note.messages.removeAll { $0.id == pendingID }
                        note.pendingUserMessageID = nil
                    }
                } else { note.needsReconciliation = note.threadID != nil }
                if note.pendingSubmission == submission {
                    note.error = "Could not complete sending: \(requestFailureDescription(error.localizedDescription, provider: provider))\nYour message has been kept. If disconnected, reconnect and check the history before sending again."
                    persist()
                } else {
                    note.error = "The message was accepted, but the request did not finish: \(requestFailureDescription(error.localizedDescription, provider: provider))\nReconnect and check the history before sending again."
                    persistAfterDispatch(note)
                }
            }
        }
    }

    private func checkSubmissionPreparation() throws {
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
    }

    private enum SubmissionPreparationError: Error { case persistence }

    private func abandonUnsentSubmission(_ submission: PendingSubmission, for note: NoteState, reason: String) {
        guard note.pendingSubmission == submission else { return }
        note.pendingSubmission = nil
        note.isBusy = false
        note.isStopping = false
        note.error = "\(reason) Message was not sent. Your draft and attachments have been kept; retry after saving is available."
    }

    private func persistAfterDispatch(_ note: NoteState) {
        if !persist() {
            note.error = "The message was accepted, but its latest state could not be saved. Reconnect to check the conversation history before sending again. No message will be resent automatically."
        }
    }

    func stop(_ note: NoteState) {
        guard note.isBusy, !note.isStopping else { return }
        note.isStopping = true
        guard let threadID = note.threadID, let turnID = note.activeTurnID else { return }
        let provider = note.provider
        changeActiveRequests(provider: provider, by: 1, noteID: note.id)
        Task {
            defer { changeActiveRequests(provider: provider, by: -1, noteID: note.id) }
            do { try await interrupt(threadID: threadID, turnID: turnID, provider: provider) }
            catch {
                guard !shuttingDown else { return }
                note.isStopping = false
                note.error = "Could not stop: \(error.localizedDescription)"
            }
        }
    }

    private func changeActiveRequests(provider: ChatProvider, by delta: Int, noteID: UUID) {
        if provider == .codex { activeTurnRequests += delta }
        else { claudeActiveTurnRequests += delta }
        let count = (activeNoteRequests[noteID] ?? 0) + delta
        if count > 0 { activeNoteRequests[noteID] = count }
        else { activeNoteRequests.removeValue(forKey: noteID) }
    }

    private func createThread(model: String, provider: ChatProvider, fileAccess: FileAccessContext? = nil) async throws -> String {
        switch provider {
        case .codex: return try await client.createThread(model: model, fileAccess: fileAccess)
        case .claude:
            let id = try await claudeClient.createThread(model: model)
            try await claudeClient.configureFileAccess(threadID: id, access: fileAccess)
            return id
        }
    }

    private func resumeThread(_ id: String, provider: ChatProvider) async throws -> JSONValue {
        switch provider {
        case .codex: return try await client.resumeThread(id: id)
        case .claude: return try await claudeClient.resumeThread(id: id)
        }
    }

    private func sendSubmission(_ submission: PendingSubmission, threadID: String, provider: ChatProvider,
                                beforeDispatch: @escaping @Sendable () async throws -> Void) async throws -> String {
        let text = AttachmentMessage.encode(text: submission.text, attachments: submission.attachments)
        let images = submission.attachments.filter(\.isImage).map(\.path)
        switch provider {
        case .codex: return try await client.send(threadID: threadID, text: text,
            imagePaths: images, model: submission.model, effort: submission.effort, beforeDispatch: beforeDispatch)
        case .claude: return try await claudeClient.send(threadID: threadID, text: text,
            imagePaths: images, model: submission.model, effort: submission.effort, beforeDispatch: beforeDispatch)
        }
    }

    private func interrupt(threadID: String, turnID: String, provider: ChatProvider) async throws {
        switch provider {
        case .codex: try await client.interrupt(threadID: threadID, turnID: turnID)
        case .claude: try await claudeClient.interrupt(threadID: threadID, turnID: turnID)
        }
    }

    private func fileAccessContext(for note: NoteState) throws -> FileAccessContext? {
        // Merely keeping an unused document in Note Files must not disable text
        // chat on an older CLI. Once sent, its reader remains available on resume.
        guard note.hasFiles || note.attachments.contains(where: { !$0.isImage }) ||
                note.pendingSubmission?.attachments.contains(where: { !$0.isImage }) == true else { return nil }
        guard FileManager.default.isExecutableFile(atPath: fileToolURL.path) else { throw AttachmentError.unavailable }
        let directory = attachmentStore.noteDirectory(note.id)
        let scratch = persistence.directory.appendingPathComponent("FileScratch").appendingPathComponent(note.id.uuidString)
        try AttachmentStore.rejectLinkedDirectories([directory.deletingLastPathComponent(), directory,
                                                     scratch.deletingLastPathComponent(), scratch])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return FileAccessContext(directory: directory, scratchDirectory: scratch, toolExecutable: fileToolURL)
    }

    private func configureFileAccess(_ access: FileAccessContext?, threadID: String, provider: ChatProvider) async throws {
        switch provider {
        case .codex: try await client.configureFileAccess(threadID: threadID, access: access)
        case .claude: try await claudeClient.configureFileAccess(threadID: threadID, access: access)
        }
    }

    func files(for note: NoteState) -> [Attachment] {
        guard notes.contains(where: { $0 === note }) else { return [] }
        return note.fileLibrary.filter { attachmentStore.owns($0, noteID: note.id) }
    }

    func referenceFiles(_ selected: Set<UUID>, in note: NoteState) {
        guard !note.isDeleting, !note.deletionPending, notes.contains(where: { $0 === note }) else { return }
        let existing = Set(note.attachments.map(\.id))
        let referenced = files(for: note).filter { selected.contains($0.id) && !existing.contains($0.id) }
        guard note.attachments.count + referenced.count <= 20 else { note.error = "Attach up to 20 files per message."; return }
        guard referenced.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            note.error = "An attachment file is missing. Add a new copy using Add Files."; return
        }
        note.attachments.append(contentsOf: referenced)
        note.focusRequest = UUID()
        if isReady(for: note) { validateSelection(note) }
        persist()
    }

    func attachFiles(_ urls: [URL], to note: NoteState) {
        guard !shuttingDown, !note.isDeleting, !note.deletionPending, !urls.isEmpty, notes.contains(where: { $0 === note }) else { return }
        guard urls.count + note.attachments.count <= 20 else { note.error = "Attach up to 20 files per message."; return }
        importingNotes[note.id, default: 0] += 1
        note.isImportingFiles = true
        let storage = attachmentStore, id = note.id
        let operation = UUID()
        importTasks[operation] = Task {
            defer { importTasks.removeValue(forKey: operation) }
            let results = await Task.detached(priority: .userInitiated) { () -> [(Attachment?, String?)] in
                urls.map { url in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let imageType = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                        if imageType {
                            let png = try AttachmentImageCodec.png(AttachmentImageCodec.decode(fileURL: url))
                            return (try storage.storePNG(png, noteID: id, name: url.deletingPathExtension().lastPathComponent + ".png"), nil)
                        }
                        return (try storage.importFile(url, noteID: id), nil)
                    } catch { return (nil, "\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            }.value
            importingNotes[id] = max(0, (importingNotes[id] ?? 1) - 1)
            note.isImportingFiles = importingNotes[id] != 0
            guard notes.contains(where: { $0 === note }), !note.deletionPending else { return }
            let added = results.compactMap { $0.0 }
            note.fileLibrary.append(contentsOf: added)
            note.attachments.append(contentsOf: added.prefix(max(0, 20 - note.attachments.count)))
            let failures = results.compactMap { $0.1 }
            note.error = failures.isEmpty ? nil : failures.joined(separator: "\n")
            note.focusRequest = UUID()
            if failures.isEmpty, isReady(for: note) { validateSelection(note) }
            persist()
        }
    }

    func attachImage(_ image: NSImage, to note: NoteState) {
        storeImage(to: note) { try AttachmentImageCodec.decode(image) }
    }

    func attachImageData(_ data: Data, to note: NoteState) {
        storeImage(to: note) { try AttachmentImageCodec.decode(data) }
    }

    func removeAttachment(_ attachment: Attachment, from note: NoteState) {
        guard !note.isDeleting, !note.deletionPending else { return }
        note.attachments.removeAll { $0.id == attachment.id }
        // Removing from this message keeps the file in this note's library.
        persist()
    }

    func recoverPending(_ note: NoteState) {
        guard !note.isBusy, !note.isDeleting, !note.deletionPending, let pending = note.pendingSubmission else { return }
        if note.draft != pending.text {
            note.draft = note.draft.isEmpty ? pending.text : note.draft + "\n\n" + pending.text
        }
        let existing = Set(note.attachments.map(\.path))
        note.attachments.append(contentsOf: pending.attachments.compactMap { adoptAttachment($0, for: note) }
            .filter { !existing.contains($0.path) })
        note.pendingSubmission = nil
        note.error = "The unconfirmed message has been restored to your draft. Check the history to avoid sending it twice."
        note.focusRequest = UUID()
        persist()
    }

    func discardPending(_ note: NoteState) {
        guard !note.isBusy, !note.isDeleting, !note.deletionPending else { return }
        note.pendingSubmission = nil
        note.error = nil
        persist()
    }

    @discardableResult func persist() -> Bool {
        guard canPersist else { return false }
        do { try persistence.save(documentSnapshot()); return true }
        catch { self.error = "Could not save notes: \(error.localizedDescription)"; return false }
    }

    func recordNoteUse(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }), recentNoteIDs.first != id else { return }
        let existingIDs = Set(notes.map(\.id))
        recentNoteIDs = [id] + recentNoteIDs.filter { $0 != id && existingIDs.contains($0) }
    }

    @discardableResult func updateKeyboardShortcuts(_ settings: KeyboardShortcutSettings) -> Bool {
        let previous = keyboardShortcuts
        do {
            try configureKeyboardShortcuts?(settings)
            keyboardShortcuts = settings
            guard persist() else {
                do {
                    try configureKeyboardShortcuts?(previous)
                    shortcutError = "Could not save shortcuts. Your previous shortcuts have been kept."
                } catch {
                    keyboardShortcuts = previous
                    disableGlobalShortcut?()
                    shortcutError = "Could not save shortcuts or restore the previous global shortcut. Open Recent Note is inactive; use Retry in Keyboard Shortcuts when storage is available."
                }
                keyboardShortcuts = previous
                return false
            }
            shortcutError = nil
            return true
        } catch {
            shortcutError = error.localizedDescription
            return false
        }
    }

    private func documentSnapshot(excluding excludedID: UUID? = nil) -> AppDocument {
        var document = AppDocument()
        document.authenticationMode = authenticationMode
        document.cliPath = cliPath
        document.claudeCLIPath = claudeCLIPath
        document.claudeEnabled = claudeEnabled
        document.defaultModelID = defaultModelID
        document.defaultProvider = defaultProvider
        document.defaultEffort = defaultEffort
        document.inactiveNoteOpacity = AppDocument.normalizedInactiveNoteOpacity(inactiveNoteOpacity)
        document.keepNotesExpanded = keepNotesExpanded
        document.keyboardShortcuts = keyboardShortcuts
        let existingIDs = Set(notes.filter { $0.id != excludedID }.map(\.id))
        document.recentNoteIDs = recentNoteIDs.filter { existingIDs.contains($0) }
        document.notes = notes.filter { $0.id != excludedID }.map { note in
            StoredNote(id: note.id, title: note.title, model: note.model, effort: note.effort,
                       threadID: note.threadID, activeTurnID: note.activeTurnID, draft: note.draft,
                       attachments: note.attachments, hasImages: note.hasImages, isVisible: note.isVisible,
                       compactX: note.compactX, compactY: note.compactY, expandedWidth: note.expandedWidth,
                       expandedHeight: note.expandedHeight, displayID: note.displayID,
                       pendingSubmission: note.pendingSubmission, needsReconciliation: note.needsReconciliation,
                       composerHeight: StoredNote.normalizedComposerHeight(note.composerHeight), provider: note.provider,
                       deletionPending: note.deletionPending,
                       referencedImagePaths: note.imageReferencesKnown ? Array(note.retainedImagePaths).sorted() : nil,
                       compactWidth: note.compactWidth, compactHeight: note.compactHeight, fileLibrary: note.fileLibrary,
                       hasFiles: note.hasFiles)
        }
        return document
    }

    func shutdown() async {
        shuttingDown = true
        connectionRevision = UUID()
        claudeConnectionRevision = UUID()
        connectionTask?.cancel()
        claudeConnectionTask?.cancel()
        authenticationTask?.cancel()
        saveTask?.cancel()
        for task in Array(importTasks.values) { await task.value }
        persist()
        // CodexClient sends best-effort interrupts before closing its process without waiting per note.
        await client.disconnect()
        await claudeClient.disconnect()
        await authenticationTask?.value
        await connectionTask?.value
        await claudeConnectionTask?.value
        await batchDeletionTask?.value
        // A canceled connection may have been awaiting initialization when the
        // first disconnect arrived; close any child it finished starting as well.
        await client.disconnect()
        await claudeClient.disconnect()
        eventTask?.cancel()
        claudeEventTask?.cancel()
        persist()
    }

    private func observe(_ note: NoteState) {
        var subscriptions = Set<AnyCancellable>()
        // A bounded write delay is shared across persisted fields. Streaming tokens never delay it.
        let publishers: [AnyPublisher<Void, Never>] = [
            note.$title.map { _ in () }.eraseToAnyPublisher(), note.$draft.map { _ in () }.eraseToAnyPublisher(),
            note.$model.map { _ in () }.eraseToAnyPublisher(), note.$effort.map { _ in () }.eraseToAnyPublisher(),
            note.$provider.map { _ in () }.eraseToAnyPublisher(),
            note.$attachments.map { _ in () }.eraseToAnyPublisher(), note.$isVisible.map { _ in () }.eraseToAnyPublisher(),
            note.$pendingSubmission.map { _ in () }.eraseToAnyPublisher(),
            note.$composerHeight.map { _ in () }.eraseToAnyPublisher(),
            note.$fileLibrary.map { _ in () }.eraseToAnyPublisher()
        ]
        for publisher in publishers {
            publisher.dropFirst().sink { [weak self] in self?.scheduleSave() }.store(in: &subscriptions)
        }
        // Parent views derive authentication controls and the management search
        // from individual notes. Forward changes so those derived lists stay current.
        note.$title.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        note.$isBusy.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        note.$isDeleting.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        noteSubscriptions[note.id] = subscriptions
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.persist()
        }
    }

    private func resolveCLI() -> URL? {
        cliLocator.resolve(savedPath: cliPath)
    }

    private func applyDefaults() {
        let available = mergedModels
        // Another provider may still be connecting. Keep its saved preference.
        if !defaultModelID.isEmpty && !available.contains(where: { $0.provider == defaultProvider }) { return }
        if defaultModelID.isEmpty || !available.contains(where: { $0.id == defaultModelSelectionID }) {
            if let initial = available.first(where: \.isDefault) ?? available.first {
                defaultProvider = initial.provider
                defaultModelID = initial.nativeID
            }
        }
        if let model = available.first(where: { $0.id == defaultModelSelectionID }),
           !model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == defaultEffort }) {
            defaultEffort = model.defaultReasoningEffort
        }
    }

    @discardableResult private func validateSelection(_ note: NoteState) -> Bool {
        guard !note.deletionPending else { return false }
        guard let model = availableModels(for: note).first(where: { $0.id == note.modelSelectionID }) else {
            note.error = "The selected model is unavailable or does not support images. Choose another model."; return false
        }
        guard model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == note.effort }) else {
            note.error = "This model does not support the selected effort. Choose another effort level."; return false
        }
        return true
    }

    private func storeImage(to note: NoteState, decode: () throws -> CGImage) {
        guard !shuttingDown, !note.isDeleting, !note.deletionPending,
              notes.contains(where: { $0 === note }) else { return }
        do {
            guard note.attachments.count < 20 else { throw AppError.message("Attach up to 20 files per message.") }
            let png = try AttachmentImageCodec.png(decode())
            let attachment = try attachmentStore.storePNG(png, noteID: note.id, name: "Pasted image.png")
            note.attachments.append(attachment)
            note.fileLibrary.append(attachment)
            note.error = nil
            note.focusRequest = UUID()
            if isReady(for: note) { validateSelection(note) }
            persist()
        } catch { note.error = error.localizedDescription }
    }

    private func acceptSubmission(_ note: NoteState, _ submission: PendingSubmission) {
        note.retainedImagePaths.formUnion(submission.attachments.filter(\.isImage).map(\.path))
        if note.draft == submission.text { note.draft = "" }
        let sentIDs = Set(submission.attachments.map(\.id)), sentPaths = Set(submission.attachments.map(\.path))
        note.attachments.removeAll { sentIDs.contains($0.id) || ($0.legacyPath.map { sentPaths.contains($0) } ?? false) }
        note.hasImages = note.hasImages || submission.attachments.contains(where: \.isImage)
        note.hasFiles = note.hasFiles || submission.attachments.contains(where: { !$0.isImage })
        note.pendingSubmission = nil
    }

    private func restoreConversations(provider: ChatProvider) async {
        for note in notes where note.provider == provider {
            guard !note.deletionPending else { continue }
            guard let threadID = note.threadID else { continue }
            let wasInterrupted = note.activeTurnID != nil || note.pendingSubmission != nil
            do {
                try await configureFileAccess(try fileAccessContext(for: note), threadID: threadID, provider: provider)
                let response = try await resumeThread(threadID, provider: provider)
                let restored = Transcript.messages(from: response)
                note.messages = localizedMessages(restored, for: note)
                note.retainedImagePaths.formUnion(restored.flatMap(\.imagePaths))
                note.imageReferencesKnown = true
                note.hasImages = note.hasImages || restored.contains(where: { !$0.imagePaths.isEmpty })
                note.hasFiles = note.hasFiles || restored.contains(where: { !$0.fileAttachments.isEmpty })
                resumedThreadIDs.insert(routingKey(threadID, provider: provider))
                note.activeTurnID = nil
                note.isBusy = false
                note.isStopping = false
                note.needsReconciliation = false
                note.pendingUserMessageID = nil
                if let pending = note.pendingSubmission, pending.matchesNewReceipt(restored.last(where: { $0.role == "user" })) {
                    acceptSubmission(note, pending)
                }
                note.error = wasInterrupted ? "Conversation history restored. The previous request may have been interrupted; check the last reply. No messages were resent." : nil
                validateSelection(note)
            } catch {
                note.isBusy = false
                note.isStopping = false
                note.error = "Could not restore the conversation. Your note and draft have been kept: \(error.localizedDescription)"
            }
        }
    }

    private func handle(_ event: CodexEvent, provider: ChatProvider) {
        switch event {
        case .disconnected(let reason):
            guard !shuttingDown else { return }
            if provider == .codex {
                guard !isConnecting, !isUpdatingAuthentication else { return }
                connectionRevision = UUID()
                isConnected = false
                isLoggedIn = false
                accountKind = .none
                models = []
                connectionStatus = "Codex disconnected"
                error = reason
            } else {
                guard !claudeIsConnecting else { return }
                claudeConnectionRevision = UUID()
                claudeIsConnected = false
                claudeIsLoggedIn = false
                claudeModels = []
                claudeConnectionStatus = "Claude disconnected"
                claudeError = reason
            }
            clearRoutingState(provider: provider)
            for note in notes where note.provider == provider && note.isBusy {
                note.isBusy = false
                note.isStopping = false
                note.needsReconciliation = true
                note.error = "\(provider.displayName) disconnected. Your reply and draft have been kept. Reconnect to check the history; messages will not be resent automatically."
            }
            persist()
        case .notification(let method, let params):
            if provider == .codex && method == "account/login/completed" {
                // API login is completed within connect(). Browser completions
                // belong only to an explicitly started, still-current login.
                guard authenticationMode == .codexSignIn, loginInProgress,
                      !isConnecting, !isUpdatingAuthentication, !shuttingDown else { return }
                loginInProgress = false
                if params["success"].boolValue == true { connect() }
                else { error = params["error"].stringValue ?? "Sign-in did not complete. Try again." }
                return
            }
            if provider == .codex && method == "account/updated" {
                guard !isConnecting, !isUpdatingAuthentication, !shuttingDown else { return }
                switch params["authMode"].stringValue {
                case "chatgpt": accountKind = .chatGPT
                case "apikey": accountKind = .apiKey
                case nil: accountKind = .none
                default: accountKind = .unsupported
                }
                isLoggedIn = isConnected && (accountKind == .chatGPT || accountKind == .apiKey)
                if authenticationMode == .openAIAPIKey && accountKind != .apiKey { isLoggedIn = false }
                if !isLoggedIn { connectionStatus = "Authentication is unavailable. Reconnect in Settings." }
                return
            }
            guard !shuttingDown, provider != .codex || !isUpdatingAuthentication else { return }
            guard let threadID = params["threadId"].stringValue,
                  let note = notes.first(where: { $0.provider == provider && $0.threadID == threadID }),
                  !note.isDeleting, !note.deletionPending else { return }
            switch method {
            case "floatingAI/sessionDisconnected":
                resumedThreadIDs.remove(routingKey(threadID, provider: provider))
                note.isBusy = false
                note.isStopping = false
                note.needsReconciliation = true
                note.error = params["message"].stringValue ?? "Conversation disconnected. Reconnect to check history before sending again."
                persist()
            case "turn/started":
                note.activeTurnID = params["turn"]["id"].stringValue
                note.isBusy = true
            case "item/agentMessage/delta":
                guard let itemID = params["itemId"].stringValue, let delta = params["delta"].stringValue else { return }
                Transcript.append(delta: delta, itemID: itemID, to: &note.messages)
            case "item/started", "item/completed":
                guard let message = Transcript.message(from: params["item"]) else { return }
                // Started events after a delta must not erase already streamed text.
                if method == "item/started", note.messages.contains(where: { $0.id == message.id }) { return }
                receiveMessage(message, for: note)
            case "turn/completed":
                if let turnID = params["turn"]["id"].stringValue {
                    let key = routingKey(threadID + ":" + turnID, provider: provider)
                    guard !completedTurnIDs.contains(key) else { return }
                    if let activeID = note.activeTurnID, activeID != turnID { return }
                    completedTurnIDs.insert(key)
                }
                if let items = params["turn"]["items"].arrayValue {
                    for item in items {
                        if let message = Transcript.message(from: item) { receiveMessage(message, for: note) }
                    }
                }
                note.isBusy = false
                note.isStopping = false
                note.needsReconciliation = false
                note.activeTurnID = nil
                note.hasUnreadReply = !note.isExpanded
                if let message = params["turn"]["error"]["message"].stringValue { note.error = requestFailureDescription(message, provider: provider) }
                if let submission = note.pendingSubmission { acceptSubmission(note, submission) }
                persistAfterDispatch(note)
            case "error":
                note.error = requestFailureDescription(params["error"]["message"].stringValue ?? "\(provider.displayName) returned an error.", provider: provider)
            case "floatingAI/toolBlocked":
                note.error = params["message"].stringValue ?? "This action was blocked. Floating AI allows web search and reading files attached to this note; other local actions are unavailable."
            default: break
            }
        }
    }

    private func requestFailureDescription(_ message: String, provider: ChatProvider = .codex) -> String {
        guard provider == .codex, authenticationMode == .openAIAPIKey || accountKind == .apiKey else { return message }
        let lower = message.lowercased()
        if lower.contains("insufficient_quota") || lower.contains("exceeded your current quota") || lower.contains("billing_hard_limit") {
            return "OpenAI API quota is unavailable. Check your Platform billing and project limits.\n\(message)"
        }
        if lower.contains("invalid_api_key") || lower.contains("incorrect api key") || lower.contains("invalid api key") || lower.contains("401 unauthorized") {
            return "The OpenAI API key was rejected. Replace it in Settings, then reconnect.\n\(message)"
        }
        if lower.contains("model_not_found") || (lower.contains("model") && (lower.contains("does not exist") || lower.contains("do not have access"))) {
            return "This model is unavailable for the API key. Choose an accessible model.\n\(message)"
        }
        return message
    }

    private func receiveMessage(_ message: ChatMessage, for note: NoteState) {
        if message.role == "user", !note.messages.contains(where: { $0.id == message.id }),
           let pendingID = note.pendingUserMessageID {
            note.messages.removeAll { $0.id == pendingID }
            note.pendingUserMessageID = nil
            if let submission = note.pendingSubmission { acceptSubmission(note, submission) }
        }
        if let localized = localizedMessages([message], for: note).first { Transcript.upsert(localized, into: &note.messages) }
    }

    private func recoverFileLibrary(_ note: NoteState) {
        var candidates = note.fileLibrary + note.attachments + (note.pendingSubmission?.attachments ?? [])
        candidates += note.retainedImagePaths.map { Attachment(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
        note.fileLibrary = []
        for file in candidates { _ = adoptAttachment(file, for: note) }
        note.attachments = note.attachments.map { adoptAttachment($0, for: note) ?? $0 }
    }

    private func adoptAttachment(_ file: Attachment, for note: NoteState) -> Attachment? {
        if let known = note.fileLibrary.first(where: { $0.path == file.path || $0.legacyPath == file.path }) { return known }
        if attachmentStore.owns(file, noteID: note.id) {
            note.fileLibrary.append(file); return file
        }
        // Older Copy History shared image paths. Make private copies before they
        // appear in this note's library; never adopt arbitrary transcript paths.
        let url = URL(fileURLWithPath: file.path).standardizedFileURL
        let root = persistence.directory.appendingPathComponent("Attachments").standardizedFileURL
        guard file.isImage, url.path.hasPrefix(root.path + "/"),
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              AttachmentStore.isManagedFilename(url.lastPathComponent),
              UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil,
              url.deletingLastPathComponent().deletingLastPathComponent() == root else { return nil }
        do {
            var copy = try attachmentStore.importFile(url, noteID: note.id, name: file.name, kind: .image)
            copy.legacyPath = file.path
            note.fileLibrary.append(copy)
            return copy
        } catch { return nil }
    }

    private func localizedMessages(_ messages: [ChatMessage], for note: NoteState) -> [ChatMessage] {
        messages.map { message in
            var value = message
            value.imagePaths = message.imagePaths.compactMap {
                adoptAttachment(Attachment(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent), for: note)?.path
            }
            value.fileAttachments = message.fileAttachments.compactMap { file in
                guard attachmentStore.owns(file, noteID: note.id) else { return nil }
                return adoptAttachment(file, for: note)
            }
            return value
        }
    }

    private enum AppError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
