import AppKit
import Foundation
import FloatingAICore

// Production AppStore plus both real client adapters, against fake local JSONL
// processes. No network, actual CLI, Keychain, login, or user note is accessed.
private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                     file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition() { throw CheckFailure(message: "\(message) [\(file):\(line)]") }
}

private final class EmptyKeyStore: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return nil }
    func save(_ key: String) throws { throw CheckFailure(message: "Unexpected credential save") }
    func delete() throws { throw CheckFailure(message: "Unexpected credential deletion") }
}

private struct Fixture {
    static let session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let directory: URL
    let codex: URL
    let claude: URL
    let configuration: URL
    let codexNoteID = UUID()
    let claudeNoteID = UUID()

    init(emptyNotes: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floating-ai-providers-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        codex = directory.appendingPathComponent("fake-codex")
        claude = directory.appendingPathComponent("fake-claude")
        configuration = directory.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for executable in [codex, claude] {
            try Self.server.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        var document = AppDocument()
        document.cliPath = codex.path
        document.claudeCLIPath = claude.path
        document.claudeEnabled = true
        document.defaultModelID = "shared"
        document.defaultEffort = "medium"
        // The Codex note deliberately omits provider and authentication fields,
        // matching a document saved by the previous release.
        document.notes = [
            StoredNote(id: codexNoteID, title: "Codex fixture", model: "shared", effort: "medium",
                       threadID: Self.session, draft: "Saved Codex draft"),
            StoredNote(id: claudeNoteID, title: "Claude fixture", model: "shared", effort: "medium",
                       threadID: Self.session, draft: "Saved Claude draft", provider: .claude)
        ]
        if emptyNotes { document.notes = [] }
        try NotePersistence(directory: directory).save(document)
        try "Synthetic Codex history".write(to: codexHistory, atomically: true, encoding: .utf8)
        let work = directory.appendingPathComponent("ClaudeChat", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let canonical = realpath(work.path, nil) else { throw CheckFailure(message: "Could not resolve fixture workspace") }
        let nativePath = String(cString: canonical)
        free(canonical)
        let encoded = nativePath.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let project = configuration.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let previous: [String: Any] = ["uuid": "past-user", "sessionId": Self.session, "type": "user",
                                      "message": ["role": "user", "content": "Previous Claude question"]]
        var transcript = try JSONSerialization.data(withJSONObject: previous)
        transcript.append(0x0a)
        try transcript.write(to: project.appendingPathComponent(Self.session + ".jsonl"))
    }

    var codexHistory: URL { directory.appendingPathComponent("codex-history-" + Self.session + ".json") }
    var claudeHistory: URL {
        let path = directory.appendingPathComponent("ClaudeChat").path
        let work: String
        if let resolved = realpath(path, nil) { work = String(cString: resolved); free(resolved) }
        else { work = path }
        let encoded = work.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return configuration.appendingPathComponent("projects").appendingPathComponent(encoded)
            .appendingPathComponent(Self.session + ".jsonl")
    }

    @MainActor func store(keys: EmptyKeyStore) -> AppStore {
        let environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": configuration.path]
        return AppStore(directory: directory, apiKeyStore: keys,
                        client: CodexClient(requestTimeout: 3, environment: environment),
                        claudeClient: ClaudeClient(requestTimeout: 3, environment: environment),
                        fileToolURL: URL(fileURLWithPath: "/usr/bin/true"))
    }

    func signal(_ name: String, value: String = "ready") throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func removeSignal(_ name: String) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    func events() -> [[String: Any]] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    func requests(provider: String, method: String) -> [[String: Any]] {
        events().filter { $0["provider"] as? String == provider && $0["method"] as? String == method }
    }
    func submissions(provider: ChatProvider) -> [[String: Any]] {
        requests(provider: provider.rawValue, method: provider == .codex ? "turn/start" : "user")
    }
    func preparationCount(provider: ChatProvider) -> Int {
        if provider == .claude { return requests(provider: "claude", method: "initialize").count }
        return requests(provider: "codex", method: "thread/start").count + requests(provider: "codex", method: "thread/resume").count
    }
    func blockMetadataWrites() throws {
        let document = directory.appendingPathComponent("notes.json")
        try FileManager.default.moveItem(at: document, to: directory.appendingPathComponent("send-snapshot-backup.json"))
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: false)
    }
    func restoreMetadataWrites() throws {
        let document = directory.appendingPathComponent("notes.json")
        try FileManager.default.removeItem(at: document)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("send-snapshot-backup.json"), to: document)
    }
    func durableSendSnapshot() throws -> AppDocument {
        try JSONDecoder().decode(AppDocument.self, from: Data(contentsOf: directory.appendingPathComponent("send-snapshot-backup.json")))
    }
    func runningChildren() -> Set<Int> {
        let values = events()
        let started = Set(values.filter { $0["event"] as? String == "started" }.compactMap { $0["pid"] as? Int })
        let stopped = Set(values.filter { $0["event"] as? String == "stopped" }.compactMap { $0["pid"] as? Int })
        return started.subtracting(stopped)
    }

    private static let server = #"""
#!/usr/bin/python3
import atexit, json, os, re, signal, sys, threading, time, uuid
root = os.path.dirname(os.path.realpath(__file__))
provider = 'claude' if os.path.basename(__file__).endswith('claude') else 'codex'
pid = os.getpid()
lock = threading.Lock()
effort = 'medium'
session = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
for flag in ('--resume', '--session-id'):
    if flag in sys.argv: session = sys.argv[sys.argv.index(flag) + 1]
def record(event, **fields):
    fields.update(event=event, pid=pid, provider=provider)
    fd = os.open(os.path.join(root, 'events.jsonl'), os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try: os.write(fd, (json.dumps(fields) + '\n').encode())
    finally: os.close(fd)
record('started', arguments=sys.argv[1:])
atexit.register(lambda: record('stopped'))
signal.signal(signal.SIGTERM, lambda *_args: sys.exit(0))
if provider == 'claude' and 'auth' in sys.argv and 'status' in sys.argv:
    print(json.dumps({'loggedIn':True,'authMethod':'oauth'}))
    sys.exit(0)
def send(value):
    with lock: os.write(1, (json.dumps(value) + '\n').encode())
def crash_watch():
    while True:
        if os.path.exists(os.path.join(root, 'crash-' + provider)):
            record('stopped')
            os._exit(0)
        time.sleep(0.01)
threading.Thread(target=crash_watch, daemon=True).start()
def wait_release():
    while not os.path.exists(os.path.join(root, 'release-' + provider)): time.sleep(0.01)
def fail_send_save(stage):
    if not os.path.exists(os.path.join(root, 'fail-send-' + stage + '-' + provider)): return False
    path = os.path.join(root, 'notes.json')
    if not os.path.isfile(path): return False
    os.rename(path, os.path.join(root, 'send-snapshot-backup.json'))
    os.mkdir(path)
    record('save-blocked', stage=stage)
    return True
def record_send_journal():
    try:
        with open(os.path.join(root, 'notes.json')) as file: document = json.load(file)
        note = next(note for note in document['notes'] if note.get('provider', 'codex') == provider
                    and note.get('threadID') == session and note.get('pendingSubmission'))
        pending = note['pendingSubmission']
        valid = pending['text'] == note['draft'] and pending['attachments'] == note['attachments']
        record('send-journal', valid=valid, note=note['id'], text=pending['text'])
    except (OSError, ValueError, KeyError, StopIteration): record('send-journal', valid=False)
def codex_finish(turn):
    wait_release()
    item = {'id':'shared-assistant','type':'agentMessage','text':'Codex reply'}
    value = {'method':'turn/completed','params':{'threadId':session,'turn':{'id':turn,'status':'completed','items':[item]}}}
    send(value)
    send(value) # Native completion replay must not affect either conversation.
def append_native(value):
    project = re.sub('[^a-zA-Z0-9]', '-', os.getcwd())
    path = os.path.join(os.environ['CLAUDE_CONFIG_DIR'], 'projects', project, session + '.jsonl')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a') as file: file.write(json.dumps(value) + '\n')
def claude_finish(user_id):
    wait_release()
    append_native({'type':'assistant','sessionId':session,'uuid':str(uuid.uuid4()),'parentUuid':user_id,
        'message':{'id':'shared-assistant','role':'assistant','content':[{'type':'text','text':'Claude reply'}]}})
    send({'type':'assistant','session_id':session,'uuid':str(uuid.uuid4()),
          'message':{'id':'shared-assistant','role':'assistant','content':[{'type':'text','text':'Claude reply'}]}})
    send({'type':'result','subtype':'success','session_id':session,'uuid':str(uuid.uuid4()),'result':'Claude reply'})
thread_configs = {}
def history():
    try:
        with open(os.path.join(root, 'codex-history-' + session + '.json')) as file:
            value=json.load(file)
        if isinstance(value,dict) and 'thread' in value: return value
    except (ValueError,FileNotFoundError): pass
    return {'thread':{'id':session,'turns':[{'id':'history','items':[
        {'id':'past-user','type':'userMessage','content':[{'type':'text','text':'Previous Codex question'}]}]}]},'modelProvider':'openai'}
for line in sys.stdin:
    message = json.loads(line)
    if provider == 'codex':
        method, params = message.get('method'), message.get('params', {})
        record('request', method=method, model=params.get('model'), thread=params.get('threadId'), params=params)
        result = {}
        if method == 'initialize':
            version_path=os.path.join(root, 'codex-version')
            version=open(version_path).read().strip() if os.path.exists(version_path) else '0.163.0'
            result = {'userAgent':'codex/'+version+' (multi-provider-fixture)'}
        elif method == 'config/read': result = {'config':{'mcp_servers':{},'model_provider':'openai','model_providers':{}}}
        elif method == 'configRequirements/read': result = {'requirements':{}}
        elif method == 'account/read': result = {'account':{'type':'chatgpt'}}
        elif method == 'model/list': result = {'data':[{'id':'catalog-shared','model':'shared','displayName':'Shared Model',
            'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':'medium','description':'Balanced'}],
            'inputModalities':['text','image'],'isDefault':True,'hidden':False}]}
        elif method in ('thread/start','thread/read','thread/resume'):
            history_path = os.path.join(root, 'codex-history-' + params.get('threadId', session) + '.json')
            if method != 'thread/start' and not os.path.exists(history_path):
                send({'id':message['id'],'error':{'code':-32600,'message':'no rollout found for thread id '+params['threadId']}})
                continue
            result = history()
            if method in ('thread/start','thread/resume'): thread_configs[session]=params.get('config',{})
            if method in ('thread/start','thread/resume'): fail_send_save('prepared')
        elif method == 'thread/unsubscribe': result={'status':'unsubscribed'}
        elif method == 'mcpServerStatus/list':
            name=params['serverName']; config=thread_configs[params['threadId']]['mcp_servers.'+name]
            assert config['enabled_tools']==['read_attachment'] and config['enabled'] is True
            assert os.path.isdir(config['args'][2]) and os.path.isdir(config['args'][4])
            result={'data':[{'name':name,'runtimeStatus':'connected','tools':{'read_attachment':{'name':'read_attachment'}},'toolsError':None}], 'nextCursor':None}
        elif method == 'thread/delete':
            if os.path.exists(os.path.join(root, 'hold-delete-codex')):
                while not os.path.exists(os.path.join(root, 'release-delete-codex')): time.sleep(0.01)
            history_path = os.path.join(root, 'codex-history-' + params['threadId'] + '.json')
            if os.path.exists(os.path.join(root, 'fail-delete-codex')):
                send({'id':message['id'],'error':{'code':-32600,'message':'Fixture cannot delete history'}})
                continue
            if not os.path.exists(history_path):
                send({'id':message['id'],'error':{'code':-32600,'message':'no rollout found for thread id '+params['threadId']}})
                continue
            os.unlink(history_path)
            if os.path.exists(os.path.join(root, 'fail-delete-commit')):
                os.rename(os.path.join(root, 'notes.json'), os.path.join(root, 'deletion-snapshot-backup.json'))
                os.mkdir(os.path.join(root, 'notes.json'))
            send({'method':'thread/deleted','params':{'threadId':params['threadId']}})
        elif method == 'turn/start':
            record_send_journal()
            turn_path = os.path.join(root, 'turn-id')
            turn = open(turn_path).read() if os.path.exists(turn_path) else 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            saved=history()
            saved['thread']['turns'].append({'id':turn,'items':[
                {'id':'user-'+str(uuid.uuid4()),'type':'userMessage','content':params['input']},
                {'id':'shared-assistant','type':'agentMessage','text':'Codex reply'}]})
            with open(os.path.join(root, 'codex-history-' + session + '.json'), 'w') as file: json.dump(saved,file)
            save_failed = fail_send_save('accepted')
            result = {'turn':{'id':turn,'status':'inProgress'}}
            send({'method':'turn/started','params':{'threadId':session,'turn':{'id':turn}}})
            send({'method':'item/agentMessage/delta','params':{'threadId':session,'turnId':turn,'itemId':'shared-assistant','delta':'Codex reply'}})
            if save_failed: codex_finish(turn) # Exercise completion before the send continuation resumes.
            else: threading.Thread(target=codex_finish, args=(turn,), daemon=True).start()
        if 'id' in message: send({'id':message['id'],'result':result})
    else:
        if message.get('type') == 'control_request':
            request = message['request']
            method = request['subtype']
            record('request', method=method, model=request.get('model'), params=request, session=session)
            result = {}
            if method in ('initialize','list_models'):
                result = {'claude_code_version':'2.1.307','commands':[],
                    'account':{'tokenSource':'oauth','apiKeySource':'none'},
                    'models':[{'value':'shared','displayName':'Shared Model','supportsImages':True,'supportsEffort':True,
                        'supportedEffortLevels':['medium','high'],'defaultEffort':'medium','isDefault':True}]}
            elif method == 'mcp_status':
                configured=json.loads(sys.argv[sys.argv.index('--mcp-config')+1]).get('mcpServers',{})
                result={'mcpServers':[{'name':name,'source':'sdk','status':'connected','tools':[{'name':'read_attachment'}]} for name in configured]}
            elif method == 'apply_flag_settings': effort = request.get('settings',{}).get('effortLevel', effort)
            elif method == 'get_settings': result = {'effective':{'disableAllHooks':True},'applied':{'effort':effort}}
            if method == 'initialize': fail_send_save('prepared')
            if method == 'get_settings': fail_send_save('controls')
            send({'type':'control_response','response':{'subtype':'success','request_id':message['request_id'],'response':result}})
        elif message.get('type') == 'user':
            record('request', method='user', session=message.get('session_id'), message=message['message'])
            record_send_journal()
            if os.path.exists(os.path.join(root, 'crash-before-ack')): sys.exit(0)
            append_native({'type':'user','sessionId':session,'uuid':message['uuid'],'parentUuid':'past-user','message':message['message']})
            save_failed = fail_send_save('accepted')
            send(message) # --replay-user-messages receipt follows persistence.
            send({'type':'stream_event','session_id':session,'uuid':str(uuid.uuid4()),
                  'event':{'type':'message_start','message':{'id':'shared-assistant'}}})
            send({'type':'stream_event','session_id':session,'uuid':str(uuid.uuid4()),
                  'event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'Claude reply'}}})
            if save_failed: claude_finish(message['uuid'])
            else: threading.Thread(target=claude_finish, args=(message['uuid'],), daemon=True).start()
"""#
}

@main private struct MultiProviderChecks {
    @MainActor static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("legacy notes retain Codex and never read app credentials", legacyDefaults),
            ("merged models keep native ID collisions and names-only labels", mergedModels),
            ("parallel streams isolate identical thread, turn, and item IDs", parallelStreams),
            ("authentication and connection busy guards are provider scoped", busyGuards),
            ("one provider disconnecting preserves the other provider", independentDisconnects),
            ("Claude crash before acknowledgment retains draft across restart", unacknowledgedClaude),
            ("fresh sends require a durable pending message before preparation", { try await sendPersistenceBeforePreparation(fresh: true) }),
            ("existing sends require a durable pending message before preparation", { try await sendPersistenceBeforePreparation(fresh: false) }),
            ("new conversation IDs must persist before dispatch and survive explicit retry", { try await sendPersistenceAfterPreparation(fresh: true) }),
            ("restored conversation preparation requires a second durable save", { try await sendPersistenceAfterPreparation(fresh: false) }),
            ("Claude model and effort preparation precedes the final durable save", {
                try await sendPersistenceAfterPreparation(fresh: false, providers: [.claude], stage: "controls")
            }),
            ("accepted sends survive failed commits and reconcile without resending", sendPersistenceAfterAcceptance),
            ("unreadable note metadata blocks both providers without replacing the original", sendPersistenceDisabled),
            ("provider, session, title, and drafts survive restart without sends", restoreMetadata),
            ("cross-provider copy preserves original and waits for explicit send", copyConversation),
            ("fresh cross-provider notes exclude history and preserve the original", freshConversation),
            ("first document sends configure per-note readers and restore file cards", { try await documentAttachments(fresh: true) }),
            ("existing conversations gain scoped file readers without changing native IDs", { try await documentAttachments(fresh: false) }),
            ("unused library documents keep Codex 0.151 text chat available", unusedLibraryDocument),
            ("permanent deletion isolates matching provider IDs and survives restart", deletionIsolation),
            ("busy notes reject deletion while an unrelated idle note can be deleted", deletionBusyGuards),
            ("failed deletion survives restart without restore or resend and can retry", deletionFailureRecovery),
            ("durable deletion markers protect failures before and after backend removal", deletionPersistenceFailures),
            ("deletion keeps shared images until their final note and preserves external files", deletionSharedImages),
            ("batch deletion removes hidden notes across providers exactly once without showing them", batchDeletionHiddenNotes),
            ("partial batch failure keeps only the hidden retry note across restart", batchDeletionPartialFailure),
            ("batch deletion rejects busy selections and reserves every queued note", batchDeletionGuards)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
            fflush(stdout)
        }
        print("Multi-provider checks: \(checks.count - failures)/\(checks.count) passed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func wait(_ message: String, timeout: TimeInterval = 6,
                                       until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw CheckFailure(message: "Timed out: \(message)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func connect(_ store: AppStore) async throws {
        store.connectAll()
        try await wait("both connections") { !store.isConnecting && !store.claudeIsConnecting }
        try require(store.isConnected && store.isLoggedIn, "Codex failed: \(store.error ?? store.connectionStatus)")
        try require(store.claudeIsConnected && store.claudeIsLoggedIn, "Claude failed: \(store.claudeError ?? store.claudeConnectionStatus)")
        try require(store.notes.allSatisfy { $0.error == nil }, "Fixture histories must restore before exercising routing")
    }

    @MainActor private static func exercise(emptyNotes: Bool = false, _ body: (AppStore, EmptyKeyStore, Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(emptyNotes: emptyNotes), keys = EmptyKeyStore()
        let store = fixture.store(keys: keys)
        do {
            try await body(store, keys, fixture)
            await store.shutdown()
            try await wait("fixture child processes to exit") { fixture.runningChildren().isEmpty }
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await store.shutdown()
            try? await wait("fixture cleanup") { fixture.runningChildren().isEmpty }
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @MainActor private static func notes(_ store: AppStore) throws -> (NoteState, NoteState) {
        guard let codex = store.notes.first(where: { $0.provider == .codex }),
              let claude = store.notes.first(where: { $0.provider == .claude }) else {
            throw CheckFailure(message: "Fixture must contain both provider notes")
        }
        return (codex, claude)
    }

    @MainActor private static func legacyDefaults() async throws {
        try await exercise { store, keys, fixture in
            let (codex, claude) = try notes(store)
            try require(codex.id == fixture.codexNoteID && claude.id == fixture.claudeNoteID, "Legacy note changed providers")
            try require(store.defaultProvider == .codex && store.authenticationMode == .codexSignIn, "Legacy defaults were changed")
            try require(codex.threadID == Fixture.session && codex.draft == "Saved Codex draft", "Legacy conversation metadata changed")
            try await connect(store)
            try require(keys.readCount == 0, "Existing CLI authentication must not read the application Keychain")
            try require(fixture.requests(provider: "codex", method: "account/login/start").isEmpty, "Connect must not trigger a login flow")
            try require(fixture.requests(provider: "claude", method: "user").isEmpty, "Model discovery must not send a Claude prompt")
        }
    }

    @MainActor private static func mergedModels() async throws {
        try await exercise { store, _, _ in
            try await connect(store)
            try require(Set(store.mergedModels.map(\.id)) == ["codex:shared", "claude:shared"], "Native model IDs collided")
            try require(store.mergedModels.allSatisfy { $0.displayName == "Shared Model" }, "Model names gained provider prefixes")
            let note = store.createNote(title: "", model: "codex:shared", effort: "medium")
            store.selectModel("claude:shared", for: note)
            try require(note.provider == .claude && note.model == "shared", "Changing an empty note did not route to Claude")
            try require(note.title == "Ask Me Anything" && note.threadID == nil, "Empty-note selection created a session or changed the default title")
            try require(store.defaultModelSelectionID == "claude:shared", "Last selection lost its provider")
        }
    }

    @MainActor private static func parallelStreams() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            claude.draft = "Claude question"; store.send(claude)
            try await wait("Claude active turn") { claude.activeTurnID != nil && claude.messages.contains(where: { $0.text == "Claude reply" }) }
            let sharedTurn = claude.activeTurnID!
            try fixture.signal("turn-id", value: sharedTurn)
            codex.draft = "Codex question"; store.send(codex)
            try await wait("both independent streams") {
                codex.isBusy && claude.isBusy && codex.activeTurnID == sharedTurn &&
                codex.messages.contains(where: { $0.text == "Codex reply" })
            }
            try require(codex.threadID == claude.threadID, "Fixture did not exercise session ID collision")
            try require(!codex.messages.contains(where: { $0.text.contains("Claude reply") }), "Claude delta entered Codex conversation")
            try require(!claude.messages.contains(where: { $0.text.contains("Codex reply") }), "Codex delta entered Claude conversation")
            try fixture.signal("release-codex")
            try await wait("Codex completion") { !codex.isBusy }
            try require(claude.isBusy, "Codex completion stopped Claude despite a different provider")
            try fixture.signal("release-claude")
            try await wait("Claude completion") { !claude.isBusy }
            try require(codex.messages.filter { $0.role == "assistant" }.map(\.text) == ["Codex reply"], "Codex completion duplicated or mixed replies")
            try require(claude.messages.filter { $0.role == "assistant" }.map(\.text) == ["Claude reply"], "Claude completion duplicated or mixed replies")
            try require(fixture.requests(provider: "codex", method: "turn/start").first?["model"] as? String == "shared", "Codex received a qualified model ID")
            try require(fixture.requests(provider: "claude", method: "set_model").last?["model"] as? String == "shared", "Claude received a qualified model ID")
            try require(codex.pendingSubmission == nil && claude.pendingSubmission == nil, "Completed submissions remain pending")
        }
    }

    @MainActor private static func busyGuards() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            claude.draft = "Keep Claude busy"; store.send(claude)
            try await wait("Claude response starts") { claude.activeTurnID != nil }
            try require(store.canChangeAuthentication && !store.canChangeClaudeConnection, "Claude blocks an unrelated Codex setting")
            store.disconnectClaude()
            try require(store.claudeEnabled && claude.isBusy, "A busy Claude connection was disconnected")
            store.selectAuthenticationMode(.openAIAPIKey)
            try await wait("Codex authentication change") { !store.isConnecting && !store.isUpdatingAuthentication }
            try require(store.authenticationMode == .openAIAPIKey && !store.isConnected, "Codex authentication change did not apply")
            try require(store.claudeIsConnected && claude.isBusy, "Changing Codex authentication interrupted Claude")
            try fixture.signal("release-claude")
            try await wait("Claude finish") { !claude.isBusy && store.canChangeClaudeConnection }
            store.selectAuthenticationMode(.codexSignIn)
            try await wait("Codex reconnect") { !store.isConnecting && store.isConnected }
            codex.draft = "Keep Codex busy"; store.send(codex)
            try await wait("Codex response starts") { codex.activeTurnID != nil }
            try require(!store.canChangeAuthentication && store.canChangeClaudeConnection, "Codex blocks an unrelated Claude setting")
            store.selectAuthenticationMode(.openAIAPIKey)
            try require(store.authenticationMode == .codexSignIn, "A busy Codex changed authentication")
            store.disconnectClaude()
            try await wait("Claude disconnected") { !store.claudeIsConnecting }
            try require(!store.claudeEnabled && codex.isBusy && store.isConnected, "Disconnecting idle Claude interrupted Codex")
            try fixture.signal("release-codex")
            try await wait("Codex finish") { !codex.isBusy }
        }
    }

    @MainActor private static func independentDisconnects() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            claude.draft = "Claude survives another provider crash"; store.send(claude)
            try await wait("Claude starts") { claude.activeTurnID != nil }
            try fixture.signal("crash-codex")
            try await wait("Codex disconnection") { !store.isConnected }
            try require(store.claudeIsConnected && claude.isBusy && claude.error == nil, "Codex crash damaged Claude state")
            try require(store.mergedModels.map(\.id) == ["claude:shared"], "Codex crash cleared the live Claude model")
            try fixture.signal("release-claude")
            try await wait("Claude finishes") { !claude.isBusy }
            try fixture.removeSignal("crash-codex")
            store.connect()
            try await wait("Codex restored") { !store.isConnecting && store.isConnected }
            codex.draft = "Preserve this Codex draft"
            try fixture.signal("crash-claude")
            try await wait("Claude disconnection") { !store.claudeIsConnected }
            try require(store.isConnected && store.isLoggedIn && codex.draft == "Preserve this Codex draft", "Claude crash changed Codex state")
            try require(store.mergedModels.map(\.id) == ["codex:shared"], "Claude crash cleared the live Codex model")
        }
    }

    @MainActor private static func restoreMetadata() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            codex.title = "Saved first note"; codex.draft = "First unsent draft"
            claude.title = "Saved second note"; claude.draft = "Second unsent draft"
            store.persist()
            await store.shutdown()
            let restored = fixture.store(keys: keys)
            do {
                let (first, second) = try notes(restored)
                try require(first.id == codex.id && second.id == claude.id, "Restart changed note identities")
                try require(first.threadID == Fixture.session && second.threadID == Fixture.session, "Restart changed native sessions")
                try require(first.title == "Saved first note" && second.title == "Saved second note", "Restart lost note titles")
                try require(first.draft == "First unsent draft" && second.draft == "Second unsent draft", "Restart lost drafts")
                try await connect(restored)
                try require(first.messages.first?.text == "Previous Codex question", "Codex resumed the wrong history")
                try require(second.messages.first?.text == "Previous Claude question", "Claude resumed the wrong history")
                try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty && fixture.requests(provider: "claude", method: "user").isEmpty,
                            "Restoration automatically sent a message")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func unacknowledgedClaude() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (_, claude) = try notes(store)
            let draft = "Message awaiting Claude acknowledgment"
            claude.draft = draft
            try fixture.signal("crash-before-ack")
            store.send(claude)
            try await wait("unacknowledged send fails") {
                !claude.isBusy && claude.needsReconciliation && store.canChangeClaudeConnection
            }
            try require(claude.draft == draft && claude.pendingSubmission?.text == draft,
                        "A pipe write without Claude acknowledgment discarded the draft")
            try require(claude.threadID == Fixture.session, "Unconfirmed send changed the native session")
            await store.shutdown()
            try fixture.removeSignal("crash-before-ack")
            let restored = fixture.store(keys: keys)
            do {
                let (_, pending) = try notes(restored)
                try require(pending.pendingSubmission?.text == draft && pending.draft == draft,
                            "Restart lost the unacknowledged request")
                restored.connectAll()
                try await wait("restore after unacknowledged send") { !restored.isConnecting && !restored.claudeIsConnecting }
                try require(restored.claudeIsConnected && pending.pendingSubmission?.text == draft && pending.draft == draft,
                            "Restoring older history discarded an unacknowledged request")
                try require(fixture.requests(provider: "claude", method: "user").count == 1,
                            "Reconnecting automatically resent an unacknowledged Claude message")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func attachPersistenceFixture(to note: NoteState, fixture: Fixture, text: String) throws -> StoredAttachment {
        let original = fixture.directory.appendingPathComponent("send-\(note.id.uuidString).txt")
        try "Synthetic document retained through save failures".write(to: original, atomically: true, encoding: .utf8)
        let attachment = try AttachmentStore(directory: fixture.directory).importFile(original, noteID: note.id)
        note.attachments = [attachment]
        note.fileLibrary = [attachment]
        note.draft = text
        return attachment
    }

    @MainActor private static func requireUnsent(_ note: NoteState, draft: String, attachment: StoredAttachment) throws {
        try require(note.draft == draft && note.attachments == [attachment] && note.fileLibrary == [attachment],
                    "A failed save changed an unsent draft or its attachments")
        try require(!note.isBusy && !note.isStopping && note.pendingSubmission == nil && note.pendingUserMessageID == nil && !note.needsReconciliation,
                    "A known-unsent request retained busy, pending, or uncertain state")
        try require(note.error?.localizedCaseInsensitiveContains("not sent") == true,
                    "A failed pre-send save did not explain that the message was not sent: \(note.error ?? "no error")")
        try require(FileManager.default.fileExists(atPath: attachment.path), "A failed save removed the attachment copy")
    }

    private static func requireDurableDispatch(_ fixture: Fixture, provider: ChatProvider, draft: String) throws {
        let journals = fixture.events().filter { $0["event"] as? String == "send-journal" && $0["provider"] as? String == provider.rawValue }
        try require(journals.count == 1 && journals[0]["valid"] as? Bool == true && journals[0]["text"] as? String == draft,
                    "Backend dispatch did not see exactly one durable conversation ID and matching pending submission")
    }

    @MainActor private static func sendPersistenceBeforePreparation(fresh: Bool) async throws {
        try await exercise(emptyNotes: fresh) { store, _, fixture in
            try await connect(store)
            for provider in ChatProvider.allCases {
                let note = fresh ? store.createNote(title: "Save gate", model: provider.rawValue + ":shared", effort: "medium")
                    : store.notes.first(where: { $0.provider == provider })!
                let draft = "Preserve \(provider.rawValue) draft before preparing a conversation"
                let attachment = try attachPersistenceFixture(to: note, fixture: fixture, text: draft)
                store.persist()
                let originalThread = note.threadID, preparations = fixture.preparationCount(provider: provider)
                try fixture.blockMetadataWrites()
                store.send(note)
                try await wait("preparation save failure") { !note.isBusy }
                try requireUnsent(note, draft: draft, attachment: attachment)
                try require(note.threadID == originalThread && fixture.preparationCount(provider: provider) == preparations &&
                            fixture.submissions(provider: provider).isEmpty,
                            "A conversation was prepared or a prompt dispatched before saving the pending submission")
                try fixture.restoreMetadataWrites()
                try fixture.signal("release-" + provider.rawValue)
                store.send(note)
                try await wait("explicit retry after fixing storage") {
                    !note.isBusy && note.pendingSubmission == nil && note.draft.isEmpty
                }
                try require(note.error == nil && note.attachments.isEmpty && note.fileLibrary == [attachment] &&
                            fixture.submissions(provider: provider).count == 1,
                            "An explicit retry did not send exactly once and retain reusable files")
                try requireDurableDispatch(fixture, provider: provider, draft: draft)
            }
        }
    }

    @MainActor private static func sendPersistenceAfterPreparation(fresh: Bool,
                                                                  providers: [ChatProvider] = ChatProvider.allCases,
                                                                  stage: String = "prepared") async throws {
        for provider in providers {
            try await exercise(emptyNotes: fresh) { store, _, fixture in
                try await connect(store)
                let note = fresh ? store.createNote(title: "Conversation save gate", model: provider.rawValue + ":shared", effort: "medium")
                    : store.notes.first(where: { $0.provider == provider })!
                let draft = "Preserve \(provider.rawValue) draft after preparing a conversation"
                let attachment = try attachPersistenceFixture(to: note, fixture: fixture, text: draft)
                let originalThread = note.threadID
                store.persist()
                let signal = "fail-send-" + stage + "-" + provider.rawValue
                try fixture.signal(signal)
                store.send(note)
                try await wait("conversation prepared but metadata save failed") {
                    !note.isBusy && fixture.events().contains { $0["event"] as? String == "save-blocked" }
                }
                try requireUnsent(note, draft: draft, attachment: attachment)
                try require(note.threadID != nil && (fresh || note.threadID == originalThread),
                            "A failed second save lost or replaced the prepared conversation ID")
                try require(fixture.submissions(provider: provider).isEmpty,
                            "A message was dispatched before durably saving its conversation ID and pending submission")
                let snapshot = try fixture.durableSendSnapshot().notes.first { $0.id == note.id }
                try require(snapshot?.threadID == originalThread && snapshot?.pendingSubmission?.text == draft &&
                            snapshot?.pendingSubmission?.attachments == [attachment],
                            "Conversation preparation began without a durable pending message and attachments")
                let preparedID = note.threadID
                let createdCodexThreads = fixture.requests(provider: "codex", method: "thread/start").count
                try fixture.removeSignal(signal)
                try fixture.restoreMetadataWrites()
                try fixture.signal("release-" + provider.rawValue)
                store.send(note)
                try await wait("retry using the prepared conversation") {
                    !note.isBusy && note.pendingSubmission == nil && note.draft.isEmpty
                }
                try require(note.threadID == preparedID && fixture.requests(provider: "codex", method: "thread/start").count == createdCodexThreads &&
                            fixture.submissions(provider: provider).count == 1 && note.fileLibrary == [attachment],
                            "\(provider.rawValue) retry created another conversation, duplicated the send, or lost attachments")
                try requireDurableDispatch(fixture, provider: provider, draft: draft)
            }
        }
    }

    @MainActor private static func sendPersistenceAfterAcceptance() async throws {
        for provider in ChatProvider.allCases {
            try await exercise { store, keys, fixture in
                try await connect(store)
                let note = store.notes.first { $0.provider == provider }!
                let draft = "Accepted \(provider.rawValue) message with a failed storage commit"
                let attachment = try attachPersistenceFixture(to: note, fixture: fixture, text: draft)
                store.persist()
                let signal = "fail-send-accepted-" + provider.rawValue
                try fixture.signal(signal)
                try fixture.signal("release-" + provider.rawValue)
                store.send(note)
                try await wait("accepted send retains acceptance after a failed commit") {
                    !note.isBusy && note.pendingSubmission == nil && note.draft.isEmpty && store.error != nil
                }
                try require(note.attachments.isEmpty && note.fileLibrary == [attachment] && !note.needsReconciliation,
                            "A failed post-acceptance save rolled back accepted state")
                try require(note.error?.localizedCaseInsensitiveContains("not sent") != true &&
                            store.error?.contains("Could not save notes") == true,
                            "A failed post-acceptance save misreported an accepted message as unsent or hid the storage error")
                try requireDurableDispatch(fixture, provider: provider, draft: draft)
                let durable = try fixture.durableSendSnapshot().notes.first { $0.id == note.id }
                try require(durable?.threadID == note.threadID && durable?.pendingSubmission?.text == draft &&
                            durable?.pendingSubmission?.attachments == [attachment] && durable?.draft == draft,
                            "The last successful save cannot recover this accepted request")
                // Keep storage blocked through shutdown so its last save cannot
                // hide the failure. Restart from exactly the pre-dispatch journal.
                await store.shutdown()
                try fixture.removeSignal(signal)
                try fixture.restoreMetadataWrites()
                let restored = fixture.store(keys: keys)
                do {
                    guard let pending = restored.notes.first(where: { $0.id == note.id }) else {
                        throw CheckFailure(message: "Restart lost the journaled note")
                    }
                    try require(pending.pendingSubmission?.text == draft && pending.draft == draft && pending.attachments == [attachment],
                                "Restart did not load the durable pre-send request")
                    restored.connectAll()
                    try await wait("reconcile accepted history after storage failure") {
                        !restored.isConnecting && !restored.claudeIsConnecting
                    }
                    try require(restored.isConnected && restored.claudeIsConnected && pending.pendingSubmission == nil &&
                                pending.draft.isEmpty && pending.attachments.isEmpty && !pending.needsReconciliation,
                                "History reconciliation did not recognize the already accepted message")
                    try require(pending.messages.contains { $0.role == "user" && $0.text == draft && $0.fileAttachments == [attachment] },
                                "Restart restored the wrong user message or lost its attachment manifest")
                    try require(fixture.submissions(provider: provider).count == 1 && pending.fileLibrary == [attachment],
                                "Restart resent an accepted message or lost reusable attachments")
                    await restored.shutdown()
                } catch { await restored.shutdown(); throw error }
            }
        }
    }

    @MainActor private static func sendPersistenceDisabled() async throws {
        let fixture = try Fixture(emptyNotes: true), keys = EmptyKeyStore()
        let document = fixture.directory.appendingPathComponent("notes.json")
        let corrupt = Data("{ preserved malformed note metadata".utf8)
        try corrupt.write(to: document)
        let store = fixture.store(keys: keys)
        do {
            store.cliPath = fixture.codex.path
            store.claudeCLIPath = fixture.claude.path
            store.claudeEnabled = true
            try await connect(store)
            for provider in ChatProvider.allCases {
                let note = store.createNote(title: "Unsaved note", model: provider.rawValue + ":shared", effort: "medium")
                let draft = "Do not dispatch \(provider.rawValue) when saving metadata is disabled"
                let attachment = try attachPersistenceFixture(to: note, fixture: fixture, text: draft)
                let preparations = fixture.preparationCount(provider: provider)
                store.send(note)
                try await wait("disabled persistence rejects send") { !note.isBusy }
                try requireUnsent(note, draft: draft, attachment: attachment)
                try require(note.threadID == nil && fixture.preparationCount(provider: provider) == preparations &&
                            fixture.submissions(provider: provider).isEmpty,
                            "Disabled metadata persistence allowed conversation preparation or dispatch")
            }
            await store.shutdown()
            let original = try Data(contentsOf: document)
            try require(original == corrupt, "An unreadable metadata file was overwritten")
            try await wait("disabled persistence fixture cleanup") { fixture.runningChildren().isEmpty }
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            await store.shutdown()
            try? await wait("disabled persistence fixture cleanup") { fixture.runningChildren().isEmpty }
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
    }

    @MainActor private static func documentAttachments(fresh: Bool) async throws {
        try await exercise(emptyNotes: fresh) { store, keys, fixture in
            try await connect(store)
            let codex: NoteState, claude: NoteState
            if fresh {
                codex = store.createNote(title: "Codex files", model: "codex:shared", effort: "medium")
                claude = store.createNote(title: "Claude files", model: "claude:shared", effort: "medium")
                try require(codex.threadID == nil && claude.threadID == nil, "New notes created backend sessions before Send")
            } else { (codex, claude) = try notes(store) }
            let originalIDs = [codex.threadID, claude.threadID]
            // Fixed valid PNG bytes avoid consulting the display's color profile
            // while constructing a fixture in a headless test executable.
            guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC") else {
                throw CheckFailure(message: "Could not decode image fixture")
            }
            var originals: [URL] = []
            for note in [codex, claude] {
                let file = fixture.directory.appendingPathComponent(note.provider.rawValue + " analysis.txt")
                let image = fixture.directory.appendingPathComponent(note.provider.rawValue + " image.png")
                try "Original \(note.provider.rawValue) document".write(to: file, atomically: true, encoding: .utf8)
                try png.write(to: image)
                originals += [file, image]
                store.attachFiles([file, image], to: note)
            }
            try await wait("both providers import files") { !codex.isImportingFiles && !claude.isImportingFiles }
            let storage = AttachmentStore(directory: fixture.directory)
            for note in [codex, claude] {
                try require(note.error == nil && note.attachments.count == 2 && note.fileLibrary.count == 2,
                            "Import failed: \(note.error ?? "missing attachments")")
                try require(note.fileLibrary.allSatisfy { storage.owns($0, noteID: note.id) }, "Imported file escaped its note root")
            }
            guard let codexFile = codex.fileLibrary.first(where: { !$0.isImage }),
                  let claudeFile = claude.fileLibrary.first(where: { !$0.isImage }),
                  let codexImage = codex.fileLibrary.first(where: \.isImage),
                  let claudeImage = claude.fileLibrary.first(where: \.isImage) else {
                let kinds = [codex, claude].map { note in
                    note.provider.rawValue + ": " + note.fileLibrary.map { "\($0.name)=\($0.kind?.rawValue ?? "legacy-image")" }.joined(separator: ", ")
                }.joined(separator: "; ")
                throw CheckFailure(message: "Expected one imported document and one image per note; received \(kinds)")
            }
            try require(codexFile.path != claudeFile.path && codexImage.path != claudeImage.path, "Providers shared attachment paths")
            let beforeForeignReference = claude.attachments
            store.referenceFiles([codexFile.id], in: claude)
            try require(claude.attachments == beforeForeignReference && !store.files(for: claude).contains(where: { $0.id == codexFile.id }),
                        "A note could reference another note's library")
            for original in originals { try FileManager.default.removeItem(at: original) }
            let prompts = ["Read the Codex document", "Read the Claude document"]
            codex.draft = prompts[0]; claude.draft = prompts[1]
            store.send(codex); store.send(claude)
            try await wait("document sends start or fail") {
                (codex.activeTurnID != nil || !codex.isBusy) && (claude.activeTurnID != nil || !claude.isBusy)
            }
            try require(codex.isBusy && claude.isBusy && codex.error == nil && claude.error == nil,
                        "Document send failed: Codex \(codex.error ?? "idle"); Claude \(claude.error ?? "idle")")
            if !fresh {
                try require(codex.threadID == originalIDs[0] && claude.threadID == originalIDs[1], "Adding files replaced an existing conversation")
            }
            for note in [codex, claude] {
                let scratch = fixture.directory.appendingPathComponent("FileScratch").appendingPathComponent(note.id.uuidString)
                let values = try scratch.resourceValues(forKeys: [.isDirectoryKey])
                let permissions = try FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? NSNumber
                try require(values.isDirectory == true && permissions?.intValue == 0o700, "The reader scratch directory was not prepared privately")
            }
            guard let codexSend = fixture.requests(provider: "codex", method: "turn/start").last,
                  let claudeSend = fixture.requests(provider: "claude", method: "user").last else {
                throw CheckFailure(message: "The adapters never received the submitted attachments")
            }
            let codexWire = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: codexSend))["params"]
            let claudeWire = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: claudeSend))["message"]
            let firstEnvelope = AttachmentMessage.decode(codexWire["input"][0]["text"].string ?? "")
            let secondEnvelope = AttachmentMessage.decode(claudeWire["content"][0]["text"].string ?? "")
            try require(firstEnvelope.text == prompts[0] && firstEnvelope.files == [codexFile], "Codex lost the document manifest or mixed another note's files")
            try require(secondEnvelope.text == prompts[1] && secondEnvelope.files == [claudeFile], "Claude lost the document manifest or mixed another note's files")
            try require(codexWire["input"].array?.filter { $0["type"].string == "localImage" }.map { $0["path"].string } == [codexImage.path],
                        "Codex sent a document as an image or omitted the image")
            try require(claudeWire["content"].array?.filter { $0["type"].string == "image" }.count == 1,
                        "Claude sent documents as images or omitted the image")
            let configMethod = fresh ? "thread/start" : "thread/resume"
            guard let configRequest = fixture.requests(provider: "codex", method: configMethod).last else {
                throw CheckFailure(message: "Codex file configuration was not applied")
            }
            let config = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: configRequest))["params"]["config"]
            let readers = config.object?.values.filter { $0["enabled"].bool == true && $0["enabled_tools"] == ["read_attachment"] } ?? []
            try require(readers.count == 1 && readers[0]["args"][2].string == storage.noteDirectory(codex.id).path,
                        "Codex did not receive exactly this note's attachment root")
            let claudeInitializations = fixture.requests(provider: "claude", method: "initialize")
            try require(claudeInitializations.contains {
                ($0["params"] as? [String: Any])?["sdkMcpServers"] as? [String] == ["floating_ai_files"] && $0["session"] as? String == claude.threadID
            }, "Claude's file-capable session did not initialize the fixed SDK reader")
            try fixture.signal("release-codex"); try fixture.signal("release-claude")
            try await wait("file replies complete") { !codex.isBusy && !claude.isBusy }
            for (note, prompt) in zip([codex, claude], prompts) {
                try require(note.pendingSubmission == nil && note.draft.isEmpty && note.attachments.isEmpty,
                            "Acknowledged document submission was left pending")
                try require(note.hasFiles, "Acknowledged documents did not enable future file access")
                try require(note.fileLibrary.count == 2 && note.fileLibrary.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                            "Acknowledgment removed reusable files or depended on deleted originals")
                let message = note.messages.first { $0.role == "user" && $0.text == prompt }
                try require(message?.fileAttachments.count == 1 && message?.imagePaths.count == 1,
                            "The sent message did not display document and image cards")
            }
            let savedIDs = [codex.threadID, claude.threadID]
            let sendCounts = [fixture.requests(provider: "codex", method: "turn/start").count,
                              fixture.requests(provider: "claude", method: "user").count]
            store.persist()
            await store.shutdown()
            let restored = fixture.store(keys: keys)
            do {
                try require(restored.notes.allSatisfy(\.hasFiles), "Sent-document capability was not persisted before native history restore")
                try await connect(restored)
                let (restoredCodex, restoredClaude) = try notes(restored)
                try require([restoredCodex.threadID, restoredClaude.threadID] == savedIDs, "File restore replaced native session IDs")
                for (note, prompt) in zip([restoredCodex, restoredClaude], prompts) {
                    let message = note.messages.first { $0.role == "user" && $0.text == prompt }
                    try require(message?.fileAttachments.count == 1 && message?.imagePaths.count == 1,
                                "Native history did not restore readable message text and attachment cards")
                    try require(note.hasFiles && note.fileLibrary.count == 2 && note.draft.isEmpty && note.attachments.isEmpty,
                                "Restart lost the file library or revived an acknowledged draft")
                    try require(note.fileLibrary.allSatisfy { storage.owns($0, noteID: note.id) }, "Restored library crossed note boundaries")
                }
                try require(fixture.requests(provider: "codex", method: "turn/start").count == sendCounts[0] &&
                            fixture.requests(provider: "claude", method: "user").count == sendCounts[1], "Restoring files resent a message")
                restored.referenceFiles([codexFile.id], in: restoredCodex)
                try require(restoredCodex.attachments.map(\.id) == [codexFile.id] && restoredClaude.attachments.isEmpty,
                            "Reusing a restored file changed another note or lost its identity")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func unusedLibraryDocument() async throws {
        try await exercise { store, keys, fixture in
            try fixture.signal("codex-version", value: "0.151.0")
            try await connect(store)
            let (note, _) = try notes(store)
            let original = fixture.directory.appendingPathComponent("unused.txt")
            try "Keep this document for later".write(to: original, atomically: true, encoding: .utf8)
            store.attachFiles([original], to: note)
            try await wait("unused document import") { !note.isImportingFiles }
            guard let attachment = note.attachments.first else {
                throw CheckFailure(message: "Unused document import failed: \(note.error ?? "missing file")")
            }
            store.removeAttachment(attachment, from: note)
            try require(note.attachments.isEmpty && note.fileLibrary == [attachment] && !note.hasFiles,
                        "Removing an unsent attachment changed the library or enabled file access")
            try FileManager.default.removeItem(at: original)
            note.draft = "Plain text still works"
            store.send(note)
            try await wait("legacy plain-text send starts or fails") { note.activeTurnID != nil || !note.isBusy }
            try require(note.isBusy && note.error == nil, "Unused library file blocked the older CLI: \(note.error ?? "idle")")
            let requests = fixture.requests(provider: "codex", method: "turn/start")
            guard let sent = requests.last else { throw CheckFailure(message: "Plain text was never sent") }
            let wire = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: sent))["params"]
            try require(wire["input"] == [["type": "text", "text": "Plain text still works"]],
                        "An unused library document entered the plaintext request")
            try require(fixture.requests(provider: "codex", method: "mcpServerStatus/list").isEmpty,
                        "An unused library document activated the attachment reader")
            let scratch = fixture.directory.appendingPathComponent("FileScratch").appendingPathComponent(note.id.uuidString)
            try require(!FileManager.default.fileExists(atPath: scratch.path), "Plain text unnecessarily created file-analysis state")
            try fixture.signal("release-codex")
            try await wait("legacy plain-text completion") { !note.isBusy }
            try require(note.pendingSubmission == nil && note.draft.isEmpty && !note.hasFiles,
                        "Plain text was not acknowledged independently of the unused library")
            store.persist()
            await store.shutdown()
            let restored = fixture.store(keys: keys)
            do {
                let (same, _) = try notes(restored)
                try require(!same.hasFiles && same.fileLibrary == [attachment] && same.attachments.isEmpty,
                            "Restart treated an unused library document as a sent attachment")
                try await connect(restored)
                try require(!same.hasFiles && same.threadID == Fixture.session &&
                            same.messages.contains(where: { $0.text == "Plain text still works" }),
                            "Older CLI could not restore its plain-text history")
                try require(fixture.requests(provider: "codex", method: "mcpServerStatus/list").isEmpty &&
                            fixture.requests(provider: "codex", method: "turn/start").count == requests.count,
                            "Restore activated file tools or resent the plain-text message")
                try require(FileManager.default.fileExists(atPath: attachment.path), "Unused managed document disappeared on restart")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func copyConversation() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (original, _) = try notes(store)
            let attachment = try NotePersistence(directory: fixture.directory).attachmentDirectory(noteID: original.id)
                .appendingPathComponent(UUID().uuidString + ".png")
            try Data([0x89, 0x50, 0x4e, 0x47]).write(to: attachment)
            original.attachments = [StoredAttachment(path: attachment.path, name: "retained.png")]
            original.messages = [ChatMessage(id: "question", role: "user", text: "Image question", imagePaths: [attachment.path]),
                                 ChatMessage(id: "answer", role: "assistant", text: "Original reply")]
            original.draft = "My next question"
            let target = store.mergedModels.first { $0.provider == .claude }!
            // The destination may disconnect while the model-switch alert is open.
            store.claudeIsConnected = false
            let copy = store.copyConversation(original, to: target)
            try require(store.notes.count == 3 && copy.id != original.id, "Copy replaced the original note")
            try require(copy.provider == .claude && copy.model == "shared" && copy.threadID == nil, "Copy reused a foreign session")
            try require(copy.draft.contains("Image question") && copy.draft.contains("Original reply") && copy.draft.contains("My next question"), "Copy omitted reviewable conversation context")
            try require(copy.attachments.count == 1 && copy.attachments[0].path != attachment.path &&
                        AttachmentStore(directory: fixture.directory).owns(copy.attachments[0], noteID: copy.id), "Copied image was lost, duplicated, or shared between notes")
            let copiedBytes = try Data(contentsOf: URL(fileURLWithPath: copy.attachments[0].path))
            let originalBytes = try Data(contentsOf: attachment)
            try require(copiedBytes == originalBytes, "Independent image copy changed its contents")
            copy.draft = "Edited before sending"
            try require(original.provider == .codex && original.model == "shared" && original.draft == "My next question" && original.messages.count == 2 && original.threadID == Fixture.session,
                        "Editing a copy changed the original conversation")
            try require(FileManager.default.fileExists(atPath: attachment.path), "Copy removed the original image")
            try require(!copy.isBusy && copy.pendingSubmission == nil, "Copy sent without confirmation")
            try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty && fixture.requests(provider: "claude", method: "user").isEmpty,
                        "Copy automatically sent a message")
        }
    }

    @MainActor private static func freshConversation() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            let attachment = fixture.directory.appendingPathComponent("original.png")
            try Data([0x89, 0x50, 0x4e, 0x47]).write(to: attachment)
            for original in [codex, claude] {
                let provider = original.provider, model = original.model
                original.draft = "Keep this unsent draft"
                original.attachments = [StoredAttachment(path: attachment.path, name: "original.png")]
                original.hasImages = true
                original.messages = [ChatMessage(id: "history", role: "user", text: "Keep this history", imagePaths: [attachment.path])]
                let target = store.mergedModels.first { $0.provider != provider }!
                let fresh = store.copyConversation(original, to: target, includeHistory: false)
                try require(fresh.id != original.id && fresh.title == original.title && fresh.provider == target.provider && fresh.model == target.nativeID && fresh.effort == target.defaultReasoningEffort,
                            "Fresh note lost its destination model or reused the original")
                try require(fresh.threadID == nil && fresh.messages.isEmpty && fresh.draft.isEmpty && fresh.attachments.isEmpty && !fresh.hasImages && fresh.pendingSubmission == nil && !fresh.isBusy,
                            "Fresh note inherited conversation state or sent automatically")
                try require(original.provider == provider && original.model == model && original.threadID == Fixture.session && original.draft == "Keep this unsent draft" && original.messages.count == 1 && original.attachments.count == 1,
                            "Start Fresh changed the original note")
                let document = try NotePersistence(directory: fixture.directory).load()
                let saved = document.notes.first { $0.id == fresh.id }
                try require(saved?.provider == target.provider && saved?.model == target.nativeID && saved?.threadID == nil && saved?.draft == "" && saved?.attachments.isEmpty == true,
                            "Fresh note was not persisted as an empty independent conversation")
            }
            try require(store.notes.count == 4 && FileManager.default.fileExists(atPath: attachment.path), "Start Fresh replaced a note or removed its image")
            try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty && fixture.requests(provider: "claude", method: "user").isEmpty,
                        "Start Fresh automatically sent a message")
        }
    }

    @MainActor private static func deletionIsolation() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            try require(codex.threadID == claude.threadID, "Deletion fixture must exercise matching provider session IDs")
            try require(FileManager.default.fileExists(atPath: fixture.claudeHistory.path), "Claude history path is not canonical")
            await store.deleteNote(codex)
            try require(store.notes.map(\.id) == [claude.id] && !FileManager.default.fileExists(atPath: fixture.codexHistory.path),
                        "Codex deletion did not remove both its note and native history: \(codex.error ?? "no error")")
            try require(FileManager.default.fileExists(atPath: fixture.claudeHistory.path) && claude.threadID == Fixture.session && claude.error == nil,
                        "Codex deletion damaged the same-ID Claude conversation: exists=\(FileManager.default.fileExists(atPath: fixture.claudeHistory.path)), id=\(claude.threadID ?? "nil"), error=\(claude.error ?? "nil")")
            let freshCodex = CodexClient(requestTimeout: 3, environment: ["PATH": "/usr/bin:/bin"])
            _ = try await freshCodex.connect(executableURL: fixture.codex, workingDirectory: fixture.directory)
            do {
                _ = try await freshCodex.resumeThread(id: Fixture.session)
                await freshCodex.disconnect()
                throw CheckFailure(message: "Deleted Codex history remains resumable")
            } catch let error as CodexError {
                guard case .server = error else { await freshCodex.disconnect(); throw error }
            }
            await freshCodex.disconnect()
            await store.deleteNote(claude)
            try require(store.notes.isEmpty && !FileManager.default.fileExists(atPath: fixture.claudeHistory.path),
                        "Claude deletion did not remove its note and native history: \(claude.error ?? "no error")")
            let freshClaude = ClaudeClient(requestTimeout: 3, environment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": fixture.configuration.path])
            _ = try await freshClaude.connect(executableURL: fixture.claude, workingDirectory: fixture.directory.appendingPathComponent("ClaudeChat"))
            do {
                _ = try await freshClaude.resumeThread(id: Fixture.session)
                await freshClaude.disconnect()
                throw CheckFailure(message: "Deleted Claude history remains resumable")
            } catch let error as ClaudeError {
                guard case .missingSession = error else { await freshClaude.disconnect(); throw error }
            }
            await freshClaude.disconnect()
            let empty = store.createNote(title: "Offline empty note", model: "codex:shared", effort: "medium")
            store.isConnected = false
            await store.deleteNote(empty)
            try require(store.notes.isEmpty, "An unsent note cannot be deleted while its backend is offline")
            try require(fixture.requests(provider: "codex", method: "thread/delete").count == 1,
                        "Claude or an empty note caused another Codex deletion")
            await store.shutdown()
            let reads = fixture.requests(provider: "codex", method: "thread/read").count
            let restored = fixture.store(keys: keys)
            do {
                try require(restored.notes.isEmpty, "Restart resurrected a deleted note")
                try await connect(restored)
                try require(restored.notes.isEmpty && fixture.requests(provider: "codex", method: "thread/read").count == reads,
                            "Restart attempted to restore a deleted conversation")
                try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty && fixture.requests(provider: "claude", method: "user").isEmpty,
                            "Deleting or restarting automatically sent a message")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func deletionBusyGuards() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            claude.draft = "Keep this generation alive"
            store.send(claude)
            try await wait("Claude starts before deletion check") { claude.isBusy && claude.activeTurnID != nil }
            try require(!store.canDeleteNote(claude) && store.canDeleteNote(codex), "Deletion guards are not scoped to the target note")
            await store.deleteNote(claude)
            try require(!claude.deletionPending && store.notes.contains(where: { $0.id == claude.id }) && claude.isBusy,
                        "Deleting an active note changed its conversation")
            await store.deleteNote(codex)
            try require(store.notes.map(\.id) == [claude.id] && claude.isBusy && store.claudeIsConnected,
                        "Deleting an idle Codex note interrupted Claude")
            try fixture.signal("release-claude")
            try await wait("Claude finishes after unrelated deletion") { !claude.isBusy && store.canDeleteNote(claude) }
            await store.deleteNote(claude)
            try require(store.notes.isEmpty && !FileManager.default.fileExists(atPath: fixture.claudeHistory.path),
                        "Finished Claude note could not be deleted")
        }
    }

    @MainActor private static func deletionFailureRecovery() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, _) = try notes(store)
            try fixture.signal("fail-delete-codex")
            await store.deleteNote(codex)
            let saved = try NotePersistence(directory: fixture.directory).load().notes.first { $0.id == codex.id }
            try require(codex.deletionPending && !codex.isDeleting && codex.error?.contains("kept for retry") == true && saved?.deletionPending == true,
                        "Backend failure did not retain a durable retry entry")
            try require(FileManager.default.fileExists(atPath: fixture.codexHistory.path) && codex.draft == "Saved Codex draft",
                        "Failed backend deletion changed the history or draft")
            store.send(codex)
            store.selectModel("claude:shared", for: codex)
            try require(codex.provider == .codex && fixture.requests(provider: "codex", method: "turn/start").isEmpty,
                        "A pending deletion can still change models or send")
            await store.shutdown()
            try fixture.removeSignal("fail-delete-codex")
            let readCount = fixture.requests(provider: "codex", method: "thread/read").count
            let resumeCount = fixture.requests(provider: "codex", method: "thread/resume").count
            let deleteCount = fixture.requests(provider: "codex", method: "thread/delete").count
            let restored = fixture.store(keys: keys)
            do {
                let (pending, _) = try notes(restored)
                try require(pending.deletionPending && pending.threadID == Fixture.session && pending.draft == "Saved Codex draft",
                            "Restart lost the deletion marker or original metadata")
                restored.connectAll()
                try await wait("connections with pending deletion") { !restored.isConnecting && !restored.claudeIsConnecting }
                try require(restored.isConnected && restored.claudeIsConnected, "Pending deletion prevented a backend connection")
                try require(fixture.requests(provider: "codex", method: "thread/read").count == readCount &&
                            fixture.requests(provider: "codex", method: "thread/resume").count == resumeCount &&
                            fixture.requests(provider: "codex", method: "thread/delete").count == deleteCount &&
                            fixture.requests(provider: "codex", method: "turn/start").isEmpty,
                            "Restart resumed, resent, or automatically deleted a pending conversation")
                await restored.deleteNote(pending)
                try require(restored.notes.allSatisfy { $0.provider == .claude } && !FileManager.default.fileExists(atPath: fixture.codexHistory.path),
                            "Retry did not finish the pending deletion")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func deletionPersistenceFailures() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, _) = try notes(store)
            let manager = FileManager.default
            let document = fixture.directory.appendingPathComponent("notes.json")
            let before = fixture.directory.appendingPathComponent("notes-before.json")
            try manager.moveItem(at: document, to: before)
            try manager.createDirectory(at: document, withIntermediateDirectories: false)
            await store.deleteNote(codex)
            try require(!codex.deletionPending && codex.error?.contains("Could not save the deletion request") == true,
                        "Failure before the durable marker did not leave the note usable")
            try require(fixture.requests(provider: "codex", method: "thread/delete").isEmpty && manager.fileExists(atPath: fixture.codexHistory.path),
                        "Backend deletion happened before saving a durable request")
            try manager.removeItem(at: document)
            try manager.moveItem(at: before, to: document)
            try fixture.signal("fail-delete-commit")
            await store.deleteNote(codex)
            try require(codex.deletionPending && codex.error?.contains("kept for retry") == true && store.notes.contains(where: { $0.id == codex.id }),
                        "Failure after backend removal lost the retry entry")
            try require(!manager.fileExists(atPath: fixture.codexHistory.path), "Fixture did not delete backend history before failing commit")
            let durable = fixture.directory.appendingPathComponent("deletion-snapshot-backup.json")
            let snapshot = try JSONDecoder().decode(AppDocument.self, from: Data(contentsOf: durable))
            try require(snapshot.notes.first(where: { $0.id == codex.id })?.deletionPending == true,
                        "The last successful write did not contain the deletion marker")
            try manager.removeItem(at: document)
            try manager.moveItem(at: durable, to: document)
            try fixture.removeSignal("fail-delete-commit")
            await store.shutdown()
            let readCount = fixture.requests(provider: "codex", method: "thread/read").count
            let restored = fixture.store(keys: keys)
            do {
                let (pending, _) = try notes(restored)
                restored.connectAll()
                try await wait("connections after partially completed deletion") { !restored.isConnecting && !restored.claudeIsConnecting }
                try require(pending.deletionPending && fixture.requests(provider: "codex", method: "thread/read").count == readCount,
                            "Partially deleted history was restored on restart")
                await restored.deleteNote(pending)
                try require(!restored.notes.contains(where: { $0.id == pending.id }),
                            "Retrying a backend history already removed before a failed commit did not finish")
                let finalDocument = try NotePersistence(directory: fixture.directory).load()
                try require(finalDocument.notes.allSatisfy { $0.id != pending.id },
                            "Successful retry did not commit the removal")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func deletionSharedImages() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            let manager = FileManager.default, persistence = NotePersistence(directory: fixture.directory)
            let attachmentDirectory = try persistence.attachmentDirectory(noteID: codex.id)
            let shared = attachmentDirectory.appendingPathComponent(UUID().uuidString + ".png")
            let exclusive = attachmentDirectory.appendingPathComponent(UUID().uuidString + ".png")
            let outside = fixture.directory.appendingPathComponent("original-outside-attachments.png")
            let auth = fixture.configuration.appendingPathComponent(".credentials.json")
            for path in [shared, exclusive, outside, auth] { try Data("fixture sentinel".utf8).write(to: path) }
            codex.attachments = [shared, exclusive, outside].map { StoredAttachment(path: $0.path, name: $0.lastPathComponent) }
            codex.retainedImagePaths = Set([shared.path, exclusive.path, outside.path])
            codex.hasImages = true
            claude.retainedImagePaths = [shared.path]
            claude.imageReferencesKnown = true
            claude.hasImages = true
            claude.messages.append(ChatMessage(id: "shared-image", role: "user", text: "Shared image", imagePaths: [shared.path]))
            store.persist()
            await store.deleteNote(codex)
            try require(!manager.fileExists(atPath: exclusive.path) && manager.fileExists(atPath: shared.path),
                        "Deletion did not distinguish unused and shared application images")
            let remaining = try persistence.load().notes.first { $0.id == claude.id }
            try require(remaining?.referencedImagePaths?.contains(shared.path) == true,
                        "Remaining note did not retain its shared-image reference")
            try require(manager.fileExists(atPath: outside.path) && manager.fileExists(atPath: auth.path),
                        "Deletion removed an original image or authentication file")
            await store.shutdown()
            let restored = fixture.store(keys: keys)
            do {
                try await connect(restored)
                guard let last = restored.notes.first else { throw CheckFailure(message: "Shared-image note disappeared on restart") }
                try require(last.retainedImagePaths.contains(shared.path), "Restart forgot the surviving history's image reference")
                await restored.deleteNote(last)
                try require(restored.notes.isEmpty && !manager.fileExists(atPath: shared.path),
                            "The final referencing note did not remove the shared application image")
                let originalData = try Data(contentsOf: outside), authenticationData = try Data(contentsOf: auth)
                try require(originalData == Data("fixture sentinel".utf8) && authenticationData == Data("fixture sentinel".utf8),
                            "Original images or shared authentication were changed")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func batchDeletionHiddenNotes() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            codex.isVisible = false; claude.isVisible = false
            store.persist()
            try require(store.requestedNoteID == nil, "Fixture unexpectedly requested a window")
            await store.deleteNotes([codex, claude, codex, claude])
            try require(store.notes.isEmpty && !store.isDeletingNotes && !codex.isDeleting && !claude.isDeleting,
                        "Mixed-provider batch did not complete both deletions")
            try require(!FileManager.default.fileExists(atPath: fixture.codexHistory.path) &&
                        !FileManager.default.fileExists(atPath: fixture.claudeHistory.path),
                        "Batch removed note metadata but retained native conversation history")
            try require(!codex.isVisible && !claude.isVisible && store.requestedNoteID == nil,
                        "Batch deletion showed a previously hidden note")
            try require(fixture.requests(provider: "codex", method: "thread/delete").count == 1,
                        "Duplicate selection entries deleted a backend conversation more than once")
            let saved = try NotePersistence(directory: fixture.directory).load()
            try require(saved.notes.isEmpty, "Batch deletion was not committed to persistence")
            await store.shutdown()
            let reads = fixture.requests(provider: "codex", method: "thread/read").count
            let restored = fixture.store(keys: keys)
            do {
                try require(restored.notes.isEmpty && restored.requestedNoteID == nil, "Restart resurrected or showed a batch-deleted note")
                try await connect(restored)
                try require(restored.notes.isEmpty && fixture.requests(provider: "codex", method: "thread/read").count == reads,
                            "Restart restored batch-deleted history")
                try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty &&
                            fixture.requests(provider: "claude", method: "user").isEmpty,
                            "Batch deletion or restart sent a model request")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func batchDeletionPartialFailure() async throws {
        try await exercise { store, keys, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            codex.isVisible = false; claude.isVisible = false
            store.persist()
            let originalHistory = try Data(contentsOf: fixture.codexHistory)
            try fixture.signal("fail-delete-codex")
            await store.deleteNotes([codex, claude])
            let saved = try NotePersistence(directory: fixture.directory).load()
            let remaining = saved.notes.first
            let failedHistory = try Data(contentsOf: fixture.codexHistory)
            try require(store.notes.map(\.id) == [codex.id] && saved.notes.map(\.id) == [codex.id],
                        "One batch failure prevented deletion of the other provider")
            try require(codex.deletionPending && !codex.isDeleting && !store.isDeletingNotes &&
                        remaining?.deletionPending == true && remaining?.threadID == Fixture.session,
                        "Partial batch failure lost its durable retry journal or left the batch locked")
            try require(failedHistory == originalHistory && codex.draft == "Saved Codex draft" &&
                        remaining?.draft == "Saved Codex draft" && !FileManager.default.fileExists(atPath: fixture.claudeHistory.path),
                        "Partial failure lost the failed draft/history or retained the successful history")
            try require(!codex.isVisible && remaining?.isVisible == false && !claude.isVisible && store.requestedNoteID == nil,
                        "Partial batch failure opened a hidden note")
            try require(codex.error != nil && store.noteDeletionSummary != nil,
                        "Partial batch failure did not report its failed note")
            await store.shutdown()
            let reads = fixture.requests(provider: "codex", method: "thread/read").count
            let resumes = fixture.requests(provider: "codex", method: "thread/resume").count
            let deletes = fixture.requests(provider: "codex", method: "thread/delete").count
            try fixture.removeSignal("fail-delete-codex")
            let restored = fixture.store(keys: keys)
            do {
                guard let pending = restored.notes.first else { throw CheckFailure(message: "Failed batch note disappeared on restart") }
                try require(restored.notes.count == 1 && pending.id == codex.id && !pending.isVisible &&
                            pending.deletionPending && pending.draft == "Saved Codex draft" && restored.requestedNoteID == nil,
                            "Restart lost the hidden failed note or resurrected the successful deletion")
                restored.connectAll()
                try await wait("batch retry connections") { !restored.isConnecting && !restored.claudeIsConnecting }
                try require(restored.isConnected && restored.claudeIsConnected &&
                            fixture.requests(provider: "codex", method: "thread/read").count == reads &&
                            fixture.requests(provider: "codex", method: "thread/resume").count == resumes &&
                            fixture.requests(provider: "codex", method: "thread/delete").count == deletes,
                            "Restart restored or automatically retried a pending batch deletion")
                await restored.deleteNotes([pending])
                let final = try NotePersistence(directory: fixture.directory).load()
                try require(restored.notes.isEmpty && final.notes.isEmpty && !FileManager.default.fileExists(atPath: fixture.codexHistory.path),
                            "Retrying only the failed selection did not complete its deletion")
                try require(fixture.requests(provider: "codex", method: "thread/delete").count == deletes + 1 &&
                            restored.requestedNoteID == nil && !pending.isVisible,
                            "Batch retry sent extra deletions or showed the failed note")
                try require(fixture.requests(provider: "codex", method: "turn/start").isEmpty &&
                            fixture.requests(provider: "claude", method: "user").isEmpty,
                            "Partial batch recovery resent a message")
                await restored.shutdown()
            } catch { await restored.shutdown(); throw error }
        }
    }

    @MainActor private static func batchDeletionGuards() async throws {
        try await exercise { store, _, fixture in
            try await connect(store)
            let (codex, claude) = try notes(store)
            codex.isVisible = false; claude.isVisible = false
            claude.draft = "Keep this generation alive"
            store.send(claude)
            try await wait("busy batch selection") { claude.isBusy && claude.activeTurnID != nil }
            try require(store.deletionUnavailableReason(for: [claude]) != nil && store.deletionUnavailableReason(for: [codex]) == nil,
                        "Batch eligibility did not distinguish a busy note from an idle one")
            await store.deleteNotes([codex, claude])
            try require(store.notes.count == 2 && !codex.deletionPending && !claude.deletionPending &&
                        !codex.isDeleting && !claude.isDeleting && !store.isDeletingNotes,
                        "A busy selection partially deleted or reserved the otherwise idle note")
            try require(fixture.requests(provider: "codex", method: "thread/delete").isEmpty &&
                        FileManager.default.fileExists(atPath: fixture.codexHistory.path) &&
                        FileManager.default.fileExists(atPath: fixture.claudeHistory.path),
                        "A rejected busy batch changed native history")
            try fixture.signal("release-claude")
            try await wait("busy selection becomes idle") { !claude.isBusy && store.canChangeClaudeConnection && store.canDeleteNote(claude) }
            claude.draft = "Keep this queued draft"
            try fixture.signal("hold-delete-codex")
            let operation = Task { @MainActor in await store.deleteNotes([codex, claude, codex]) }
            do {
                try await wait("first batch deletion awaits backend") {
                    !fixture.requests(provider: "codex", method: "thread/delete").isEmpty
                }
                try require(store.isDeletingNotes && codex.isDeleting && claude.isDeleting,
                            "The batch did not reserve all selected notes before awaiting its first backend")
                try require(store.deletionUnavailableReason(for: [claude]) != nil && !store.canChangeAuthentication &&
                            !store.canChangeClaudeConnection, "Queued deletion allowed backend authentication changes")
                let claudeRequests = fixture.requests(provider: "claude", method: "user").count
                store.send(claude)
                store.selectEffort("high", for: claude)
                store.selectAuthenticationMode(.openAIAPIKey)
                store.disconnectClaude()
                try require(claude.effort == "medium" && claude.draft == "Keep this queued draft" &&
                            !claude.isBusy && store.authenticationMode == .codexSignIn && store.claudeEnabled &&
                            store.claudeIsConnected && fixture.requests(provider: "claude", method: "user").count == claudeRequests,
                            "A queued note sent, changed model settings, or changed authentication while reserved")
                await store.deleteNotes([claude])
                try require(store.isDeletingNotes && codex.isDeleting && claude.isDeleting,
                            "A competing batch disrupted the existing reservations")
                try fixture.signal("release-delete-codex")
                await operation.value
            } catch {
                try? fixture.signal("release-delete-codex")
                await operation.value
                throw error
            }
            try require(store.notes.isEmpty && !store.isDeletingNotes &&
                        fixture.requests(provider: "codex", method: "thread/delete").count == 1,
                        "Reserved batch did not finish once or deduplicate selected notes")
            try require(!codex.isVisible && !claude.isVisible && store.requestedNoteID == nil,
                        "Batch guard handling showed a hidden note")
        }
    }
}
