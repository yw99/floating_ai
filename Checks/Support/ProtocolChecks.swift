import Foundation
import FloatingAICore

public enum ProtocolChecks {
    private static func fixture(version: String = "0.134.0", scenario: String = "normal") throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-codex")
        try Self.server.replacingOccurrences(of: "0.134.0", with: version)
            .replacingOccurrences(of: "fixture-scenario", with: scenario)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (directory, script)
    }

    public static func testConnectPaginatesModelsAndDisablesEachMCPWithoutChangingConfig() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        let info = try await client.connect(executableURL: executable, workingDirectory: directory)
        try require(info.isLoggedIn)
        try equal(info.version, "0.134.0")
        try equal(info.models.map(\.id), ["model-a", "model-b"])
        try equal(info.models[0].supportedReasoningEfforts.map(\.reasoningEffort), ["medium", "high"])
        let args = try await client.request(method: "test/args")
        try require(args.array?.contains(.string("mcp_servers.test_server.enabled=false")) == true)
        try require(args.array?.contains(.string("features.shell_tool=false")) == true)
        try require(args.array?.contains(.string("model_reasoning_effort=\"medium\"")) == true)
        let environment = try await client.request(method: "test/environment")
        let paths = (environment["PATH"].string ?? "").split(separator: ":").map(String.init)
        try equal(paths.first, directory.path)
        try require(paths.contains("/opt/homebrew/bin") && paths.contains("/usr/local/bin") && paths.contains("/usr/bin"))
        try equal(Set(paths).count, paths.count)
        await client.disconnect()
    }

    public static func testSplitUnicodeResponsesDuplicateRepliesAndDeclinedServerRequest() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let eventTask = Task { try await notification("test/declined", from: client) }
        let response = try await client.request(method: "test/split")
        try equal(response["text"].string, "你好 🌎")
        _ = try await client.request(method: "test/approval")
        let declined = try await eventTask.value
        try equal(declined?["decision"].string, "cancel")
        let after = try await client.request(method: "test/split")
        try equal(after["text"].string, "你好 🌎")
        await client.disconnect()
    }

    public static func testTimeoutDoesNotBreakFutureRequestsAndReconnectIgnoresOldProcess() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 1)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        do {
            _ = try await client.request(method: "test/stall")
            try fail("Expected timeout")
        } catch { try equal(error as? CodexError, .timeout("test/stall")) }
        let response = try await client.request(method: "test/split")
        try equal(response["text"].string, "你好 🌎")
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let after = try await client.request(method: "test/split")
        try equal(after["text"].string, "你好 🌎")
        await client.disconnect()
    }

    public static func testTurnOptionsAreSafeAndCompletedNotificationBeforeResponseDoesNotLockThread() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let thread = try await client.createThread(model: "model-a")
        try equal(thread, "thread-test")
        let first = try await client.send(threadID: thread, text: "hello", imagePaths: ["/tmp/image.png"], model: "model-a", effort: "high")
        try equal(first, "turn-test")
        let params = try await client.request(method: "test/lastTurn")
        try equal(params["environments"], .array([]))
        try equal(params["sandboxPolicy"]["type"].string, "readOnly")
        try equal(params["approvalPolicy"].string, "never")
        try equal(params["input"][1]["type"].string, "localImage")
        _ = try await client.send(threadID: thread, text: "second", imagePaths: [], model: "model-a", effort: "medium")
        await client.disconnect()
    }

    public static func testCrashFailsPendingAndCanReconnect() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 2)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        do { _ = try await client.request(method: "test/crash"); try fail("Expected disconnection") }
        catch { guard case CodexError.disconnected = error else { return try fail("Unexpected error: \(error)") } }
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let response = try await client.request(method: "test/split")
        try equal(response["text"].string, "你好 🌎")
        await client.disconnect()
    }

    public static func testErrorCancellationAndMalformedInput() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        do { _ = try await client.request(method: "test/error"); try fail("Expected server error") }
        catch { try equal(error as? CodexError, .server(code: 42, message: "Fixture rejection")) }
        let canceled = Task { try await client.request(method: "test/stall") }
        try await Task.sleep(nanoseconds: 50_000_000)
        canceled.cancel()
        do { _ = try await canceled.value; try fail("Expected cancellation") }
        catch { try require(error is CancellationError) }
        let response = try await client.request(method: "test/split")
        try equal(response["text"].string, "你好 🌎")
        do { _ = try await client.request(method: "test/malformed"); try fail("Expected disconnection") }
        catch { guard case CodexError.disconnected = error else { return try fail("Unexpected error: \(error)") } }
        await client.disconnect()
    }

    public static func testModernProfileRetainsDynamicEffortsAndLegacyHistory() async throws {
        for version in ["0.151.0-alpha.7.2", "0.163.0", "0.163.1-alpha.1"] {
            let (directory, executable) = try fixture(version: version)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CodexClient(requestTimeout: 5)
            let info = try await client.connect(executableURL: executable, workingDirectory: directory)
            try equal(info.version, version)
            try equal(info.models[0].supportedReasoningEfforts.map(\.reasoningEffort), ["medium", "high", "max", "ultra"])
            let thread = try await client.createThread(model: "model-a")
            let start = try await client.request(method: "test/lastThread")
            try equal(start["historyMode"].string, "legacy")
            _ = try await client.send(threadID: thread, text: "hello", imagePaths: ["/tmp/image.png"], model: "model-a", effort: "ultra")
            let params = try await client.request(method: "test/lastTurn")
            try equal(params["effort"].string, "ultra")
            try equal(params["input"][1]["type"].string, "localImage")
            let args = try await client.request(method: "test/args")
            try require(args.array?.contains(.string("features.view_image=false")) == true)
            try require(args.array?.contains(.string("features.code_mode_host=true")) == true)
            try require(args.array?.contains(.string("features.code_mode=false")) == true)
            await client.disconnect()
        }
    }

    public static func testUnverifiedVersionFailsBeforeAuthenticationOrThreads() async throws {
        let (directory, executable) = try fixture(version: "0.164.0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        do {
            _ = try await client.connect(executableURL: executable, workingDirectory: directory,
                                         authentication: .apiKey("sk-offline-version-fixture"))
            try fail("An unverified version must not silently become an executable agent")
        } catch { try equal(error as? CodexError, .incompatibleVersion("0.164.0")) }
        let audit = try String(contentsOf: directory.appendingPathComponent("fixture-audit.jsonl"), encoding: .utf8)
        try require(!audit.contains("account/login/start") && !audit.contains("thread/start"))
        await client.disconnect()
    }

    public static func testConcurrentThreadsAndInterruption() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let first = try await client.createThread(model: "model-a")
        let second = try await client.createThread(model: "model-a")
        async let firstTurn = client.send(threadID: first, text: "keep-running", imagePaths: [], model: "model-a", effort: "medium")
        async let secondTurn = client.send(threadID: second, text: "keep-running", imagePaths: [], model: "model-a", effort: "high")
        let turns = try await (firstTurn, secondTurn)
        try equal(turns.0, "turn-running-" + first)
        try equal(turns.1, "turn-running-" + second)
        try require(turns.0 != turns.1)
        do {
            _ = try await client.send(threadID: first, text: "duplicate", imagePaths: [], model: "model-a", effort: "medium")
            try fail("A second active turn on the same thread should be rejected")
        } catch { try equal(error as? CodexError, .protocolError("This conversation already has an active turn.")) }
        do {
            try await client.configureFileAccess(threadID: first, access: nil)
            try fail("An active conversation's reader must not be reconfigured")
        } catch { try require(error.localizedDescription.contains("Wait for this conversation")) }
        let completed = Task { try await notification("turn/completed", from: client) }
        try await client.interrupt(threadID: first, turnID: turns.0)
        let event = try await completed.value
        try equal(event?["threadId"].string, first)
        try equal(event?["turn"]["status"].string, "interrupted")
        _ = try await client.send(threadID: first, text: "after-stop", imagePaths: [], model: "model-a", effort: "medium")
        try await client.interrupt(threadID: second, turnID: turns.1)
        await client.disconnect()
    }

    public static func testPermanentDeletionTargetsOneThreadAndBlocksConcurrentReuse() async throws {
        let (directory, executable) = try fixture(version: "0.163.0", scenario: "delete-hold")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let deleted = try await client.createThread(model: "model-a")
        let retained = try await client.createThread(model: "model-a")
        let deletion = Task { try await client.deleteThread(id: deleted) }
        var observed = false
        for _ in 0..<100 {
            if try await client.request(method: "test/deleteState")["pending"].bool == true { observed = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(observed)
        do {
            _ = try await client.send(threadID: deleted, text: "must not send", imagePaths: [], model: "model-a", effort: "medium")
            try fail("Sending while deleting must fail")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected deletion guard") } }
        do {
            _ = try await client.resumeThread(id: deleted)
            try fail("Resuming while deleting must fail")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected deletion guard") } }
        _ = try await client.send(threadID: retained, text: "unrelated conversation", imagePaths: [], model: "model-a", effort: "medium")
        _ = try await client.request(method: "test/releaseDelete")
        try await deletion.value
        try await client.deleteThread(id: deleted) // Local repeat is idempotent.
        let state = try await client.request(method: "test/deleteState")
        try equal(state["ids"], .array([.string(deleted)]))
        try equal(state["count"].number, 1)
        do {
            _ = try await client.readThread(id: deleted)
            try fail("Deleted conversations must not be reloaded")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected deleted guard") } }
        let audit = try String(contentsOf: directory.appendingPathComponent("fixture-audit.jsonl"), encoding: .utf8)
        try require(!audit.contains("thread/archive"))
        await client.disconnect()
    }

    public static func testPermanentDeletionRetriesOnlyConfirmedMissingHistories() async throws {
        for version in ["0.151.0-alpha.7.2", "0.163.0"] {
            let (directory, executable) = try fixture(version: version, scenario: "delete-missing")
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CodexClient(requestTimeout: 5)
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            try await client.deleteThread(id: "thread-deleted-before-crash")
            await client.disconnect()
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            try await client.deleteThread(id: "thread-deleted-before-crash")
            await client.disconnect()
        }
        for scenario in ["delete-failure", "delete-other-missing", "delete-unsupported", "delete-malformed"] {
            let (directory, executable) = try fixture(version: "0.163.0", scenario: scenario)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CodexClient(requestTimeout: 5)
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            for _ in 0..<2 {
                do {
                    try await client.deleteThread(id: "retained-thread")
                    try fail("Deletion errors must not become silent success")
                } catch let error as CodexError {
                    if scenario == "delete-unsupported" {
                        guard case .protocolError(let message) = error else { return try fail("Expected upgrade error") }
                        try require(message.contains("Upgrade"))
                    }
                }
            }
            let state = try await client.request(method: "test/deleteState")
            try equal(state["count"].number, 2) // Failure must remain retryable.
            await client.disconnect()
        }
    }

    public static func testPermanentDeletionRejectsLegacyAndBusyThreads() async throws {
        let (legacyDirectory, legacyExecutable) = try fixture()
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let legacy = CodexClient(requestTimeout: 5)
        _ = try await legacy.connect(executableURL: legacyExecutable, workingDirectory: legacyDirectory)
        do {
            try await legacy.deleteThread(id: "legacy-thread")
            try fail("Legacy CLI cannot permanently delete")
        } catch {
            guard case CodexError.protocolError(let message) = error else { return try fail("Expected upgrade error") }
            try require(message.contains("0.151") && message.contains("Upgrade"))
        }
        let legacyAudit = try String(contentsOf: legacyDirectory.appendingPathComponent("fixture-audit.jsonl"), encoding: .utf8)
        try require(!legacyAudit.contains("thread/delete") && !legacyAudit.contains("thread/archive"))
        await legacy.disconnect()

        let (directory, executable) = try fixture(version: "0.163.0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let first = try await client.createThread(model: "model-a")
        let second = try await client.createThread(model: "model-a")
        let firstSend = Task { try await client.send(threadID: first, text: "keep-running", imagePaths: [], model: "model-a", effort: "medium") }
        var observed = false
        for _ in 0..<100 {
            if try await client.request(method: "test/lastTurn")["threadId"].string == first { observed = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(observed)
        do {
            try await client.deleteThread(id: first)
            try fail("A turn awaiting acknowledgement must prevent deletion")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected active turn guard") } }
        let secondTurn = try await client.send(threadID: second, text: "keep-running", imagePaths: [], model: "model-a", effort: "medium")
        let firstTurn = try await firstSend.value
        do {
            try await client.deleteThread(id: first)
            try fail("An active turn must prevent deletion")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected active turn guard") } }
        try await client.interrupt(threadID: first, turnID: firstTurn)
        try await client.deleteThread(id: first)
        try await client.interrupt(threadID: second, turnID: secondTurn)
        await client.disconnect()
    }

    public static func testLiveWebSearchOnFreshAndResumedThreadsKeepsLocalToolsDisabled() async throws {
        for version in ["0.134.0", "0.151.0-alpha.7.2", "0.163.0"] {
            let (directory, executable) = try fixture(version: version)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CodexClient(requestTimeout: 5)
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            let args = try await client.request(method: "test/args")
            try require(args.array?.contains(.string("web_search=\"live\"")) == true)
            try require(args.array?.contains(.string("features.standalone_web_search=true")) == true)
            try require(args.array?.contains(.string("features.standalone_web_search=false")) == false)
            try require(args.array?.contains(.string("features.browser_use=false")) == true)
            try require(args.array?.contains(.string("features.code_mode_host=true")) == true)
            try require(args.array?.contains(.string("features.skip_host_skill_discovery=true")) == true)
            let thread = try await client.createThread(model: "model-a")
            let fresh = try await client.request(method: "test/lastThread")
            try equal(fresh["environments"], .array([]))
            await client.disconnect()
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            _ = try await client.resumeThread(id: thread)
            let resumed = try await client.request(method: "test/lastResume")
            for params in [fresh, resumed] {
                try equal(params["config"]["web_search"].string, "live")
                try equal(params["config"]["features.standalone_web_search"].bool, true)
                try equal(params["config"]["features.code_mode_host"].bool, true)
                try equal(params["config"]["features.code_mode"].bool, false)
                try equal(params["config"]["features.skip_host_skill_discovery"].bool, true)
                try equal(params["config"]["features.shell_tool"].bool, false)
                try equal(params["config"]["features.browser_use"].bool, false)
                try equal(params["config"]["mcp_servers.test_server.enabled"].bool, false)
                try equal(params["sandbox"].string, "read-only")
                let instructions = params["baseInstructions"].string ?? ""
                try require(instructions.contains("built-in web search") && instructions.contains("Markdown links"))
                try require(!instructions.contains("Do not attempt tools") && !instructions.contains("or use tools in this application"))
            }
            _ = try await client.send(threadID: thread, text: "Search the web", imagePaths: [], model: "model-a", effort: "medium")
            let turn = try await client.request(method: "test/lastTurn")
            try equal(turn["environments"], .array([]))
            try equal(turn["sandboxPolicy"]["networkAccess"].bool, false)
            let searchEvent = Task { try await notification("item/completed", from: client) }
            _ = try await client.request(method: "test/webSearch")
            let observed = try await searchEvent.value
            try equal(observed?["item"]["type"].string, "webSearch")
            await client.disconnect()
        }
    }

    public static func testScopedAttachmentReaderCreationSwitchingAndRestore() async throws {
        let (directory, executable) = try fixture(version: "0.163.0")
        defer { try? FileManager.default.removeItem(at: directory) }
        func context(_ name: String) throws -> FileAccessContext {
            let files = directory.appendingPathComponent(name), scratch = directory.appendingPathComponent(name + "-scratch")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return FileAccessContext(directory: files, scratchDirectory: scratch, toolExecutable: executable)
        }
        let firstAccess = try context("first"), secondAccess = try context("second")
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        let first = try await client.createThread(model: "model-a", fileAccess: firstAccess)
        let fresh = try await client.request(method: "test/lastThread")
        let firstKey = try fileServerKey(fresh)
        try equal(fresh["config"][firstKey]["command"].string, executable.path)
        try equal(fresh["config"][firstKey]["args"], .array(["--mcp", "--root", firstAccess.directory.path, "--scratch", firstAccess.scratchDirectory.path].map(JSONValue.string)))
        try equal(fresh["config"][firstKey]["enabled_tools"], ["read_attachment"])
        try equal(fresh["config"][firstKey]["tools"]["read_attachment"]["approval_mode"], "approve")
        try equal(fresh["config"]["mcp_servers.test_server.enabled"], false)
        try equal(fresh["config"]["features.shell_tool"], false)
        try equal(fresh["environments"], [])
        try require(fresh["baseInstructions"].string?.contains("read_attachment") == true)
        let second = try await client.createThread(model: "model-b")
        let plain = try await client.request(method: "test/lastThread")
        try equal(plain["config"][firstKey]["enabled"], false)
        try await client.configureFileAccess(threadID: second, access: secondAccess)
        let changed = try await client.request(method: "test/lastResume")
        let secondKey = try fileServerKey(changed)
        try require(firstKey != secondKey)
        try equal(changed["threadId"].string, second)
        try equal(changed["config"][firstKey]["enabled"], false)
        try equal(changed["config"][secondKey]["args"][2].string, secondAccess.directory.path)
        let before = try await client.request(method: "test/fileState")
        try await client.configureFileAccess(threadID: second, access: secondAccess)
        let same = try await client.request(method: "test/fileState")
        try equal(before["unsubscribed"], same["unsubscribed"])
        try await client.configureFileAccess(threadID: first, access: nil)
        let cleared = try await client.request(method: "test/lastResume")
        try equal(cleared["config"][firstKey]["enabled"], false)
        try require(cleared["config"].object?.values.contains(where: { $0["enabled"].bool == true }) == false)
        _ = try await client.send(threadID: first, text: "ordinary chat", imagePaths: [], model: "model-a", effort: "medium")
        _ = try await client.send(threadID: second, text: "read the attachment", imagePaths: [], model: "model-b", effort: "medium")
        let turn = try await client.request(method: "test/lastTurn")
        try equal(turn["environments"], [])
        try equal(turn["sandboxPolicy"]["networkAccess"], false)
        await client.disconnect()
        _ = try await client.connect(executableURL: executable, workingDirectory: directory)
        try await client.configureFileAccess(threadID: second, access: secondAccess)
        let beforeResume = try await client.request(method: "test/fileState")
        try equal(beforeResume["unsubscribed"], [])
        _ = try await client.resumeThread(id: second)
        let restored = try await client.request(method: "test/lastResume")
        let restoredKey = try fileServerKey(restored)
        try equal(restored["threadId"].string, second)
        try equal(restored["config"][restoredKey]["args"][2].string, secondAccess.directory.path)
        _ = try await client.send(threadID: second, text: "restored", imagePaths: [], model: "model-b", effort: "medium")
        await client.disconnect()
    }

    public static func testAttachmentReaderFailureAndLegacyVersionsDoNotSend() async throws {
        for version in ["0.134.0", "0.151.0", "0.163.0"] {
            let (directory, executable) = try fixture(version: version, scenario: "file-reader-unavailable")
            defer { try? FileManager.default.removeItem(at: directory) }
            let scratch = directory.appendingPathComponent("scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let access = FileAccessContext(directory: directory, scratchDirectory: scratch, toolExecutable: executable)
            let client = CodexClient(requestTimeout: 5)
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            let thread = try await client.createThread(model: "model-a")
            do { try await client.configureFileAccess(threadID: thread, access: access); try fail("Expected unavailable reader") }
            catch { try require(error.localizedDescription.contains(version == "0.163.0" ? "attachment reader" : "0.163")) }
            let state = try await client.request(method: "test/fileState")
            if version == "0.163.0" {
                try equal(state["unsubscribed"], [.string(thread)])
                do { _ = try await client.send(threadID: thread, text: "must not send", imagePaths: [], model: "model-a", effort: "medium"); try fail("Expected reader guard") }
                catch { try require(error.localizedDescription.contains("attachment reader")) }
                let lastTurn = try await client.request(method: "test/lastTurn")
                try equal(lastTurn, [:])
                try await client.configureFileAccess(threadID: thread, access: nil)
            } else {
                try equal(state["unsubscribed"], [])
                do { _ = try await client.createThread(model: "model-a", fileAccess: access); try fail("Expected version guard") }
                catch { try require(error.localizedDescription.contains("0.163")) }
            }
            _ = try await client.send(threadID: thread, text: "text still works", imagePaths: [], model: "model-a", effort: "medium")
            await client.disconnect()
        }
    }

    private static func fileServerKey(_ params: JSONValue) throws -> String {
        guard let keys = params["config"].object?.keys.filter({ $0.hasPrefix("mcp_servers.fa_files_") && params["config"][$0]["enabled"].bool == true }), keys.count == 1,
              let key = keys.first else { throw CheckFailure(description: "Expected one scoped attachment server") }
        return key
    }

    public static func testIndependentAPIKeyAuthenticationAndReconnect() async throws {
        for version in ["0.134.0", "0.151.0-alpha.7.2", "0.163.0"] {
            let (directory, executable) = try fixture(version: version)
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = "sk-proj-offline-fixture-not-a-real-secret"
            let auth = CodexAuthentication.apiKey(key)
            try require(!String(describing: auth).contains(key) && !String(reflecting: auth).contains(key))
            let inherited = ["PATH": "/usr/bin:/bin", "CODEX_HOME": directory.path,
                             "OPENAI_API_KEY": "inherited-fixture", "CODEX_API_KEY": "inherited-fixture",
                             "CODEX_ACCESS_TOKEN": "inherited-fixture", "OPENAI_BASE_URL": "https://invalid.example",
                             "CHATGPT_BASE_URL": "https://invalid.example", "KEEP_FIXTURE": "retained"]
            let client = CodexClient(requestTimeout: 5, environment: inherited)
            for round in 0..<2 {
                let info = try await client.connect(executableURL: executable, workingDirectory: directory, authentication: auth)
                try equal(info.accountKind, .apiKey)
                try require(info.isLoggedIn)
                let args = try await client.request(method: "test/args")
                try require(args.array?.contains(.string("cli_auth_credentials_store=\"ephemeral\"")) == true)
                try require(args.array?.contains(.string("model_provider=\"openai\"")) == true)
                try require(args.array?.contains(.string("openai_base_url=\"https://api.openai.com/v1\"")) == true)
                try require(!(args.array ?? []).contains(where: { $0.string?.hasPrefix("model_providers.openai.") == true }))
                try require(!(args.array ?? []).contains(where: { $0.string?.contains(key) == true }))
                let environment = try await client.request(method: "test/environment")
                try equal(environment["CODEX_HOME"].string, directory.path)
                try equal(environment["KEEP_FIXTURE"].string, "retained")
                try equal(environment["credentialVariableNames"], .array([]))
                try equal(environment["credentialInEnvironment"].bool, false)
                do {
                    _ = try await client.send(threadID: "unverified-thread", text: "should not send", imagePaths: [], model: "model-a", effort: "medium")
                    try fail("API send must require a verified thread provider")
                } catch { guard case CodexError.protocolError = error else { return try fail("Expected unverified-provider rejection") } }
                let thread = try await client.createThread(model: "model-a")
                _ = try await client.resumeThread(id: thread)
                let start = try await client.request(method: "test/lastThread")
                let resume = try await client.request(method: "test/lastResume")
                try equal(start["modelProvider"].string, "openai")
                try equal(resume["modelProvider"].string, "openai")
                for params in [start, resume] {
                    try equal(params["config"]["model_provider"].string, "openai")
                    try equal(params["config"]["cli_auth_credentials_store"].string, "ephemeral")
                    try equal(params["config"]["openai_base_url"].string, "https://api.openai.com/v1")
                }
                try equal(resume["config"]["features.shell_tool"].bool, false)
                let turnID = try await client.send(threadID: thread, text: "API fixture message", imagePaths: [], model: "model-a", effort: "high")
                try equal(turnID, "turn-test")
                let turn = try await client.request(method: "test/lastTurn")
                try equal(turn["threadId"].string, thread)
                try equal(turn["model"].string, "model-a")
                try equal(turn["effort"].string, "high")
                try equal(turn["input"][0]["text"].string, "API fixture message")
                let audit = try await client.request(method: "test/apiAudit")
                try equal(audit["loginCount"].number, Double(round + 1))
                try equal(audit["verifiedBeforeLogin"].bool, true)
                try equal(audit["mcpDisabledBeforeLogin"].bool, true)
                try equal(audit["keyWasInArguments"].bool, false)
                let methods = audit["methods"].array?.compactMap(\.string) ?? []
                try require(!methods.contains("account/logout") && !methods.contains(where: { $0.hasPrefix("config/") && $0 != "config/read" }))
                try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path))
                await client.disconnect()
            }
            // Switching back uses the existing Codex sign-in without logout or an API-key override.
            let regular = try await client.connect(executableURL: executable, workingDirectory: directory)
            try equal(regular.accountKind, .chatGPT)
            let args = try await client.request(method: "test/args")
            try require(args.array?.contains(.string("cli_auth_credentials_store=\"ephemeral\"")) == false)
            await client.disconnect()
        }
    }

    public static func testAPIKeyBootstrapNotificationsAndRedaction() async throws {
        let (directory, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "sk-proj-redaction-fixture-not-a-real-secret"
        let client = CodexClient(requestTimeout: 5)
        _ = try await client.connect(executableURL: executable, workingDirectory: directory, authentication: .apiKey(key))
        let observed = Task { try await notificationsUntil("test/authFence", from: client) }
        _ = try await client.request(method: "test/authNotifications")
        let events = try await observed.value
        try require(!events.contains(where: { $0.0 == "account/login/completed" }))
        try equal(events.filter { $0.0 == "account/updated" }.count, 1)
        try equal(events.last?.1["message"].string, "Key [redacted]; masked [redacted]")
        do { _ = try await client.request(method: "test/keyError"); try fail("Expected key error") }
        catch {
            guard case CodexError.server(let code, let message) = error else { return try fail("Expected sanitized server error") }
            try equal(code, 401)
            try require(message.contains("Incorrect API key") && !message.contains(key) && !message.contains("sk-proj"))
        }
        let echoed = try await client.request(method: "test/keyResponse")
        try equal(echoed["key"].string, "[redacted]")
        await client.disconnect()

        // An invalid key that happens to equal a protocol request ID must fail
        // cleanly, without redacting that ID and stranding its continuation.
        let shortKeyClient = CodexClient(requestTimeout: 1)
        do {
            _ = try await shortKeyClient.connect(executableURL: executable, workingDirectory: directory, authentication: .apiKey("1"))
            try fail("The invalid short key must not produce a usable connection")
        } catch {
            guard case CodexError.protocolError = error else { return try fail("Short key must fail validation rather than response routing") }
        }
        await shortKeyClient.disconnect()
    }

    public static func testAPIKeyConfigurationFailuresDoNotReceiveCredential() async throws {
        for scenario in ["bad-store", "bad-provider", "bad-endpoint", "bad-credentials", "bad-headers", "forced-chatgpt", "managed-store", "managed-chatgpt", "managed-provider", "managed-endpoint", "managed-login-methods", "managed-no-login-methods"] {
            let (directory, executable) = try fixture(version: "0.163.0", scenario: scenario)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CodexClient(requestTimeout: 5)
            do {
                _ = try await client.connect(executableURL: executable, workingDirectory: directory,
                                             authentication: .apiKey("sk-proj-policy-fixture-not-a-real-key"))
                try fail("Expected configuration rejection: \(scenario)")
            } catch { guard case CodexError.protocolError = error else { return try fail("Expected configuration error: \(scenario)") } }
            let audit = try String(contentsOf: directory.appendingPathComponent("fixture-audit.jsonl"), encoding: .utf8)
            try require(!audit.contains("account/login/start") && !audit.contains("account/logout"))
            await client.disconnect()
        }
        let (directory, executable) = try fixture(scenario: "login-error")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 5)
        let key = "sk-proj-rejected-fixture-not-a-real-key"
        do {
            _ = try await client.connect(executableURL: executable, workingDirectory: directory, authentication: .apiKey(key))
            try fail("Expected login rejection")
        } catch {
            guard case CodexError.server(let code, let message) = error else { return try fail("Expected sanitized authentication rejection") }
            try equal(code, 403)
            try require(!message.contains(key) && message.contains("authentication policy"))
        }
        await client.disconnect()

        let (threadDirectory, threadExecutable) = try fixture(scenario: "bad-thread-provider")
        defer { try? FileManager.default.removeItem(at: threadDirectory) }
        let threadClient = CodexClient(requestTimeout: 5)
        _ = try await threadClient.connect(executableURL: threadExecutable, workingDirectory: threadDirectory, authentication: .apiKey(key))
        do {
            _ = try await threadClient.resumeThread(id: "existing-custom-provider-thread")
            try fail("Resume must confirm OpenAI provider before any turn")
        } catch { guard case CodexError.protocolError = error else { return try fail("Expected resumed-provider rejection") } }
        let audit = try await threadClient.request(method: "test/apiAudit")
        try require(!(audit["methods"].array ?? []).contains(.string("turn/start")))
        await threadClient.disconnect()
    }

    private static func notificationsUntil(_ target: String, from client: CodexClient) async throws -> [(String, JSONValue)] {
        try await withThrowingTaskGroup(of: [(String, JSONValue)].self) { group in
            group.addTask {
                var values: [(String, JSONValue)] = []
                for await event in client.events {
                    if case .notification(let method, let params) = event {
                        values.append((method, params))
                        if method == target { return values }
                    }
                }
                return values
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CodexError.timeout("fixture events")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private static func notification(_ target: String, from client: CodexClient) async throws -> JSONValue? {
        try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                for await event in client.events {
                    if case .notification(let method, let params) = event, method == target { return params }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CodexError.timeout("fixture event \(target)")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    public static func run() async throws {
        try await testConnectPaginatesModelsAndDisablesEachMCPWithoutChangingConfig()
        try await testSplitUnicodeResponsesDuplicateRepliesAndDeclinedServerRequest()
        try await testTimeoutDoesNotBreakFutureRequestsAndReconnectIgnoresOldProcess()
        try await testTurnOptionsAreSafeAndCompletedNotificationBeforeResponseDoesNotLockThread()
        try await testCrashFailsPendingAndCanReconnect()
        try await testErrorCancellationAndMalformedInput()
        try await testModernProfileRetainsDynamicEffortsAndLegacyHistory()
        try await testUnverifiedVersionFailsBeforeAuthenticationOrThreads()
        try await testConcurrentThreadsAndInterruption()
        try await testPermanentDeletionTargetsOneThreadAndBlocksConcurrentReuse()
        try await testPermanentDeletionRetriesOnlyConfirmedMissingHistories()
        try await testPermanentDeletionRejectsLegacyAndBusyThreads()
        try await testLiveWebSearchOnFreshAndResumedThreadsKeepsLocalToolsDisabled()
        try await testScopedAttachmentReaderCreationSwitchingAndRestore()
        try await testAttachmentReaderFailureAndLegacyVersionsDoNotSend()
        try await testIndependentAPIKeyAuthenticationAndReconnect()
        try await testAPIKeyBootstrapNotificationsAndRedaction()
        try await testAPIKeyConfigurationFailuresDoNotReceiveCredential()
    }

    private struct CheckFailure: Error, CustomStringConvertible { let description: String }
    private static func require(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) throws {
        if !condition { throw CheckFailure(description: "Protocol check failed at \(file):\(line)") }
    }
    private static func equal<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #fileID, line: UInt = #line) throws {
        if lhs != rhs { throw CheckFailure(description: "Protocol check mismatch at \(file):\(line): \(lhs) != \(rhs)") }
    }
    private static func fail(_ message: String) throws { throw CheckFailure(description: message) }

    private static let server = #"""
#!/usr/bin/python3
import json, os, sys
version = '0.134.0'
scenario = 'fixture-scenario'
disabled = 'mcp_servers.test_server.enabled=false' in sys.argv
api_mode = 'cli_auth_credentials_store="ephemeral"' in sys.argv
accepted_key = None
verified = False
audit_path = os.path.join(os.path.dirname(__file__), 'fixture-audit.jsonl')
last_turn = {}
last_thread = {}
last_resume = {}
thread_count = 0
pending_live_turns = []
deletion_ids = []
pending_deletion = None
unsubscribed = []
thread_configs = {}
def send(message, split=False):
    encoded = (json.dumps(message, ensure_ascii=False) + '\n').encode('utf-8')
    if split:
        for b in encoded:
            os.write(1, bytes([b]))
    else:
        os.write(1, encoded)
def model(name, default=False):
    return {'id':'catalog-'+name,'model':name,'displayName':name,'defaultReasoningEffort':'medium',
        'supportedReasoningEfforts':[{'reasoningEffort':s,'description':s} for s in ['medium','high','max','ultra']],
        'inputModalities':['text','image'],'isDefault':default,'hidden':False}
for line in sys.stdin:
    msg=json.loads(line)
    if msg.get('id') == 'server-request' and 'result' in msg:
        send({'method':'test/declined','params':msg['result']})
        continue
    method=msg.get('method'); params=msg.get('params',{}); result={}
    with open(audit_path, 'a') as audit:
        audit.write(json.dumps({'method':method,'pid':os.getpid()})+'\n')
    if method == 'initialized': continue
    if method == 'initialize': result={'userAgent':'codex/0.134.0 (test)'}
    elif method == 'config/read':
        config={'mcp_servers':{'test_server':{'enabled':not disabled}}}
        if api_mode:
            config.update({'cli_auth_credentials_store':'ephemeral','model_provider':'openai','openai_base_url':'https://api.openai.com/v1'})
            if scenario == 'bad-store': config['cli_auth_credentials_store']='file'
            if scenario == 'bad-provider': config['model_provider']='third-party'
            if scenario == 'bad-endpoint': config['openai_base_url']='https://invalid.example/v1'
            if scenario == 'bad-credentials': config['model_providers']={'openai':{'env_key':'THIRD_PARTY_API_KEY'}}
            if scenario == 'bad-headers': config['model_providers']={'openai':{'http_headers':{'Authorization':'fixture'}}}
            if scenario == 'forced-chatgpt': config['forced_login_method']='chatgpt'
        result={'config':config}
    elif method == 'configRequirements/read':
        verified=True
        requirements={}
        if version.startswith('0.163.'): requirements['allowedLoginMethods']=['api','chatgpt']
        if scenario == 'managed-login-methods': requirements['allowedLoginMethods']=['chatgpt']
        if scenario == 'managed-no-login-methods': requirements['allowedLoginMethods']=[]
        if scenario == 'managed-store': requirements['cliAuthCredentialsStore']='file'
        if scenario == 'managed-chatgpt': requirements['forcedLoginMethod']='chatgpt'
        if scenario == 'managed-provider': requirements['modelProvider']='other'
        if scenario == 'managed-endpoint': requirements['openaiBaseUrl']='https://invalid.example/v1'
        result={'requirements':requirements}
    elif method == 'account/read': result={'account':({'type':'apiKey'} if accepted_key else None) if api_mode else {'type':'chatgpt'}}
    elif method == 'account/login/start':
        assert api_mode and verified and disabled and params['type']=='apiKey'
        accepted_key=params['apiKey']
        if scenario == 'login-error':
            send({'id':msg['id'],'error':{'code':403,'message':'Rejected '+accepted_key}})
            continue
        send({'method':'account/login/completed','params':{'success':True,'loginId':None}})
        send({'method':'account/updated','params':{'authMode':'apikey'}})
        send({'id':msg['id'],'result':{'type':'apiKey'}})
        send({'method':'account/login/completed','params':{'success':True,'loginId':None}})
        send({'method':'account/updated','params':{'authMode':'apikey'}})
        continue
    elif method == 'model/list':
        result={'data':[model('model-b')]} if params.get('cursor') else {'data':[model('model-a',True)],'nextCursor':'page-two'}
    elif method == 'test/args': result=sys.argv
    elif method == 'test/environment': result={'PATH':os.environ.get('PATH',''), 'CODEX_HOME':os.environ.get('CODEX_HOME'),
        'KEEP_FIXTURE':os.environ.get('KEEP_FIXTURE'),
        'credentialVariableNames':[k for k in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CHATGPT_BASE_URL'] if k in os.environ] if api_mode else [],
        'credentialInEnvironment':accepted_key in os.environ.values() if accepted_key else False}
    elif method == 'test/apiAudit':
        rows=[json.loads(line) for line in open(audit_path)]
        result={'loginCount':sum(r['method']=='account/login/start' for r in rows), 'methods':[r['method'] for r in rows],
            'verifiedBeforeLogin':verified,'mcpDisabledBeforeLogin':disabled,'keyWasInArguments':any(accepted_key in arg for arg in sys.argv)}
    elif method == 'test/authNotifications':
        send({'method':'account/login/completed','params':{'success':True,'loginId':None}})
        send({'method':'account/updated','params':{'authMode':'apikey'}})
        send({'method':'test/authFence','params':{'message':'Key '+accepted_key+'; masked sk-proj-abcd***'}})
    elif method == 'test/keyError':
        send({'id':msg['id'],'error':{'code':401,'message':'Incorrect API key: '+accepted_key+' (sk-proj-abcd***)'}})
        continue
    elif method == 'test/keyResponse': result={'key':accepted_key}
    elif method == 'test/lastThread': result=last_thread
    elif method == 'test/lastResume': result=last_resume
    elif method == 'test/fileState': result={'unsubscribed':unsubscribed}
    elif method == 'test/deleteState': result={'ids':deletion_ids,'count':len(deletion_ids),'pending':pending_deletion is not None}
    elif method == 'test/releaseDelete':
        if pending_deletion is not None:
            send({'method':'thread/deleted','params':{'threadId':pending_deletion[1]}})
            send({'id':pending_deletion[0],'result':{}})
            pending_deletion=None
    elif method == 'test/webSearch':
        send({'method':'item/completed','params':{'threadId':'thread-test','turnId':'turn-test','item':{'id':'search-test','type':'webSearch','query':'fixture search'}}})
    elif method == 'test/stall': continue
    elif method == 'test/crash': sys.exit(17)
    elif method == 'test/error':
        send({'id':msg['id'],'error':{'code':42,'message':'Fixture rejection'}})
        continue
    elif method == 'test/malformed':
        os.write(1,b'{broken-json\n')
        continue
    elif method == 'test/split':
        send({'id':msg['id'],'result':{'text':'你好 🌎'}},True)
        send({'id':msg['id'],'result':{'text':'duplicate'}},True)
        continue
    elif method == 'test/approval':
        send({'id':'server-request','method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test'}})
    elif method == 'thread/start':
        last_thread=params
        assert params['environments'] == [] and params['sandbox'] == 'read-only'
        if version.startswith(('0.151.', '0.163.')):
            assert params.get('historyMode') == 'legacy'
        else:
            assert 'historyMode' not in params
        thread_count += 1
        result={'thread':{'id':'thread-test' if thread_count == 1 else 'thread-test-'+str(thread_count)}, 'modelProvider':params.get('modelProvider','openai')}
        thread_configs[result['thread']['id']]=params.get('config',{})
    elif method == 'thread/resume':
        last_resume=params
        thread_configs[params['threadId']]=params.get('config',{})
        result={'thread':{'id':params['threadId']},'modelProvider':'other' if scenario=='bad-thread-provider' else params.get('modelProvider','openai')}
    elif method == 'thread/unsubscribe':
        unsubscribed.append(params['threadId'])
        result={'status':'unsubscribed'}
    elif method == 'mcpServerStatus/list':
        name=params['serverName']; config=thread_configs.get(params['threadId'],{})
        assert config['mcp_servers.'+name]['enabled_tools']==['read_attachment']
        result={'data':[{'name':name,'runtimeStatus':'failed' if scenario=='file-reader-unavailable' else 'connected',
            'tools':{'read_attachment':{'name':'read_attachment'}},'toolsError':None}],'nextCursor':None}
    elif method == 'thread/delete':
        assert set(params) == {'threadId'}
        deletion_ids.append(params['threadId'])
        if scenario == 'delete-hold':
            pending_deletion=(msg['id'],params['threadId'])
            continue
        if scenario in ('delete-missing','delete-other-missing','delete-failure','delete-unsupported'):
            error={'code':-32600,'message':'no rollout found for thread id '+params['threadId']}
            if scenario == 'delete-other-missing': error['message']='no rollout found for thread id another-thread'
            if scenario == 'delete-failure': error['message']='Permission denied while deleting history'
            if scenario == 'delete-unsupported': error={'code':-32601,'message':'Method not found'}
            send({'id':msg['id'],'error':error})
            continue
        if scenario == 'delete-malformed': result=None
        else: send({'method':'thread/deleted','params':{'threadId':params['threadId']}})
    elif method == 'turn/start':
        last_turn=params
        if params['input'][0].get('text') == 'keep-running':
            turn={'id':'turn-running-'+params['threadId'],'status':'inProgress'}
            pending_live_turns.append((msg['id'],params['threadId'],turn))
            if len(pending_live_turns) == 2:
                for request_id,thread_id,active_turn in reversed(pending_live_turns):
                    send({'method':'turn/started','params':{'threadId':thread_id,'turn':active_turn}})
                for request_id,thread_id,active_turn in reversed(pending_live_turns):
                    send({'id':request_id,'result':{'turn':active_turn}})
                pending_live_turns=[]
            continue
        send({'method':'turn/started','params':{'threadId':params['threadId'],'turn':{'id':'turn-test'}}})
        send({'method':'turn/completed','params':{'threadId':params['threadId'],'turn':{'id':'turn-test','status':'completed'}}})
        result={'turn':{'id':'turn-test','status':'inProgress'}}
    elif method == 'turn/interrupt':
        send({'method':'turn/completed','params':{'threadId':params['threadId'],'turn':{'id':params['turnId'],'status':'interrupted'}}})
    elif method == 'test/lastTurn': result=last_turn
    if 'id' in msg: send({'id':msg['id'],'result':result})
"""#
}
