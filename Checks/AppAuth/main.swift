import AppKit
import Foundation
import FloatingAICore

// Runs production AppStore/Client code against an isolated protocol process and
// an in-memory credential store. This executable never creates a window, calls
// Keychain, touches user notes, or contacts a real API.
private let originalKey = "sk-fixture-original-app-auth"
private let replacementKey = "sk-fixture-replacement-app-auth"

private struct CheckFailure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition() else { throw CheckFailure(description: "\(message) [\(file):\(line)]") }
}

private final class MemoryKeyStore: APIKeyStore, @unchecked Sendable {
    struct Snapshot: Equatable {
        var reads = 0
        var saves = 0
        var deletes = 0
        var hasKey: Bool
    }
    private let lock = NSLock()
    private var value: String?
    private var counts: Snapshot
    private var readDenied = false
    private var saveDenied = false
    private var deleteDenied = false
    private var readDelay: TimeInterval = 0

    init(key: String? = nil) {
        value = key
        counts = Snapshot(hasKey: key != nil)
    }
    func configure(readDenied: Bool = false, saveDenied: Bool = false,
                   deleteDenied: Bool = false, readDelay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        self.readDenied = readDenied
        self.saveDenied = saveDenied
        self.deleteDenied = deleteDenied
        self.readDelay = readDelay
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return counts
    }
    func read() throws -> String? {
        lock.lock()
        counts.reads += 1
        let denied = readDenied, delay = readDelay, stored = value
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if denied { throw APIKeyStoreError.keychain(operation: .read, status: -25293) }
        return stored
    }
    func save(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        counts.saves += 1
        // A deliberately badly behaved injected backend verifies that the UI
        // error path does not repeat the submitted credential.
        if saveDenied { throw CheckFailure(description: "Fixture denied saving \(key)") }
        value = key
        counts.hasKey = true
    }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        counts.deletes += 1
        if deleteDenied { throw APIKeyStoreError.keychain(operation: .delete, status: -25293) }
        value = nil
        counts.hasKey = false
    }
}

private struct Fixture {
    let directory: URL
    let executable: URL
    let log: URL
    let noteID = UUID()
    var localExecutable: URL { directory.appendingPathComponent(".local/bin/codex") }

    init(mode: AuthenticationMode? = nil, existingThread: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floating-ai-app-auth-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("fake-codex")
        log = directory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: localExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: localExecutable, withDestinationURL: executable)
        var document = AppDocument()
        document.cliPath = executable.path
        document.authenticationMode = mode
        document.defaultModelID = "model-a"
        document.defaultEffort = "medium"
        if existingThread {
            document.notes = [StoredNote(id: noteID, title: "Fixture note", model: "model-a", effort: "medium",
                                        threadID: "thread-existing", draft: "Retain this unsent draft.",
                                        compactX: 31, compactY: 47, expandedWidth: 540, expandedHeight: 680,
                                        composerHeight: 81)]
        }
        try NotePersistence(directory: directory).save(document)
    }

    func events() -> [[String: Any]] {
        guard let contents = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
    func count(_ event: String) -> Int { events().filter { $0["event"] as? String == event }.count }
    func requests(_ method: String) -> [[String: Any]] {
        events().filter { $0["method"] as? String == method }
    }
    func runningChildren() -> Set<Int> {
        let events = events()
        let started = Set(events.filter { $0["event"] as? String == "started" }.compactMap { $0["pid"] as? Int })
        let stopped = Set(events.filter { $0["event"] as? String == "stopped" }.compactMap { $0["pid"] as? Int })
        return started.subtracting(stopped)
    }
    func validateStoredData() throws {
        let document = try String(contentsOf: directory.appendingPathComponent("notes.json"), encoding: .utf8)
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        for key in [originalKey, replacementKey] {
            try require(!document.contains(key), "Credential leaked into note metadata")
            try require(!logText.contains(key), "Credential leaked into fixture diagnostic log")
        }
        try require(requests("account/logout").isEmpty, "Authentication change must not log out shared Codex")
    }

    private static let server = #"""
#!/usr/bin/python3
import atexit, json, os, signal, sys, threading, time
directory = os.path.dirname(os.path.realpath(__file__))
log_path = os.path.join(directory, 'events.jsonl')
pid = os.getpid()
output_lock = threading.Lock()
account = 'chatgpt'
api_mode = 'cli_auth_credentials_store="ephemeral"' in sys.argv
def record(event, **fields):
    fields.update(event=event, pid=pid)
    descriptor = os.open(log_path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try: os.write(descriptor, (json.dumps(fields) + '\n').encode())
    finally: os.close(descriptor)
record('started', apiMode=api_mode)
atexit.register(lambda: record('stopped'))
signal.signal(signal.SIGTERM, lambda *args: sys.exit(0))
def send(message):
    with output_lock: os.write(1, (json.dumps(message) + '\n').encode())
def bootstrap():
    # Deliberately arrive after the connect result is published. API bootstrap
    # notifications must not trigger another connection or browser login.
    time.sleep(0.06)
    record('bootstrap')
    send({'method':'account/login/completed','params':{'success':True}})
    send({'method':'account/updated','params':{'authMode':'apikey'}})
def thread(thread_id):
    return {'id':thread_id,'turns':[{'id':'turn-existing','status':'completed','items':[
        {'id':'user-existing','type':'userMessage','content':[{'type':'text','text':'Previous question'}]},
        {'id':'reply-existing','type':'agentMessage','text':'Previous answer'}]}]}
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    params = message.get('params', {})
    fields = {'method':method}
    if 'threadId' in params: fields['threadId'] = params['threadId']
    if method == 'account/login/start':
        fields['loginType'] = params.get('type')
        fields['keyLabel'] = {'sk-fixture-original-app-auth':'original',
                              'sk-fixture-replacement-app-auth':'replacement'}.get(params.get('apiKey'), 'unknown')
    record('request', **fields)
    result = {}
    if method == 'initialize': result = {'userAgent':'codex/0.151.0 (app-store-fixture)'}
    elif method == 'config/read':
        result = {'config':{'mcp_servers':{},'cli_auth_credentials_store':'ephemeral',
            'model_provider':'openai','openai_base_url':'https://api.openai.com/v1','model_providers':{}}}
    elif method == 'configRequirements/read': result = {'requirements':{}}
    elif method == 'account/login/start':
        account = 'apiKey'
        result = {'type':'apiKey'}
    elif method == 'account/read': result = {'account':{'type':account}}
    elif method == 'model/list':
        result = {'data':[{'id':'catalog-model-a','model':'model-a','displayName':'Fixture Model',
            'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':'medium','description':'Balanced'}],
            'inputModalities':['text','image'],'isDefault':True,'hidden':False}]}
    elif method in ('thread/resume', 'thread/read'): result = {'thread':thread(params['threadId']),'modelProvider':'openai'}
    elif method == 'thread/start': result = {'thread':thread('fixture-new-thread'),'modelProvider':'openai'}
    elif method == 'turn/start':
        send({'method':'turn/started','params':{'threadId':params['threadId'],'turn':{'id':'early-turn'}}})
        send({'method':'turn/completed','params':{'threadId':params['threadId'],
            'turn':{'id':'early-turn','status':'completed','items':[]}}})
        record('completion-sent')
        time.sleep(0.25)
        result = {'turn':{'id':'early-turn','status':'inProgress'}}
        record('turn-response')
    if 'id' in message: send({'id':message['id'],'result':result})
    if method == 'model/list' and api_mode:
        threading.Thread(target=bootstrap, daemon=True).start()
"""#
}

@main private struct AppAuthChecks {
    @MainActor static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("CLI discovery prefers local installs and preserves explicit paths", cliDiscovery),
            ("local CLI selection reconnects without replacing notes", localCLISelection),
            ("missing local CLI preserves the current connection", missingLocalCLI),
            ("legacy/default Codex mode does not read credentials", defaultMode),
            ("API reconnect reads saved key and ignores bootstrap notifications", apiReconnect),
            ("switch to missing API key disconnects without fallback", missingKey),
            ("save, replace, and remove an app-only key", saveReplaceRemove),
            ("denied credential operations preserve errors and key state", deniedOperations),
            ("active conversation blocks authentication mutations", busyGuards),
            ("early completion keeps authentication locked until send responds", earlyCompletionGuard),
            ("authentication switch resumes the same conversation and draft", restoreConversation),
            ("shutdown during credential read cannot launch an orphan", delayedReadShutdown),
            ("preview authentication has no credential I/O", previewIsolation)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("App authentication checks: \(checks.count - failures)/\(checks.count) passed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func wait(_ description: String, timeout: TimeInterval = 5,
                                       until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw CheckFailure(description: "Timed out: \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func idle(_ store: AppStore) async throws {
        try await wait("authentication operation") { !store.isConnecting && !store.isUpdatingAuthentication }
    }

    @MainActor private static func exercise(mode: AuthenticationMode? = nil, key: String? = nil,
                                           existingThread: Bool = false,
                                           _ body: (AppStore, MemoryKeyStore, Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(mode: mode, existingThread: existingThread)
        let keyStore = MemoryKeyStore(key: key)
        let client = CodexClient(requestTimeout: 2, environment: ["PATH":"/usr/bin:/bin"])
        let locator = CodexCLILocator(homeDirectory: fixture.directory, searchPath: "", isExecutable: { path in
            path.hasPrefix(fixture.directory.path + "/") && FileManager.default.isExecutableFile(atPath: path)
        })
        let store = AppStore(directory: fixture.directory, apiKeyStore: keyStore, client: client, cliLocator: locator)
        do {
            try await body(store, keyStore, fixture)
            await store.shutdown()
            try await wait("fixture processes to exit") { fixture.runningChildren().isEmpty }
            try fixture.validateStoredData()
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await store.shutdown()
            try? await wait("cleanup fixture processes") { fixture.runningChildren().isEmpty }
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @MainActor private static func noLeakedErrors(_ store: AppStore) throws {
        for key in [originalKey, replacementKey] {
            try require(!(store.error ?? "").contains(key), "Credential leaked into user-facing error")
            try require(!store.connectionStatus.contains(key), "Credential leaked into connection status")
        }
    }

    @MainActor private static func defaultMode() async throws {
        try await exercise(key: originalKey) { store, keys, fixture in
            try require(store.authenticationMode == .codexSignIn, "Legacy document must retain Codex sign-in")
            try require(keys.snapshot().reads == 0, "Initialization must not read Keychain")
            store.connect(); try await idle(store)
            try require(store.isConnected && store.accountKind == .chatGPT, "Codex mode should use the existing account")
            try require(keys.snapshot().reads == 0, "Codex mode must not load the app key")
            try require(fixture.requests("account/login/start").isEmpty, "Existing account should not receive API login")
            try require(fixture.count("started") == 1, "Default connection should launch once")
        }
    }

    @MainActor private static func cliDiscovery() async throws {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let local = "/fixture-home/.local/bin/codex"
        let bundle = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let userBundle = "/fixture-home/Applications/ChatGPT.app/Contents/Resources/codex"
        let custom = "/fixture-tools/codex"
        var available: Set<String> = [local, bundle, userBundle, custom, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let locator = CodexCLILocator(homeDirectory: home,
                                     searchPath: "/Applications/ChatGPT.app/Contents/Resources:/fixture-tools",
                                     isExecutable: { available.contains($0) })
        try require(locator.resolve(savedPath: "")?.path == local, "Auto discovery should prefer the standalone CLI")
        try require(locator.resolve(savedPath: bundle)?.path == bundle, "An explicit bundled path must be preserved")
        try require(locator.resolve(savedPath: "/missing/codex") == nil, "Missing saved path must not silently fall back")
        available.remove(local)
        try require(locator.localInstallation()?.path == "/opt/homebrew/bin/codex", "Homebrew must be considered after standalone")
        available.remove("/opt/homebrew/bin/codex")
        try require(locator.localInstallation()?.path == "/usr/local/bin/codex", "Intel package manager path was skipped")
        available.remove("/usr/local/bin/codex")
        try require(locator.localInstallation()?.path == custom, "PATH lookup was skipped or chose an app bundle")
        available.remove(custom)
        try require(locator.localInstallation() == nil, "Explicit local selection must not choose a bundled CLI from PATH")
        try require(locator.resolve(savedPath: "")?.path == bundle, "Automatic discovery should retain bundled fallback")
        available.remove(bundle)
        try require(locator.resolve(savedPath: "")?.path == userBundle, "User Applications bundled fallback was skipped")
    }

    @MainActor private static func localCLISelection() async throws {
        try await exercise(existingThread: true) { store, _, fixture in
            store.connect(); try await idle(store)
            store.useLocalCLI(); try await idle(store)
            try require(store.isConnected && fixture.count("started") == 2, "Local CLI selection should reconnect once")
            try require(store.cliPath == fixture.localExecutable.path, "Local CLI symlink must not be resolved to its versioned target")
            let saved = try NotePersistence(directory: fixture.directory).load()
            try require(saved.cliPath == fixture.localExecutable.path, "Local CLI path was not persisted")
            try require(store.notes.count == 1 && store.notes[0].id == fixture.noteID && store.notes[0].threadID == "thread-existing",
                        "Local CLI selection replaced the existing note or thread")
            try require(store.notes[0].draft == "Retain this unsent draft.", "Local CLI selection lost the draft")
            try require(fixture.requests("thread/resume").count == 2, "The existing conversation was not resumed after CLI selection")
            try require(fixture.requests("turn/start").isEmpty && fixture.requests("thread/start").isEmpty,
                        "CLI selection must not send a message or start a replacement thread")
        }
    }

    @MainActor private static func missingLocalCLI() async throws {
        try await exercise { store, _, fixture in
            store.connect(); try await idle(store)
            try FileManager.default.removeItem(at: fixture.localExecutable)
            store.useLocalCLI(); try await idle(store)
            try require(store.isConnected && store.cliPath == fixture.executable.path && fixture.count("started") == 1,
                        "Missing local CLI must preserve the current path and connection")
            try require(store.error?.contains("No local Codex CLI was found") == true, "Missing local CLI needs an actionable error")
        }
    }

    @MainActor private static func apiReconnect() async throws {
        try await exercise(mode: .openAIAPIKey, key: originalKey) { store, keys, fixture in
            store.connect(); try await idle(store)
            try require(store.isConnected && store.accountKind == .apiKey && store.hasSavedAPIKey, "Saved API key should configure the connection")
            try require(keys.snapshot().reads == 1, "API connection must read the saved key")
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(fixture.count("started") == 1 && !store.isConnecting, "Bootstrap notification caused a reconnect loop")
            try require(store.isLoggedIn, "Bootstrap account event unexpectedly cleared account state")
            store.connect(); try await idle(store)
            try await Task.sleep(nanoseconds: 150_000_000)
            try require(keys.snapshot().reads == 2 && fixture.count("started") == 2, "Each deliberate reconnect must read the current key exactly once")
            try require(fixture.requests("account/login/start").allSatisfy { $0["keyLabel"] as? String == "original" }, "Wrong key reached fixture authentication")
        }
    }

    @MainActor private static func missingKey() async throws {
        try await exercise { store, keys, fixture in
            store.connect(); try await idle(store)
            try require(store.isConnected, "Initial Codex connection failed")
            store.selectAuthenticationMode(.openAIAPIKey); try await idle(store)
            try await wait("previous authenticated child to exit") { fixture.runningChildren().isEmpty }
            try require(store.authenticationMode == .openAIAPIKey && !store.isConnected && !store.isLoggedIn,
                        "Missing key must leave selected API mode disconnected")
            try require(!store.hasSavedAPIKey && keys.snapshot().reads == 1, "Missing key state is incorrect")
            try require(fixture.count("started") == 1, "Missing key must not fall back to a new Codex process")
            try require(store.error != nil, "Missing key should provide an actionable error")
        }
    }

    @MainActor private static func saveReplaceRemove() async throws {
        try await exercise(mode: .openAIAPIKey) { store, keys, fixture in
            store.saveAPIKey("  " + originalKey + "\n"); try await idle(store)
            try require(store.isConnected && store.hasSavedAPIKey, "Saving a valid key should connect")
            try require(keys.snapshot().saves == 1 && keys.snapshot().reads == 1, "Save should connect using the stored value")
            store.saveAPIKey(replacementKey); try await idle(store)
            try require(keys.snapshot().saves == 2 && keys.snapshot().reads == 2, "Replacement must be persisted and re-read")
            try require(fixture.requests("account/login/start").last?["keyLabel"] as? String == "replacement", "Replacement was not used for next connection")
            store.removeAPIKey(); try await idle(store)
            try await wait("removed-key child to exit") { fixture.runningChildren().isEmpty }
            try require(!store.hasSavedAPIKey && !keys.snapshot().hasKey, "Removal did not clear saved-key state")
            try require(store.authenticationMode == .openAIAPIKey && !store.isConnected && !store.isLoggedIn,
                        "Removal must remain disconnected in API mode")
            try require(keys.snapshot().deletes == 1 && fixture.count("started") == 2, "Removal must not reconnect or fall back")
        }
    }

    @MainActor private static func deniedOperations() async throws {
        try await exercise(mode: .openAIAPIKey, key: originalKey) { store, keys, fixture in
            keys.configure(readDenied: true)
            store.connect(); try await idle(store)
            try require(!store.isConnected && store.error != nil && fixture.count("started") == 0, "Denied read must not launch a process")
            try noLeakedErrors(store)
            keys.configure()
            store.connect(); try await idle(store)
            try require(store.isConnected && store.hasSavedAPIKey, "Retry after denied read should connect")
            keys.configure(saveDenied: true)
            store.saveAPIKey(replacementKey); try await idle(store)
            try await wait("save-denied child to exit") { fixture.runningChildren().isEmpty }
            try require(!store.isConnected && keys.snapshot().hasKey && store.hasSavedAPIKey, "Denied replacement must preserve stored-key presence and disconnect")
            try require(store.error != nil, "Denied save should report an error")
            try noLeakedErrors(store)
            keys.configure(deleteDenied: true)
            store.removeAPIKey(); try await idle(store)
            try require(store.hasSavedAPIKey && keys.snapshot().hasKey && !store.isConnected, "Denied deletion must preserve key state without reconnecting")
            try require(store.error != nil, "Denied deletion should report an error")
            try noLeakedErrors(store)
            keys.configure()
            store.connect(); try await idle(store)
            try require(fixture.requests("account/login/start").last?["keyLabel"] as? String == "original", "Denied replacement changed stored credential")
        }
    }

    @MainActor private static func busyGuards() async throws {
        try await exercise(mode: .openAIAPIKey, key: originalKey) { store, keys, fixture in
            store.connect(); try await idle(store)
            let note = store.createNote(title: "Busy fixture", model: "model-a", effort: "medium")
            note.isBusy = true
            let before = keys.snapshot(), launches = fixture.count("started")
            try require(!store.canChangeAuthentication, "Active note must disable authentication changes")
            store.selectAuthenticationMode(.codexSignIn)
            store.saveAPIKey(replacementKey)
            store.removeAPIKey()
            store.useLocalCLI()
            store.connect()
            store.login()
            try await Task.sleep(nanoseconds: 150_000_000)
            try require(keys.snapshot() == before && fixture.count("started") == launches, "Busy note allowed credential or connection mutation")
            try require(store.authenticationMode == .openAIAPIKey && store.isConnected, "Busy guard changed active authentication")
            try require(store.cliPath == fixture.executable.path, "Busy guard allowed switching the CLI path")
            note.isBusy = false
            try require(store.canChangeAuthentication, "Authentication must unlock when the turn finishes")
        }
    }

    @MainActor private static func restoreConversation() async throws {
        try await exercise(key: originalKey, existingThread: true) { store, _, fixture in
            store.connect(); try await idle(store)
            store.selectAuthenticationMode(.openAIAPIKey); try await idle(store)
            try require(store.notes.count == 1, "Authentication change replaced the note")
            let note = store.notes[0]
            try require(note.id == fixture.noteID && note.threadID == "thread-existing", "Authentication change replaced conversation identity")
            try require(note.draft == "Retain this unsent draft." && note.composerHeight == 81, "Authentication change altered unsent draft settings")
            try require(note.messages.map(\.text) == ["Previous question", "Previous answer"], "Existing history was not restored")
            try require(fixture.requests("thread/resume").count == 2, "Each authentication connection must resume existing thread")
            try require(fixture.requests("thread/resume").allSatisfy { $0["threadId"] as? String == "thread-existing" }, "Wrong conversation resumed")
            try require(fixture.requests("thread/start").isEmpty && fixture.requests("turn/start").isEmpty, "Restore must not create a thread or resend a message")
        }
    }

    @MainActor private static func earlyCompletionGuard() async throws {
        try await exercise(mode: .openAIAPIKey, key: originalKey, existingThread: true) { store, keys, fixture in
            store.connect(); try await idle(store)
            let note = store.notes[0]
            note.draft = "A fixture-only message."
            store.send(note)
            do {
                try await wait("completion before request response") {
                    (fixture.count("completion-sent") == 1 && !note.isBusy) || note.error != nil
                }
            } catch {
                let methods = fixture.events().compactMap { $0["method"] as? String }.joined(separator: ",")
                throw CheckFailure(description: "Early completion timeout: busy=\(note.isBusy), authenticated=\(store.isLoggedIn), pendingLocalMessage=\(note.pendingUserMessageID != nil), messages=\(note.messages.count), completed=\(fixture.count("completion-sent")), response=\(fixture.count("turn-response")), requests=\(methods)")
            }
            if let error = note.error {
                let sanitized = error.replacingOccurrences(of: originalKey, with: "[REDACTED]")
                    .replacingOccurrences(of: replacementKey, with: "[REDACTED]")
                throw CheckFailure(description: "Fixture send failed before completion: \(sanitized)")
            }
            try require(fixture.count("turn-response") == 0, "Fixture did not hold the send response open")
            try require(!store.canChangeAuthentication, "Completion unlocked authentication before send returned")
            let before = keys.snapshot(), launches = fixture.count("started")
            store.selectAuthenticationMode(.codexSignIn)
            store.saveAPIKey(replacementKey)
            store.removeAPIKey()
            store.useLocalCLI()
            store.connect()
            try require(keys.snapshot() == before && fixture.count("started") == launches,
                        "Pending send response allowed credential mutation")
            try require(store.cliPath == fixture.executable.path, "Pending send response allowed switching the CLI path")
            try await wait("send response releases authentication guard") { store.canChangeAuthentication }
            try require(fixture.count("turn-response") == 1 && store.authenticationMode == .openAIAPIKey,
                        "Authentication changed while completing the send")
            try require(note.error == nil, "Fixture send did not complete successfully")
        }
    }

    @MainActor private static func delayedReadShutdown() async throws {
        try await exercise(mode: .openAIAPIKey, key: originalKey) { store, keys, fixture in
            keys.configure(readDelay: 0.2)
            store.connect()
            try await wait("delayed credential read to begin") { keys.snapshot().reads == 1 }
            await store.shutdown()
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(fixture.count("started") == 0 && fixture.runningChildren().isEmpty,
                        "Shutdown during delayed key read launched an orphan child")
            try require(!store.isConnecting && !store.isConnected, "Shutdown left connecting UI state")
            try require(!store.canChangeAuthentication, "Shutdown store allowed new authentication work")
        }
    }

    @MainActor private static func previewIsolation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let keys = MemoryKeyStore(key: originalKey)
        keys.configure(readDenied: true)
        let store = AppStore(directory: fixture.directory, apiKeyStore: keys,
                             previewAuthentication: (.openAIAPIKey, true))
        try require(store.authenticationMode == .openAIAPIKey && store.hasSavedAPIKey,
                    "Preview authentication display state not applied")
        try require(keys.snapshot().reads == 0 && fixture.count("started") == 0,
                    "Preview touched credentials or started CLI")
        await store.shutdown()
    }
}
