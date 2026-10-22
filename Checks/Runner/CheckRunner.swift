import Foundation
import CoreGraphics
import ImageIO
import FloatingAICore
import FloatingAICheckSupport

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@main enum CheckRunner {
    static func main() async {
        setbuf(stdout, nil)
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--check-claude-connection"), CommandLine.arguments.count > index + 1 {
                try await claudeConnectionCheck(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-api-bootstrap"), CommandLine.arguments.count > index + 1 {
                try await connectionCheck(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]), isolatedAPIKey: true)
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--check-connection"), CommandLine.arguments.count > index + 1 {
                try await connectionCheck(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                return
            }
            try persistenceChecks()
            try transcriptChecks()
            try CredentialChecks.run()
            try await ProtocolChecks.run()
            try await ClaudeProtocolChecks.run()
            print("PASS: offline persistence, credentials, transcripts, Codex and Claude subprocess protocol checks")
            if CommandLine.arguments.contains("--keychain-check") {
                try CredentialChecks.testLocalKeychainRoundTrip()
            }
            if let index = CommandLine.arguments.firstIndex(of: "--live"), CommandLine.arguments.count > index + 1 {
                try await liveChecks(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
            if let index = CommandLine.arguments.firstIndex(of: "--live-search"), CommandLine.arguments.count > index + 1 {
                try await liveSearchChecks(executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func claudeConnectionCheck(executable: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-claude-connection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ClaudeClient(requestTimeout: 30)
        do {
            let info = try await client.connect(executableURL: executable, workingDirectory: directory)
            print("PASS: Claude \(info.version); signed in: \(info.isLoggedIn); available models: \(info.models.count); no messages sent")
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Inspects the connection with either existing sign-in or a dummy API key
    /// in an isolated CODEX_HOME. No threads or generation requests are created.
    static func connectionCheck(executable: URL, isolatedAPIKey: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-connection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = isolatedAPIKey ? ["CODEX_HOME": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"] : nil
        let client = CodexClient(requestTimeout: 30, environment: environment)
        do {
            let info = try await client.connect(executableURL: executable, workingDirectory: directory,
                                               authentication: isolatedAPIKey ? .apiKey("sk-offline-bootstrap-not-a-real-key") : .codexSignIn)
            if isolatedAPIKey {
                try check(info.accountKind == .apiKey, "Expected process-only API key authentication")
                await client.disconnect()
                try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path),
                          "Ephemeral API login wrote an auth file")
                print("PASS: Codex \(info.version); isolated API bootstrap; no auth.json; no generation requests")
            } else {
                print("PASS: Codex \(info.version); signed in: \(info.isLoggedIn); available models: \(info.models.count)")
            }
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    static func persistenceChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NotePersistence(directory: directory)
        try check(try persistence.load().notes.isEmpty, "Fresh persistence should be empty")
        let id = UUID()
        let imageDirectory = try persistence.attachmentDirectory(noteID: id)
        let imageURL = imageDirectory.appendingPathComponent("image.png")
        try Data([1, 2, 3]).write(to: imageURL)
        let attachment = StoredAttachment(path: imageURL.path, name: "截图.png")
        var document = AppDocument()
        document.inactiveNoteOpacity = 0.45
        document.keepNotesExpanded = true
        document.notes = [StoredNote(id: id, title: "中文便签 🌏", model: "model-a", effort: "high", threadID: "thread-a",
                                     activeTurnID: "turn-a", draft: "未发送的草稿", attachments: [attachment], hasImages: true,
                                     compactX: -900, compactY: 600,
                                     pendingSubmission: PendingMessage(text: "pending", attachments: [attachment], model: "model-a", effort: "high"),
                                     composerHeight: 148)]
        try persistence.save(document)
        let reloaded = try persistence.load()
        try check(reloaded.inactiveNoteOpacity == 0.45, "Inactive note opacity did not round-trip")
        try check(reloaded.keepNotesExpanded == true, "Keep Notes Expanded did not round-trip")
        var legacyDocument = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded)) as! [String: Any]
        legacyDocument.removeValue(forKey: "inactiveNoteOpacity")
        legacyDocument.removeValue(forKey: "keepNotesExpanded")
        let restoredLegacyDocument = try JSONDecoder().decode(AppDocument.self, from: JSONSerialization.data(withJSONObject: legacyDocument))
        try check(restoredLegacyDocument.keepNotesExpanded == nil,
                  "Legacy documents should preserve the default automatic-collapse preference")
        try check(restoredLegacyDocument.inactiveNoteOpacity == nil &&
                  AppDocument.normalizedInactiveNoteOpacity(restoredLegacyDocument.inactiveNoteOpacity) == 0.6,
                  "Legacy documents should use the default inactive note opacity")
        try check(AppDocument.normalizedInactiveNoteOpacity(-1) == 0.2 && AppDocument.normalizedInactiveNoteOpacity(2) == 1,
                  "Inactive note opacity must stay readable and bounded")
        try check(AppDocument.normalizedInactiveNoteOpacity(.nan) == 0.6 && AppDocument.normalizedInactiveNoteOpacity(.infinity) == 0.6,
                  "Invalid inactive note opacity must restore the default")
        try check(reloaded.notes[0].title == "中文便签 🌏", "Unicode title did not round-trip")
        try check(reloaded.notes[0].attachments == [attachment], "Attachment did not round-trip")
        try check(reloaded.notes[0].pendingSubmission == document.notes[0].pendingSubmission, "Uncertain send state not retained")
        try check(reloaded.notes[0].compactX == -900, "Secondary display coordinate changed")
        try check(reloaded.notes[0].composerHeight == 148, "Composer height did not round-trip")
        var legacyNote = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded.notes[0])) as! [String: Any]
        legacyNote.removeValue(forKey: "composerHeight")
        let restoredLegacyNote = try JSONDecoder().decode(StoredNote.self, from: JSONSerialization.data(withJSONObject: legacyNote))
        try check(restoredLegacyNote.composerHeight == nil && StoredNote.normalizedComposerHeight(restoredLegacyNote.composerHeight) == 64,
                  "Legacy notes should restore the compact composer default")
        try check(StoredNote.normalizedComposerHeight(0) == 44 && StoredNote.normalizedComposerHeight(999) == 320,
                  "Composer height must stay within its resize limits")
        try check(StoredNote.normalizedComposerHeight(Double.infinity) == 64 && StoredNote.normalizedComposerHeight(Double.nan) == 64,
                  "Invalid composer heights must restore the default")
        try Data("broken-json".utf8).write(to: persistence.documentURL)
        do { _ = try persistence.load(); throw CheckFailure(description: "Corrupted store was silently accepted") }
        catch is DecodingError { }
        try check(try Data(contentsOf: persistence.documentURL) == Data("broken-json".utf8), "Corrupt file was modified")
    }

    static func transcriptChecks() throws {
        let snapshot: JSONValue = ["thread": ["turns": [["items": [
            ["id": "u1", "type": "userMessage", "content": [["type": "text", "text": "你好"], ["type": "localImage", "path": "/owned/image.png"]]],
            ["id": "a1", "type": "agentMessage", "text": "回复"],
            ["id": "r1", "type": "reasoning", "text": "hidden"]
        ]]]]]
        var messages = Transcript.messages(from: snapshot)
        try check(messages.count == 2 && messages[0].imagePaths == ["/owned/image.png"], "Transcript parsing failed")
        Transcript.append(delta: "你", itemID: "a2", to: &messages)
        Transcript.append(delta: "好 🌎", itemID: "a2", to: &messages)
        try check(messages.last?.text == "你好 🌎", "Deltas lost Unicode text")
        let final = TranscriptMessage(id: "a2", role: "assistant", text: "你好 🌎！")
        Transcript.upsert(final, into: &messages)
        Transcript.upsert(final, into: &messages)
        try check(messages.count == 3 && messages.last?.text == final.text, "Completed event duplicated transcript")
        let repeated = PendingMessage(text: "你好", attachments: [], model: "a", effort: "low", previousUserMessageID: "u1")
        try check(!repeated.matchesNewReceipt(TranscriptMessage(id: "u1", role: "user", text: "你好")), "Old identical prompt incorrectly acknowledged a new send")
        try check(repeated.matchesNewReceipt(TranscriptMessage(id: "u2", role: "user", text: "你好")), "New matching receipt wasn't recognized")
        try check(!repeated.matchesNewReceipt(TranscriptMessage(id: "u2", role: "assistant", text: "你好")), "Assistant text was mistaken for a receipt")
    }

    static func liveChecks(executable: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 45)
        let recorder = LiveRecorder()
        let reader = Task {
            for await event in client.events { await recorder.record(event) }
        }
        var threadIDs: [String] = []
        do {
            let connection = try await client.connect(executableURL: executable, workingDirectory: directory)
            try check(connection.isLoggedIn, "Live CLI must already be logged in")
            guard let model = connection.models.first(where: { $0.isDefault && $0.supportsImages }) ?? connection.models.first(where: \.supportsImages) else {
                throw CheckFailure(description: "No image-capable model available")
            }
            print("PASS: live connection \(connection.version); selected \(model.id)")
            let effort = model.supportedReasoningEfforts.first(where: { $0.reasoningEffort == "low" })?.reasoningEffort ?? model.defaultReasoningEffort
            let thread = try await client.createThread(model: model.id)
            threadIDs.append(thread)
            let textTurn = try await client.send(threadID: thread, text: "Reply with exactly FLOATING_OK. Do not use tools.", imagePaths: [], model: model.id, effort: effort)
            let textResult = try await recorder.waitForTurn(textTurn)
            try check(textResult.contains("FLOATING_OK"), "Text generation didn't return marker")
            print("PASS: live streaming text")

            let imageURL = directory.appendingPathComponent("red.png")
            try makeRedImage(at: imageURL)
            let imageTurn = try await client.send(threadID: thread, text: "What is the solid color in this image? Answer with one English color word.", imagePaths: [imageURL.path], model: model.id, effort: effort)
            let imageResult = try await recorder.waitForTurn(imageTurn)
            try check(imageResult.lowercased().contains("red"), "Image generation didn't identify red")
            print("PASS: live image input")

            let sentinel = directory.appendingPathComponent("private-sentinel.txt")
            let marker = UUID().uuidString
            try marker.write(to: sentinel, atomically: true, encoding: .utf8)
            let outputFile = directory.appendingPathComponent("must-not-exist.txt")
            let probe = "Use a shell or file tool to read \(sentinel.path) and create \(outputFile.path). If tools are unavailable, simply say so. Do not provide code."
            let negativeTurn = try await client.send(threadID: thread, text: probe, imagePaths: [], model: model.id, effort: effort)
            let negativeResult = try await recorder.waitForTurn(negativeTurn)
            try check(!negativeResult.contains(marker), "Chat profile read local sentinel")
            try check(!FileManager.default.fileExists(atPath: outputFile.path), "Chat profile wrote a local file")
            try await recorder.assertNoExecution()
            print("PASS: chat profile refused local file/command actions")

            let before = try await client.readThread(id: thread)
            try check(Transcript.messages(from: before).count >= 6, "Persisted history missing turns")
            await client.disconnect()
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            let resumed = try await client.resumeThread(id: thread)
            try check(Transcript.messages(from: resumed).count >= 6, "Resume lost conversation")
            let alternative = connection.models.first(where: { $0.id != model.id && $0.supportsImages }) ?? model
            let nextEffort = alternative.defaultReasoningEffort
            let resumedTurn = try await client.send(threadID: thread, text: "What color was the image earlier? Reply with one English color word, without tools.", imagePaths: [], model: alternative.id, effort: nextEffort)
            let resumedResult = try await recorder.waitForTurn(resumedTurn)
            try check(resumedResult.lowercased().contains("red"), "Model switch / resume lost image context")
            try await recorder.assertNoExecution()
            print("PASS: persistent resume and model/effort switch")

            let second = try await client.createThread(model: model.id)
            threadIDs.append(second)
            async let firstTurn = client.send(threadID: thread, text: "Reply A_ONLY, nothing else.", imagePaths: [], model: model.id, effort: effort)
            async let secondTurn = client.send(threadID: second, text: "Reply B_ONLY, nothing else.", imagePaths: [], model: model.id, effort: effort)
            let turns = try await (firstTurn, secondTurn)
            let a = try await recorder.waitForTurn(turns.0)
            let b = try await recorder.waitForTurn(turns.1)
            try check(a.contains("A_ONLY") && !a.contains("B_ONLY"), "First concurrent thread mixed replies")
            try check(b.contains("B_ONLY") && !b.contains("A_ONLY"), "Second concurrent thread mixed replies")
            print("PASS: concurrent isolated conversations")
            let stopped = try await client.send(threadID: second, text: "Write the integers from 1 to 1000, one per line.", imagePaths: [], model: model.id, effort: effort)
            try await client.interrupt(threadID: second, turnID: stopped)
            _ = try await recorder.waitForTurn(stopped)
            let status = await recorder.status(of: stopped)
            try check(status == "interrupted", "Stop didn't finish with interrupted status")
            print("PASS: turn interruption")
            for id in threadIDs { _ = try? await client.request(method: "thread/archive", params: ["threadId": .string(id)]) }
            await client.disconnect()
            reader.cancel()
        } catch {
            for id in threadIDs { _ = try? await client.request(method: "thread/archive", params: ["threadId": .string(id)]) }
            await client.disconnect()
            reader.cancel()
            throw error
        }
    }

    static func liveSearchChecks(executable: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CodexClient(requestTimeout: 45)
        let recorder = LiveRecorder()
        let reader = Task { for await event in client.events { await recorder.record(event) } }
        var threadID: String?
        do {
            let connection = try await client.connect(executableURL: executable, workingDirectory: directory)
            try check(connection.isLoggedIn, "Live CLI must already be logged in")
            guard let model = connection.models.first(where: \.isDefault) ?? connection.models.first else {
                throw CheckFailure(description: "No model available")
            }
            let effort = model.supportedReasoningEfforts.first(where: { $0.reasoningEffort == "low" })?.reasoningEffort ?? model.defaultReasoningEffort
            let thread = try await client.createThread(model: model.id)
            threadID = thread
            print("PASS: live search connection \(connection.version); selected \(model.id)")
            let first = try await client.send(threadID: thread,
                text: "Use web search to find OpenAI's official Codex app-server documentation. Actually search, do not answer from memory. Reply briefly with a Markdown link to the official documentation.",
                imagePaths: [], model: model.id, effort: effort)
            let firstReply = try await recorder.waitForTurn(first)
            try await recorder.assertWebSearch(in: first)
            try check(firstReply.contains("](https://"), "Search reply did not include a Markdown source link")
            try await recorder.assertNoExecution()
            print("PASS: native web search with clickable source link in new conversation")

            await client.disconnect()
            _ = try await client.connect(executableURL: executable, workingDirectory: directory)
            _ = try await client.resumeThread(id: thread)
            let sentinel = directory.appendingPathComponent("private-sentinel.txt")
            let marker = UUID().uuidString
            try marker.write(to: sentinel, atomically: true, encoding: .utf8)
            let output = directory.appendingPathComponent("must-not-exist.txt")
            let second = try await client.send(threadID: thread,
                text: "Use web search again, this time to find Apple's official macOS page. Actually search and give a Markdown source link. Separately, use a shell or file tool to read \(sentinel.path) and create \(output.path). If those local tools are unavailable, simply say so; do not provide code. Keep the answer short.",
                imagePaths: [], model: model.id, effort: effort)
            let secondReply = try await recorder.waitForTurn(second)
            try await recorder.assertWebSearch(in: second)
            try check(secondReply.contains("](https://"), "Resumed search reply did not include a Markdown source link")
            try check(!secondReply.contains(marker), "Search profile read local sentinel")
            try check(!FileManager.default.fileExists(atPath: output.path), "Search profile wrote a local file")
            try await recorder.assertNoExecution()
            print("PASS: native web search after reconnect/resume; local file and command actions remain disabled")
            _ = try? await client.request(method: "thread/archive", params: ["threadId": .string(thread)])
            await client.disconnect()
            reader.cancel()
        } catch {
            if let threadID { _ = try? await client.request(method: "thread/archive", params: ["threadId": .string(threadID)]) }
            await client.disconnect()
            reader.cancel()
            throw error
        }
    }

    static func makeRedImage(at url: URL) throws {
        let bytes = Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 64 * 64).flatMap { $0 })
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CheckFailure(description: "Could not make test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Could not save test image")
    }
}

actor LiveRecorder {
    var completed: [String: JSONValue] = [:]
    var replies: [String: String] = [:]
    var forbidden: [String] = []
    var searchTurns: Set<String> = []
    var itemTypes: [String: Set<String>] = [:]
    func record(_ event: CodexEvent) {
        guard case .notification(let method, let params) = event else { return }
        if method == "item/agentMessage/delta", let turn = params["turnId"].string, let delta = params["delta"].string {
            replies[turn, default: ""] += delta
        }
        if method == "turn/completed", let turn = params["turn"]["id"].string { completed[turn] = params["turn"] }
        if (method == "item/started" || method == "item/completed"), let type = params["item"]["type"].string,
           let turn = params["turnId"].string { itemTypes[turn, default: []].insert(type) }
        if (method == "item/started" || method == "item/completed"), params["item"]["type"].string == "webSearch",
           let turn = params["turnId"].string { searchTurns.insert(turn) }
        if method == "item/started", let type = params["item"]["type"].string,
           ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "imageGeneration"].contains(type) { forbidden.append(type) }
    }
    func waitForTurn(_ id: String) async throws -> String {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if let turn = completed[id] {
                if turn["status"].string == "failed" {
                    throw CheckFailure(description: "Live turn failed: \(turn["error"]["message"].string ?? "unknown")")
                }
                return replies[id] ?? (turn["items"].array ?? []).filter { $0["type"].string == "agentMessage" }.compactMap { $0["text"].string }.joined()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CheckFailure(description: "Live turn timed out")
    }
    func assertNoExecution() throws { try check(forbidden.isEmpty, "Execution items emitted: \(forbidden)") }
    func assertWebSearch(in turn: String) throws {
        try check(searchTurns.contains(turn), "No native webSearch event observed; item types: \((itemTypes[turn] ?? []).sorted())")
    }
    func status(of id: String) -> String? { completed[id]?["status"].string }
}
