import AppKit
import FloatingAICore
import SwiftUI

struct PopupOption: Equatable {
    var id: String
    var title: String
}

/// A native menu exposes its lifetime so a floating panel does not collapse mid-selection.
struct NativePopup: NSViewRepresentable {
    var options: [PopupOption]
    var selection: String
    var unavailableTitle: String? = nil
    var enabled = true
    var borderless = false
    var accessibilityLabel: String
    var onSelect: (String) -> Void
    var onInteraction: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SelectedTitlePopup {
        let popup = SelectedTitlePopup(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.changed(_:))
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(popup, coordinator: context.coordinator)
        return popup
    }

    func updateNSView(_ popup: SelectedTitlePopup, context: Context) {
        context.coordinator.parent = self
        configure(popup, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectedTitlePopup, context: Context) -> NSSize? {
        let ideal = nsView.intrinsicContentSize
        // Report only the selected title's ideal width. When a narrow window proposes
        // less space, retain the native disclosure arrow and truncate the title.
        return NSSize(width: min(ideal.width, max(0, proposal.width ?? ideal.width)),
                      height: proposal.height ?? ideal.height)
    }

    private func configure(_ popup: SelectedTitlePopup, coordinator: Coordinator) {
        if coordinator.options != options || coordinator.displayedSelection != selection || coordinator.unavailableTitle != unavailableTitle {
            popup.removeAllItems()
            let items = options.contains(where: { $0.id == selection }) ? options :
                [PopupOption(id: selection, title: selection.isEmpty ? "Choose…" : "\(unavailableTitle ?? selection) (unavailable)")] + options
            for option in items {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                popup.menu?.addItem(item)
            }
            coordinator.options = options
            coordinator.displayedSelection = selection
            coordinator.unavailableTitle = unavailableTitle
        }
        popup.menu?.delegate = coordinator
        popup.isEnabled = enabled && !options.isEmpty
        popup.isBordered = !borderless
        popup.cell?.lineBreakMode = .byTruncatingTail
        popup.setAccessibilityLabel(accessibilityLabel)
        popup.fitSelectedTitle = true
        synchronizeSelection(popup)
    }

    private func synchronizeSelection(_ popup: NSPopUpButton) {
        // AppKit changes its selection before dispatching the action. The model
        // remains authoritative even when a callback cancels or creates a new note.
        if (popup.selectedItem?.representedObject as? String) != selection,
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selection }) {
            popup.selectItem(at: index)
        }
        (popup as? SelectedTitlePopup)?.refreshSelectedTitleSize()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: NativePopup
        var options: [PopupOption] = []
        var displayedSelection: String?
        var unavailableTitle: String?
        init(_ parent: NativePopup) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            // Restore before a modal opens; accepted changes arrive through
            // updateNSView, including when the callback runs a nested event loop.
            parent.synchronizeSelection(sender)
            parent.onSelect(id)
        }
        func menuWillOpen(_ menu: NSMenu) { parent.onInteraction(true) }
        func menuDidClose(_ menu: NSMenu) { parent.onInteraction(false) }
    }
}

/// NSPopUpButton normally sizes to the longest menu item. These menus instead
/// use a one-item measuring control to retain native padding and arrow spacing.
final class SelectedTitlePopup: NSPopUpButton {
    var fitSelectedTitle = false
    private var selectedTitleSize = NSSize.zero
    private var measuredTitle: String?
    private var measuredFont: NSFont?
    private var measuredControlSize: NSControl.ControlSize?
    private var measuredBordered: Bool?

    override var intrinsicContentSize: NSSize {
        fitSelectedTitle ? selectedTitleSize : super.intrinsicContentSize
    }

    func refreshSelectedTitleSize() {
        guard fitSelectedTitle else { return }
        let title = selectedItem?.title ?? "Choose…"
        guard measuredTitle != title || measuredFont != font || measuredControlSize != controlSize || measuredBordered != isBordered else { return }
        let measuringControl = NSPopUpButton(frame: .zero, pullsDown: false)
        measuringControl.controlSize = controlSize
        measuringControl.font = font
        measuringControl.isBordered = isBordered
        measuringControl.addItem(withTitle: title)
        selectedTitleSize = measuringControl.intrinsicContentSize
        measuredTitle = title
        measuredFont = font
        measuredControlSize = controlSize
        measuredBordered = isBordered
        invalidateIntrinsicContentSize()
    }
}

@MainActor struct NewNoteView: View {
    @ObservedObject var store: AppStore
    var onCreated: (NoteState) -> Void
    var onCancel: () -> Void
    @State private var title = ""
    @State private var model = ""
    @State private var modelTitle = ""
    @State private var effort = ""
    @State private var initialized = false
    @FocusState private var titleFocused: Bool

    private var selectedModel: ChatModel? { store.mergedModels.first { $0.id == model } }
    private var isReady: Bool {
        guard let selectedModel else { return false }
        let connected = selectedModel.provider == .codex
            ? store.isConnected && store.isLoggedIn && !store.isConnecting
            : store.claudeIsConnected && store.claudeIsLoggedIn && !store.claudeIsConnecting
        return connected && selectedModel.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Note").font(.title2.weight(.semibold))
                    Text("Give this conversation a short name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Ask Me Anything", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                NativePopup(options: store.mergedModels.map { .init(id: $0.id, title: $0.displayName) }, selection: model,
                            unavailableTitle: modelTitle, enabled: store.hasConnectedProvider,
                            accessibilityLabel: "Model", onSelect: selectModel)
                    .frame(height: 26)
                Text("Effort").font(.caption).foregroundStyle(.secondary)
                NativePopup(options: effortOptions, selection: effort, enabled: store.hasConnectedProvider,
                            accessibilityLabel: "Effort", onSelect: { effort = $0 })
                    .frame(height: 26)
            }
            if !store.hasConnectedProvider {
                Label("Connect Codex or Claude in Settings to create a note.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh Models") { store.refreshAllModels() }.disabled(!store.hasConnectedProvider)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Create Note") {
                    onCreated(store.createNote(title: title, model: model, effort: effort))
                }.keyboardShortcut(.defaultAction).disabled(!isReady)
            }
        }
        .padding(26).frame(width: 390)
        .onAppear { initializeSelection(); titleFocused = true }
        .onChange(of: store.mergedModels.map(\.id)) { _ in initializeSelection() }
    }

    private var effortOptions: [PopupOption] {
        selectedModel?.supportedReasoningEfforts.map { .init(id: $0.reasoningEffort, title: $0.reasoningEffort.capitalized) } ?? []
    }

    private func initializeSelection() {
        guard !initialized, !store.mergedModels.isEmpty else { return }
        initialized = true
        let initial = store.mergedModels.first(where: { $0.id == store.defaultModelSelectionID })
            ?? store.mergedModels.first(where: { $0.isDefault }) ?? store.mergedModels.first!
        model = initial.id
        modelTitle = initial.displayName
        effort = initial.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == store.defaultEffort })
            ? store.defaultEffort : initial.defaultReasoningEffort
    }

    private func selectModel(_ id: String) {
        model = id
        modelTitle = selectedModel?.displayName ?? "Choose a model"
        if let selectedModel, !selectedModel.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) {
            effort = selectedModel.defaultReasoningEffort
        }
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var path = ""
    @State private var claudePath = ""
    @State private var apiKey = ""

    private var canChangeAuthentication: Bool {
        store.canChangeAuthentication && !store.isConnecting && !store.isUpdatingAuthentication
    }

    var body: some View {
        ScrollView {
            content.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 500, height: 650)
        .onAppear { path = store.cliPath; claudePath = store.claudeCLIPath }
        .onChange(of: store.cliPath) { path = $0 }
        .onChange(of: store.claudeCLIPath) { claudePath = $0 }
        .onChange(of: store.authenticationMode) { _ in apiKey = "" }
        .onDisappear { apiKey = "" }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "note.text").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Floating AI").font(.title2.weight(.semibold))
                    Text("Chat through your local Codex and Claude Code CLIs.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Codex").font(.headline)
            HStack(spacing: 8) {
                Circle().fill(store.isLoggedIn && store.isConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(store.connectionStatus).font(.callout).fixedSize(horizontal: false, vertical: true)
                if store.isConnecting || store.isUpdatingAuthentication { ProgressView().controlSize(.small) }
            }
            authentication
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex CLI Path").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Find codex automatically", text: $path).textFieldStyle(.roundedBorder)
                    Button("Choose…") { store.chooseCLI() }
                }
                .disabled(!canChangeAuthentication)
                Text("Supports Codex CLI 0.134.x, 0.151.x, and 0.163.x. Use Local Codex finds your standalone or package manager installation and reconnects.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Use Local Codex") { store.useLocalCLI() }
                    .disabled(!canChangeAuthentication)
                Button("Reconnect") {
                    guard canChangeAuthentication else { return }
                    store.cliPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.connect()
                }
                .disabled(!canChangeAuthentication)
                Spacer()
                Link("Install Codex ↗", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                    .font(.callout)
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            claudeConnection
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep Notes Expanded", isOn: $store.keepNotesExpanded)
                Text("Keep notes open when you click elsewhere. Click the title or press Esc to collapse.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Inactive Note Opacity").font(.callout)
                    Spacer()
                    Text("\(Int((store.inactiveNoteOpacity * 100).rounded()))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $store.inactiveNoteOpacity, in: 0.2...1)
                    .accessibilityLabel("Inactive Note Opacity")
                Text("Dims collapsed notes when they are not selected. 100% is fully opaque.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Notes, drafts, and conversation history are saved on this Mac. Reopen hidden notes from the menu bar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var claudeConnection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code").font(.headline)
            HStack(spacing: 8) {
                Circle().fill(store.claudeIsLoggedIn && store.claudeIsConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(store.claudeConnectionStatus).font(.callout).fixedSize(horizontal: false, vertical: true)
                if store.claudeIsConnecting { ProgressView().controlSize(.small) }
            }
            Text("Uses your existing Claude Code sign-in. Codex and Claude can stay connected together.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Claude Code CLI Path").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Find claude automatically", text: $claudePath).textFieldStyle(.roundedBorder)
                Button("Choose…") { store.chooseClaudeCLI() }
            }
            .disabled(!store.canChangeClaudeConnection)
            HStack {
                Button("Use Local Claude") { store.useLocalClaudeCLI() }
                Button(store.claudeEnabled ? "Reconnect" : "Connect") {
                    guard store.canChangeClaudeConnection else { return }
                    store.claudeCLIPath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.connectClaude()
                }
                Button("Disconnect") { store.disconnectClaude() }.disabled(!store.claudeEnabled)
            }
            .disabled(!store.canChangeClaudeConnection)
            HStack {
                Button("Sign In to Claude") { store.loginClaude() }
                    .disabled(!store.canChangeClaudeConnection)
                Spacer()
                Link("Install Claude Code ↗", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                    .font(.callout)
            }
            if !store.canChangeClaudeConnection && !store.claudeIsConnecting {
                Text("Finish or stop Claude replies before changing this connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.claudeError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authentication").font(.caption).foregroundStyle(.secondary)
            Picker("Authentication", selection: Binding(
                get: { store.authenticationMode },
                set: { mode in
                    guard canChangeAuthentication else { return }
                    apiKey = ""
                    store.selectAuthenticationMode(mode)
                }
            )) {
                Text("Use Codex Sign-In").tag(AuthenticationMode.codexSignIn)
                Text("OpenAI API Key").tag(AuthenticationMode.openAIAPIKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!canChangeAuthentication)

            if store.authenticationMode == .codexSignIn {
                Text("Uses your existing Codex sign-in. You can sign in with ChatGPT in your browser.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Sign In to ChatGPT") { store.login() }
                    .disabled(!store.isConnected || !canChangeAuthentication)
            } else {
                SecureField(store.hasSavedAPIKey ? "Enter a replacement API key" : "Enter your OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(store.hasSavedAPIKey ? "Replacement OpenAI API key" : "OpenAI API key")
                    .disabled(!canChangeAuthentication)
                    .onSubmit(saveAPIKey)
                HStack {
                    Button("Save & Connect", action: saveAPIKey)
                        .disabled(!canChangeAuthentication || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key") {
                        guard canChangeAuthentication else { return }
                        apiKey = ""
                        store.removeAPIKey()
                    }
                    .disabled(!canChangeAuthentication || !store.hasSavedAPIKey)
                    Spacer()
                    Text(apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Stored in your Mac’s Keychain for Floating AI only. A saved key is checked when you send a message. OpenAI API usage is billed separately from ChatGPT.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !store.canChangeAuthentication && !store.isConnecting && !store.isUpdatingAuthentication {
                Text("Finish or stop Codex replies before changing authentication or the CLI connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apiKeyStatus: String {
        if store.isUpdatingAuthentication { return "Updating…" }
        if store.isConnecting { return "Connecting…" }
        return store.hasSavedAPIKey ? "Key saved" : "No key saved"
    }

    private func saveAPIKey() {
        guard canChangeAuthentication, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedKey = apiKey
        apiKey = ""
        store.saveAPIKey(submittedKey)
    }
}
