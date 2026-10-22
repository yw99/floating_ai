import Foundation
import FloatingAICore

/// Synthetic subprocess checks. No account credentials or paid model requests are used.
public enum ClaudeProtocolChecks {
    public static func run() async throws {
        do { try await testCatalogSafetyStreamingAndNativeResume() }
        catch { throw Failure(description: "Claude catalog/stream/resume: \(error)") }
        do { try await testParallelSessionsInterruptionAndCrashIsolation() }
        catch { throw Failure(description: "Claude parallel/stop/crash: \(error)") }
        do { try await testFailuresApprovalsAndMissingSessions() }
        catch { throw Failure(description: "Claude failures/approvals: \(error)") }
        do { try await testCompactedHistoryKeepsOnlyValidArchiveBranches() }
        catch { throw Failure(description: "Claude compaction history: \(error)") }
        do { try await testSessionDeletionIsConfinedAndReapsWriter() }
        catch { throw Failure(description: "Claude session deletion: \(error)") }
        do { try await testDeletionFailureKeepsNativeHistory() }
        catch { throw Failure(description: "Claude deletion failure: \(error)") }
        do { try await testScopedAttachmentReaderAndResume() }
        catch { throw Failure(description: "Claude attachment scope/resume: \(error)") }
        do { try await testAttachmentReaderLimitsAndCancellation() }
        catch { throw Failure(description: "Claude attachment limits/cancellation: \(error)") }
    }
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private actor EventLog {
        var values: [CodexEvent] = []
        func append(_ event: CodexEvent) { values.append(event) }
        func notifications(_ method: String, thread: String? = nil) -> [JSONValue] {
            values.compactMap { event in
                guard case .notification(let name, let params) = event, name == method,
                      thread == nil || params["threadId"].string == thread else { return nil }
                return params
            }
        }
    }
    private static func fixture(scenario: String = "normal") throws -> (URL, URL, [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-claude-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-claude")
        try server.replacingOccurrences(of: "FIXTURE_SCENARIO", with: scenario).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = directory.appendingPathComponent("config").path
        environment["CLAUDE_CODE_TMPDIR"] = directory.appendingPathComponent("temp").path
        return (directory, executable, environment)
    }
    private static func awaitEvent(_ method: String, thread: String, log: EventLog, count: Int = 1) async throws -> [JSONValue] {
        for _ in 0..<200 {
            let values = await log.notifications(method, thread: thread)
            if values.count >= count { return values }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(description: "Timed out waiting for \(method) on \(thread)")
    }

    public static func testCatalogSafetyStreamingAndNativeResume() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment)
        let log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        let info = try await client.connect(executableURL: executable, workingDirectory: directory)
        try require(info.version == "2.1.307" && info.isLoggedIn, "Expected authenticated Claude fixture")
        try require(info.models.map(\.id) == ["sonnet", "opus", "haiku"], "Default alias must not create a duplicate model menu item")
        try require(info.models[0].isDefault, "Resolved default model should remain the default")
        try require(info.models[0].defaultReasoningEffort == "high", "Honor CLI effective effort")
        try require(info.models[0].supportedReasoningEfforts.map(\.id) == ["low", "medium", "high", "xhigh"], "Keep CLI effort capabilities")
        try require(info.models[2].supportedReasoningEfforts.map(\.id) == ["default"], "Non-effort models have a default choice")
        let thread = try await client.createThread(model: "sonnet")
        let empty: JSONValue
        do { empty = try await client.readThread(id: thread) }
        catch { throw Failure(description: "Empty session read: \(error)") }
        try require(Transcript.messages(from: empty).isEmpty, "A new empty native session must remain resumable")
        let image = directory.appendingPathComponent("image.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jwioAAAAASUVORK5CYII=")!.write(to: image)
        _ = try await client.send(threadID: thread, text: "你好 @/etc/passwd", imagePaths: [image.path], model: "sonnet", effort: "xhigh")
        let completed = try await awaitEvent("turn/completed", thread: thread, log: log)
        try require(completed.count == 1, "Duplicate result frames must not complete the turn twice")
        let received = Transcript.messages(from: ["turns": [completed[0]["turn"]]])
        try require(received.map(\.text) == ["你好 @/etc/passwd", "你好 🌎"], "Split JSONL/Unicode streaming must assemble exactly once")
        let deltas = await log.notifications("item/agentMessage/delta", thread: thread)
        try require(deltas.map { $0["delta"].string ?? "" }.joined() == "你好 🌎", "Duplicate UUID stream events must be ignored")
        let history: JSONValue
        do { history = try await client.readThread(id: thread) }
        catch {
            let config = directory.appendingPathComponent("config")
            let paths = FileManager.default.enumerator(at: config, includingPropertiesForKeys: nil)?.allObjects.compactMap { ($0 as? URL)?.path } ?? []
            throw Failure(description: "Completed history read: \(error); workspace=\(directory.resolvingSymlinksInPath().path); fixture paths=\(paths)")
        }
        try require(Transcript.messages(from: history).map(\.text) == received.map(\.text), "Native history must reproduce displayed messages")
        try require(Transcript.messages(from: history).first?.imagePaths == [image.path], "Attachment references survive native history reads")
        await client.disconnect()
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let resumed: JSONValue
        do { resumed = try await client.resumeThread(id: thread) }
        catch { throw Failure(description: "Reconnect resume: \(error)") }
        try require(Transcript.messages(from: resumed).map(\.text) == received.map(\.text), "Reconnect must recover the original native session")
        _ = try await client.send(threadID: thread, text: "after resume", imagePaths: [], model: "opus", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: 2)
        let audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        try require(audit.contains("\"resume\": true"), "Existing sessions must use --resume")
        try require(audit.components(separatedBy: "\"kind\": \"user\"").count - 1 == 2, "Connection and restoration must never send generation requests")
        await client.disconnect()
    }

    public static func testParallelSessionsInterruptionAndCrashIsolation() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment)
        let log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let first = try await client.createThread(model: "sonnet"), second = try await client.createThread(model: "sonnet")
        let active = try await client.send(threadID: first, text: "hold", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await client.send(threadID: second, text: "second", imagePaths: [], model: "sonnet", effort: "high")
        _ = try await awaitEvent("turn/completed", thread: second, log: log)
        let firstCompletions = await log.notifications("turn/completed", thread: first)
        try require(firstCompletions.isEmpty, "A different note's completion must not end an active turn")
        do {
            _ = try await client.send(threadID: first, text: "duplicate", imagePaths: [], model: "sonnet", effort: "medium")
            throw Failure(description: "Concurrent turns in one session must fail")
        } catch ClaudeError.busy { }
        try await client.interrupt(threadID: first, turnID: active)
        let stopped = try await awaitEvent("turn/completed", thread: first, log: log)
        try require(stopped[0]["turn"]["status"].string == "interrupted", "Stop should preserve native session and finish its turn")
        _ = try await client.send(threadID: first, text: "crash", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("floatingAI/sessionDisconnected", thread: first, log: log)
        _ = try await client.send(threadID: second, text: "still connected", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: second, log: log, count: 2)
        let restored = try await client.resumeThread(id: first)
        try require(Transcript.messages(from: restored).contains(where: { $0.text == "crash" }), "Uncertain accepted messages are recovered without re-sending")
        let secondHistory = try await client.readThread(id: second)
        try require(!Transcript.messages(from: secondHistory).contains(where: { $0.text == "hold" || $0.text == "crash" }), "Conversation histories must not leak across notes")
        await client.disconnect()
    }

    public static func testFailuresApprovalsAndMissingSessions() async throws {
        for scenario in ["bad-version", "unsafe-hooks", "unsafe-mcp"] {
            let (directory, executable, environment) = try fixture(scenario: scenario)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = ClaudeClient(requestTimeout: 1, environment: environment)
            do {
                _ = try await client.connect(executableURL: executable, workingDirectory: directory)
                throw Failure(description: "Unsafe/incompatible Claude configuration must fail closed: \(scenario)")
            } catch is ClaudeError { }
            await client.disconnect()
        }
        let (directory, executable, environment) = try fixture(scenario: "normal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment), log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        do {
            _ = try await client.resumeThread(id: UUID().uuidString.lowercased())
            throw Failure(description: "Missing history must not create a replacement session")
        } catch ClaudeError.missingSession { }
        do {
            _ = try await client.readThread(id: "../../somewhere")
            throw Failure(description: "Untrusted session IDs must not become paths")
        } catch ClaudeError.invalidSession { }
        let thread = try await client.createThread(model: "sonnet")
        _ = try await client.send(threadID: thread, text: "approval", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: thread, log: log)
        _ = try await awaitEvent("floatingAI/toolBlocked", thread: thread, log: log)
        let audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        try require(audit.contains("\"behavior\": \"deny\""), "Unexpected client tool approvals must be denied")
        _ = try await client.send(threadID: thread, text: "api-error", imagePaths: [], model: "sonnet", effort: "medium")
        let failed = try await awaitEvent("turn/completed", thread: thread, log: log, count: 2)
        let message = failed.last?["turn"]["error"]["message"].string ?? ""
        try require(!message.isEmpty && message.contains("authentication failed") && !message.contains("sk-ant-secret"), "Empty errors arrays must fall back to a nonempty redacted API failure")
        let unaccepted = try await client.createThread(model: "sonnet")
        do {
            _ = try await client.send(threadID: unaccepted, text: "crash-before-ack", imagePaths: [], model: "sonnet", effort: "medium")
            throw Failure(description: "Stdin delivery must not be reported as accepted after an early crash")
        } catch is ClaudeError { }
        _ = try await awaitEvent("floatingAI/sessionDisconnected", thread: unaccepted, log: log)
        let uncertainItems = await log.notifications("item/completed", thread: unaccepted)
        try require(uncertainItems.isEmpty, "An unaccepted user message must remain pending, without synthetic receipts")
        _ = try await client.send(threadID: thread, text: "malformed", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("floatingAI/sessionDisconnected", thread: thread, log: log)
        await client.disconnect()
        let (timeoutDirectory, timeoutExecutable, timeoutEnvironment) = try fixture(scenario: "stall-models")
        defer { try? FileManager.default.removeItem(at: timeoutDirectory) }
        let timeoutClient = ClaudeClient(requestTimeout: 1, environment: timeoutEnvironment)
        _ = try await timeoutClient.connect(executableURL: timeoutExecutable, workingDirectory: timeoutDirectory)
        do {
            _ = try await timeoutClient.refreshModels()
            throw Failure(description: "Missing control response must time out")
        } catch ClaudeError.timeout { }
        // Reconnection uses a new channel generation, so late replies cannot settle new requests.
        _ = try await timeoutClient.connect(executableURL: timeoutExecutable, workingDirectory: timeoutDirectory)
        await timeoutClient.disconnect()
    }

    public static func testCompactedHistoryKeepsOnlyValidArchiveBranches() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let session = UUID().uuidString.lowercased()
        func record(_ uuid: String, parent: String?, text: String, role: String = "user", summary: Bool = false) -> JSONValue {
            ["uuid": .string(uuid), "sessionId": .string(session), "type": .string(role), "parentUuid": parent.map(JSONValue.string) ?? .null,
             "isCompactSummary": .bool(summary), "message": ["id": .string("message-" + uuid), "content": [["type": "text", "text": .string(text)]]]]
        }
        func boundary(_ uuid: String, logical: String) -> JSONValue {
            ["uuid": .string(uuid), "sessionId": .string(session), "type": "system", "subtype": "compact_boundary",
             "parentUuid": nil, "logicalParentUuid": .string(logical)]
        }
        guard let real = realpath(directory.path, nil) else { throw Failure(description: "Missing fixture workspace") }
        let encoded = String(cString: real).replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        free(real)
        let folder = directory.appendingPathComponent("config/projects").appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(session + ".jsonl")
        func write(_ records: [JSONValue]) throws {
            var data = Data()
            for record in records { data.append(try JSONEncoder().encode(record)); data.append(0x0a) }
            try data.write(to: file, options: .atomic)
        }
        try write([
            record("a", parent: nil, text: "Original question"),
            record("b", parent: "a", text: "Original reply", role: "assistant"),
            record("abandoned", parent: "a", text: "Abandoned sibling", role: "assistant"),
            boundary("c", logical: "b"), record("d", parent: "c", text: "First summary", summary: true),
            record("e", parent: "d", text: "Second question"), record("f", parent: "e", text: "Second reply", role: "assistant"),
            boundary("g", logical: "f"), record("h", parent: "g", text: "Second summary", summary: true),
            record("i", parent: "h", text: "Recent question"), record("j", parent: "i", text: "Recent reply", role: "assistant")
        ])
        let full = try await client.readThread(id: session)
        try require(Transcript.messages(from: full).map(\.text) == ["Original question", "Original reply", "Second question", "Second reply", "Recent question", "Recent reply"],
                    "Repeated compaction must restore linked originals without summaries or abandoned siblings")
        try write([boundary("c", logical: "unavailable"), record("d", parent: "c", text: "Retained summary", summary: true), record("e", parent: "d", text: "Latest question")])
        let missing = try await client.readThread(id: session)
        try require(Transcript.messages(from: missing).map(\.text) == ["Retained summary", "Latest question"], "Missing archive links must keep the compact summary")
        try write([boundary("c", logical: "c"), record("d", parent: "c", text: "Cycle-safe summary", summary: true), record("e", parent: "d", text: "Latest question")])
        let cycle = try await client.readThread(id: session)
        try require(Transcript.messages(from: cycle).map(\.text) == ["Cycle-safe summary", "Latest question"], "Self-referential archive links must not loop or erase the summary")
        try write([boundary("c", logical: "future"), record("d", parent: "c", text: "Forward-link summary", summary: true), record("future", parent: "d", text: "Current reply", role: "assistant")])
        let forward = try await client.readThread(id: session)
        try require(Transcript.messages(from: forward).map(\.text) == ["Forward-link summary", "Current reply"], "Archive links may only target earlier records")
        await client.disconnect()
    }

    private static func nativeFolder(_ directory: URL) throws -> URL {
        guard let real = realpath(directory.path, nil) else { throw Failure(description: "Missing fixture workspace") }
        defer { free(real) }
        let encoded = String(cString: real).replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        return directory.appendingPathComponent("config/projects").appendingPathComponent(encoded)
    }

    public static func testSessionDeletionIsConfinedAndReapsWriter() async throws {
        let (directory, executable, environment) = try fixture(scenario: "late-writer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment), log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let deleted = try await client.createThread(model: "sonnet"), kept = try await client.createThread(model: "sonnet")
        _ = try await client.send(threadID: deleted, text: "remove this", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: deleted, log: log)
        let active = try await client.send(threadID: kept, text: "hold", imagePaths: [], model: "sonnet", effort: "medium")
        do {
            try await client.deleteThread(id: kept)
            throw Failure(description: "A generating session must reject deletion")
        } catch ClaudeError.busy { }
        let folder = try nativeFolder(directory), config = directory.appendingPathComponent("config")
        let transcript = folder.appendingPathComponent(deleted + ".jsonl")
        let marker = directory.appendingPathComponent(".floating-ai-claude-sessions/" + deleted + ".json")
        let history = try Data(contentsOf: folder.appendingPathComponent(kept + ".jsonl"))
        var artifacts: [URL] = []
        for relative in ["projects/\(folder.lastPathComponent)/\(deleted)/subagents", "tasks/\(deleted)", "file-history/\(deleted)", "session-env/\(deleted)", "image-cache/\(deleted)", "uploads/\(deleted)", "dev-mods/\(deleted)"] {
            let subdirectory = config.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let file = subdirectory.appendingPathComponent("owned.json")
            try Data("owned".utf8).write(to: file); artifacts.append(file)
        }
        let debug = config.appendingPathComponent("debug/" + deleted + ".txt")
        try FileManager.default.createDirectory(at: debug.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [debug, folder.appendingPathComponent(deleted + ".jsonl.superseded-123"), folder.appendingPathComponent(deleted + ".orphaned-123-abc.jsonl")] {
            try Data("session data".utf8).write(to: file); artifacts.append(file)
        }
        let nativeImage = directory.appendingPathComponent("temp/claude-\(getuid())/\(folder.lastPathComponent)/\(deleted)/images/1.png")
        try FileManager.default.createDirectory(at: nativeImage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("native image".utf8).write(to: nativeImage); artifacts.append(nativeImage)
        let credentialSentinel = config.appendingPathComponent(".credentials.json")
        try Data("untouched fixture credentials".utf8).write(to: credentialSentinel)
        try await client.deleteThread(id: deleted.uppercased())
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent(deleted + ".exited").path), "Deletion must await the native writer's exit")
        try require(!FileManager.default.fileExists(atPath: transcript.path) && !FileManager.default.fileExists(atPath: marker.path), "Native transcript and empty-session marker must both be removed")
        try require(artifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "All verified per-session artifacts must be removed")
        try require(try Data(contentsOf: folder.appendingPathComponent(kept + ".jsonl")) == history, "A neighboring active session's transcript must remain byte-identical")
        try require(try String(contentsOf: credentialSentinel) == "untouched fixture credentials", "Shared authentication must remain untouched")
        do { _ = try await client.resumeThread(id: deleted); throw Failure(description: "Deleted native sessions must not resume") }
        catch ClaudeError.missingSession { }
        try await client.deleteThread(id: deleted)
        try await client.deleteThread(id: UUID().uuidString.lowercased())
        for invalid in ["../neighbor", "", deleted + "/..", "catalog"] {
            do { try await client.deleteThread(id: invalid); throw Failure(description: "Invalid deletion ID must be rejected") }
            catch ClaudeError.invalidSession { }
        }
        try await client.interrupt(threadID: kept, turnID: active)
        _ = try await awaitEvent("turn/completed", thread: kept, log: log)
        _ = try await client.send(threadID: kept, text: "still connected", imagePaths: [], model: "opus", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: kept, log: log, count: 2)
        await client.disconnect()
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        do { _ = try await client.resumeThread(id: deleted); throw Failure(description: "Reconnect must not recreate deleted native history") }
        catch ClaudeError.missingSession { }
        let restored = try await client.resumeThread(id: kept)
        try require(Transcript.messages(from: restored).contains { $0.text == "still connected" }, "Other sessions must still resume")
        await client.disconnect()
    }

    public static func testDeletionFailureKeepsNativeHistory() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 2, environment: environment), log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let thread = try await client.createThread(model: "sonnet")
        _ = try await client.send(threadID: thread, text: "keep if deletion fails", imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: thread, log: log)
        let folder = try nativeFolder(directory), transcript = folder.appendingPathComponent(thread + ".jsonl")
        let original = try Data(contentsOf: transcript)
        let outside = directory.appendingPathComponent("outside"), canary = outside.appendingPathComponent("canary")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: canary)
        let link = directory.appendingPathComponent("config/tasks/" + thread)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { try await client.deleteThread(id: thread); throw Failure(description: "Session artifact symlinks must be refused before deleting history") }
        catch ConfinedFileDeletion.Failure.unsafePath { }
        try require(try Data(contentsOf: transcript) == original, "Preflight failures must keep the original transcript")
        try require(try String(contentsOf: canary) == "untouched", "Deletion must never follow symlinks to unrelated files")
        let preserved = try await client.resumeThread(id: thread)
        try require(!Transcript.messages(from: preserved).isEmpty, "A failed deletion must leave the original session restorable")
        try FileManager.default.removeItem(at: link)
        let moved = directory.appendingPathComponent("original-project")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        do { try await client.deleteThread(id: thread); throw Failure(description: "Intermediate project symlinks must be refused") }
        catch ConfinedFileDeletion.Failure.unsafePath { }
        try require(try Data(contentsOf: moved.appendingPathComponent(thread + ".jsonl")) == original, "Intermediate links must not redirect native transcript deletion")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: moved, to: folder)
        try await client.deleteThread(id: thread)
        await client.disconnect()
    }

    private static func attachmentFixture(_ root: URL) throws -> FileAccessContext {
        let folder = root.appendingPathComponent("Attachments").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("attachment-helper")
        try #"""
#!/usr/bin/python3
import json,sys,pathlib,os,time
args=sys.argv[1:]
assert args[0]=='read'
assert 'ANTHROPIC_API_KEY' not in os.environ and 'CLAUDE_CONFIG_DIR' not in os.environ
root=pathlib.Path(args[args.index('--root')+1]);path=pathlib.Path(args[args.index('--path')+1])
assert path.parent==root
with (root/'helper-audit').open('a') as f:f.write(path.name+'\n')
if path.suffix=='.slow':
    (root/'helper-started').write_text(str(os.getpid()))
    time.sleep(20)
if path.suffix=='.bad':print(json.dumps({'error':'This file format is unsupported.'}));sys.exit(0)
images=[]
if '--page' in args:
    images=[{'mimeType':'image/png','data':'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jwioAAAAASUVORK5CYII='}]
print(json.dumps({'text':path.read_text(),'images':images}))
"""#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return FileAccessContext(directory: folder, scratchDirectory: root.appendingPathComponent("scratch"), toolExecutable: helper)
    }

    private static func attachment(_ access: FileAccessContext, text: String, ext: String = "txt") throws -> URL {
        let url = access.directory.appendingPathComponent(UUID().uuidString + "." + ext)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func filePrompt(_ url: URL, page: JSONValue? = nil) throws -> String {
        var args: [String: JSONValue] = ["path": .string(url.path)]
        args["page"] = page
        return "file:" + String(decoding: try JSONEncoder().encode(JSONValue.object(args)), as: UTF8.self)
    }

    public static func testScopedAttachmentReaderAndResume() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = try attachmentFixture(directory)
        let own = try attachment(access, text: "Owned document contents", ext: "docx")
        let outside = directory.appendingPathComponent(UUID().uuidString + ".txt")
        try "OTHER_NOTE_PRIVATE_CANARY".write(to: outside, atomically: true, encoding: .utf8)
        let link = access.directory.appendingPathComponent(UUID().uuidString + ".txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let client = ClaudeClient(requestTimeout: 2, environment: environment), log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let thread = try await client.createThread(model: "sonnet")
        try await client.configureFileAccess(threadID: thread, access: access)
        _ = try await client.send(threadID: thread, text: filePrompt(own), imagePaths: [], model: "sonnet", effort: "medium")
        var turns = try await awaitEvent("turn/completed", thread: thread, log: log)
        try require(turns[0]["turn"]["items"].array?.last?["text"].string == "Owned document contents", "Scoped tool must return the original attachment's contents")
        for (index, path) in [outside, link].enumerated() {
            _ = try await client.send(threadID: thread, text: filePrompt(path), imagePaths: [], model: "sonnet", effort: "medium")
            _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: index + 2)
        }
        var audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        try require(!audit.contains("OTHER_NOTE_PRIVATE_CANARY"), "Out-of-note and symlink reads must not reach the backend")
        try require(try String(contentsOf: access.directory.appendingPathComponent("helper-audit"), encoding: .utf8).split(separator: "\n").count == 1, "Rejected paths must not launch the parser")
        await client.disconnect()
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        try await client.configureFileAccess(threadID: thread, access: access)
        _ = try await client.resumeThread(id: thread)
        _ = try await client.send(threadID: thread, text: filePrompt(own, page: 1), imagePaths: [], model: "sonnet", effort: "high")
        turns = try await awaitEvent("turn/completed", thread: thread, log: log, count: 4)
        try require(turns.last?["turn"]["items"].array?.last?["text"].string == "Owned document contents", "Same native session must regain file access after resume")
        audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        try require(audit.contains("\"resume\": true, \"files\": true"), "File access must preserve native resume and cwd")
        let rows = audit.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        try require(rows.contains { $0["response"]["mcp_response"]["result"]["content"].array?.contains { $0["type"].string == "image" && $0["mimeType"].string == "image/png" } == true }, "PDF-page image content must reach MCP tool result")
        try await client.configureFileAccess(threadID: thread, access: nil)
        _ = try await client.send(threadID: thread, text: filePrompt(own), imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: 5)
        try require(try String(contentsOf: access.directory.appendingPathComponent("helper-audit"), encoding: .utf8).split(separator: "\n").count == 2, "Removing access must restore the no-files profile")
        await client.disconnect()
    }

    public static func testAttachmentReaderLimitsAndCancellation() async throws {
        let (directory, executable, environment) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = try attachmentFixture(directory)
        let oversized = try attachment(access, text: String(repeating: "x", count: 200_001))
        let unsupported = try attachment(access, text: "unsupported", ext: "bad")
        let slow = try attachment(access, text: "must not arrive after cancellation", ext: "slow")
        let client = ClaudeClient(requestTimeout: 2, environment: environment), log = EventLog()
        let reader = Task { for await event in client.events { await log.append(event) } }
        defer { reader.cancel() }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let thread = try await client.createThread(model: "sonnet")
        try await client.configureFileAccess(threadID: thread, access: access)
        for (index, file) in [oversized, unsupported].enumerated() {
            _ = try await client.send(threadID: thread, text: filePrompt(file), imagePaths: [], model: "sonnet", effort: "medium")
            _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: index + 1)
        }
        _ = try await client.send(threadID: thread, text: filePrompt(unsupported, page: .number(1.5)), imagePaths: [], model: "sonnet", effort: "medium")
        _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: 3)
        let audit = try String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        try require(!audit.contains(String(repeating: "x", count: 200_001)), "Oversized extraction must not be forwarded")
        try require(audit.contains("oversized result") && audit.contains("This file format is unsupported.") && audit.contains("invalid, duplicated"), "Parser and argument failures must produce explicit MCP errors")
        let active = try await client.send(threadID: thread, text: filePrompt(slow), imagePaths: [], model: "sonnet", effort: "medium")
        do { try await client.configureFileAccess(threadID: thread, access: nil); throw Failure(description: "Cannot change file capabilities during a turn") }
        catch ClaudeError.busy { }
        let started = access.directory.appendingPathComponent("helper-started")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(FileManager.default.fileExists(atPath: started.path), "Slow helper did not start")
        let processID = Int32(try String(contentsOf: started, encoding: .utf8))!
        try await client.interrupt(threadID: thread, turnID: active)
        _ = try await awaitEvent("turn/completed", thread: thread, log: log, count: 4)
        await client.disconnect()
        try require(kill(processID, 0) != 0, "Interrupted helper must be cancelled and reaped before disconnect finishes")
    }

    private static let server = #"""
#!/usr/bin/env python3
import sys,os,json,uuid,time,pathlib,re,signal
scenario='FIXTURE_SCENARIO'
args=sys.argv[1:]
if 'auth' in args and 'status' in args:
    print(json.dumps({'loggedIn':True,'authMethod':'claude.ai','apiProvider':'firstParty'}))
    sys.exit(0)
def arg(name,default=None):
    return args[args.index(name)+1] if name in args else default
assert '--safe-mode' in args and '--restricted' in args and '--disable-slash-commands' in args
assert '--replay-user-messages' in args
servers=json.loads(arg('--mcp-config'))['mcpServers'];files=bool(servers)
assert '--strict-mcp-config' in args and (not files or servers=={'floating_ai_files':{'type':'sdk','name':'floating_ai_files'}})
assert arg('--tools')=='WebSearch,WebFetch' and arg('--allowedTools')==('WebSearch,WebFetch,mcp__floating_ai_files__read_attachment' if files else 'WebSearch,WebFetch')
assert arg('--permission-mode')=='dontAsk' and arg('--permission-prompts')=='none'
assert arg('--system-prompt-snapshot')=='off' and json.loads(arg('--settings'))['disableAllHooks']
sid=arg('--session-id',arg('--resume','catalog'))
resume='--resume' in args
effort='high';model=arg('--model','sonnet');parent=None;held=False
root=pathlib.Path.cwd();audit=root/'audit.jsonl'
folder=pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])/'projects'/re.sub('[^a-zA-Z0-9]','-',str(root.resolve()))
history=folder/(sid+'.jsonl')
if scenario=='late-writer':signal.signal(signal.SIGTERM,signal.SIG_IGN)
def log(value):
    with audit.open('a') as f:f.write(json.dumps(value)+'\n')
log({'kind':'launch','session':sid,'resume':resume,'files':files})
if resume:
    assert history.exists()
    for line in history.read_text().splitlines():
        record=json.loads(line)
        if record.get('uuid'):parent=record['uuid']
def send(value,split=False):
    data=(json.dumps(value,ensure_ascii=False)+'\n').encode()
    if split:
        at=data.find('你'.encode())+1
        if at<=0:at=max(1,len(data)//2)
        os.write(1,data[:at]);time.sleep(.005);os.write(1,data[at:])
    else:os.write(1,data)
def append(record):
    global parent
    folder.mkdir(parents=True,exist_ok=True)
    record.update({'parentUuid':parent,'sessionId':sid,'isSidechain':False})
    with history.open('a') as f:f.write(json.dumps(record)+'\n')
    parent=record['uuid']
models=[{'value':'default','resolvedModel':'claude-sonnet-test','displayName':'Default (recommended)','supportsEffort':True,'supportedEffortLevels':['medium']},
 {'value':'sonnet','resolvedModel':'claude-sonnet-test','displayName':'Sonnet','supportsEffort':True,'supportedEffortLevels':['low','medium','high','xhigh']},
 {'value':'opus','resolvedModel':'claude-opus-test','displayName':'Opus','supportsEffort':True,'supportedEffortLevels':['medium','high']},
 {'value':'haiku','resolvedModel':'claude-haiku-test','displayName':'Haiku','supportsEffort':False}]
def result(interrupted=False):
    value={'type':'result','subtype':'success','is_error':False,'uuid':str(uuid.uuid4()),'session_id':sid,'result':''}
    send(value);send(value)
for line in sys.stdin:
    value=json.loads(line)
    if value['type']=='control_request':
        req=value['request'];sub=req['subtype'];response={}
        if sub=='initialize':
            assert req['hooks']=={} and req['agents']=={} and req['sdkMcpServers']==(['floating_ai_files'] if files else []) and req['skills']==[]
            response={'models':models,'claude_code_version':'2.1.308' if scenario=='bad-version' else '2.1.307',
                      'commands':[],'account':{'tokenSource':'oauth','apiKeySource':'none'}}
            if files:
                for method in ['initialize','notifications/initialized','tools/list']:
                    send({'type':'control_request','request_id':'sdk-'+method,'request':{'subtype':'mcp_message','server_name':'floating_ai_files','message':{'jsonrpc':'2.0','id':method,'method':method,'params':{'protocolVersion':'2024-11-05'}}}})
        elif sub=='mcp_status':response={'mcpServers':[{'name':'unsafe'}] if scenario=='unsafe-mcp' else ([{'name':'floating_ai_files','status':'connected','source':'sdk','tools':[{'name':'read_attachment'}]}] if files else [])}
        elif sub=='get_settings':response={'effective':{'disableAllHooks':scenario!='unsafe-hooks'},'applied':{'model':'claude-'+model+'-test','effort':effort}}
        elif sub=='list_models':
            if scenario=='stall-models':continue
            response={'models':models}
        elif sub=='set_model':model=req['model'];response={'model':'claude-'+model+'-test'}
        elif sub=='apply_flag_settings':effort=req['settings']['effortLevel']
        elif sub=='interrupt':
            if held:result(True);held=False
            response={'still_queued':[]}
        else:raise RuntimeError('Unexpected control request '+sub)
        reply={'type':'control_response','response':{'subtype':'success','request_id':value['request_id'],'response':response}}
        send(reply,True);send(reply)
    elif value['type']=='control_response':
        log(value['response'])
        if str(value['response']['request_id']).startswith('file-read-'):
            reply=value['response'].get('response',{}).get('mcp_response',{}).get('result',{})
            text=''.join(c.get('text','') for c in reply.get('content',[])) or 'Attachment capability unavailable.'
            completed={'type':'assistant','uuid':str(uuid.uuid4()),'session_id':sid,'message':{'id':'msg_'+str(uuid.uuid4()),'role':'assistant','content':[{'type':'text','text':text}]}}
            append(completed);send(completed);result()
    elif value['type']=='user':
        assert value['client_composed'] is True and value['session_id']==sid
        assert all(c['type'] in ['text','image'] for c in value['message']['content'])
        log({'kind':'user','session':sid,'effort':effort,'model':model})
        text=''.join(c.get('text','') for c in value['message']['content'])
        if text=='crash-before-ack':sys.exit(14)
        append({'type':'user','uuid':value['uuid'],'message':value['message']})
        send(value)
        if text=='api-error':
            send({'type':'result','uuid':str(uuid.uuid4()),'session_id':sid,'subtype':'success','is_error':True,'errors':[],
                  'result':'API Error: authentication failed for sk-ant-secret','user_message_uuid':value['uuid']})
            continue
        if text=='crash':sys.exit(13)
        if text=='malformed':os.write(1,b'{malformed\n');continue
        if text=='hold':held=True;continue
        send({'type':'system','subtype':'init','tools':['WebSearch','WebFetch']+(['mcp__floating_ai_files__read_attachment'] if files else []),'session_id':sid})
        if text.startswith('file:'):
            held=True
            send({'type':'control_request','request_id':'file-read-'+str(uuid.uuid4()),'request':{'subtype':'mcp_message','server_name':'floating_ai_files','message':{'jsonrpc':'2.0','id':str(uuid.uuid4()),'method':'tools/call','params':{'name':'read_attachment','arguments':json.loads(text[5:])}}}})
            continue
        send({'type':'unknown_future_event','arbitrary':True})
        if text=='approval':send({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'touch forbidden'}}})
        apiid='msg_'+str(uuid.uuid4())
        send({'type':'stream_event','uuid':str(uuid.uuid4()),'session_id':sid,'event':{'type':'message_start','message':{'id':apiid}}})
        for delta in ['你好 ','🌎']:
            chunk={'type':'stream_event','uuid':str(uuid.uuid4()),'session_id':sid,'event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':delta}}}
            send(chunk,True);send(chunk)
        completed={'type':'assistant','uuid':str(uuid.uuid4()),'session_id':sid,'message':{'id':apiid,'role':'assistant','content':[{'type':'text','text':'你好 🌎'}]}}
        append(completed);send(completed,True)
        result()
if scenario=='late-writer' and sid!='catalog':
    time.sleep(.2)
    append({'type':'assistant','uuid':str(uuid.uuid4()),'message':{'role':'assistant','content':[{'type':'text','text':'final write on exit'}]}})
    (root/(sid+'.exited')).write_text('exited')
"""#
}
