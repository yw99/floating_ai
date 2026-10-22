import AppKit
import FloatingAICore
import SwiftUI
import WebKit

// Actual NoteView integration with temporary storage and synthetic text only.
private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

private final class EmptyKeyStore: APIKeyStore, @unchecked Sendable {
    func read() throws -> String? { throw CheckFailure(message: "Unexpected credential read") }
    func save(_ key: String) throws { throw CheckFailure(message: "Unexpected credential save") }
    func delete() throws { throw CheckFailure(message: "Unexpected credential deletion") }
}

@MainActor private final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-math-transcript-\(UUID())", isDirectory: true)
    let store: AppStore
    let note = NoteState(title: "Synthetic math transcript")
    let window: NSWindow

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore(), previewAuthentication: (.codexSignIn, false))
        note.isExpanded = true
        note.expandedWidth = 520
        note.expandedHeight = 640
        note.messages = (0..<10).map { ChatMessage(id: "history-\($0)", role: "assistant", text: "Earlier paragraph \($0). This is synthetic conversation history used to check the reading position.") }
        note.messages.append(ChatMessage(id: "latest", role: "assistant", text: "Initial equation: $x+1$."))
        note.isBusy = true
        store.notes = [note]
        let actions = NoteWindowActions(expand: {}, collapse: {}, hide: {}, interaction: { _, _ in }, dragHover: { _ in })
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 520, height: 640),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Floating AI — transcript checks"
        window.contentView = NSHostingView(rootView: NoteView(note: note, store: store, actions: actions))
        window.orderFront(nil)
    }

    func close() async {
        window.close()
        await store.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func descendants<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        guard let view = view ?? window.contentView else { return [] }
        return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    func transcript() throws -> NSScrollView {
        guard let web = descendants(MathWebView.self).first else { throw CheckFailure(message: "No production math web view was mounted") }
        var ancestor = web.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { return scroll }
            ancestor = view.superview
        }
        throw CheckFailure(message: "Math message has no outer transcript scroll view")
    }

    func settle(_ seconds: Double = 0.35) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func waitForMath(containing expected: String) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            for web in descendants(MathWebView.self) {
                if let text = try? await web.evaluateJavaScript("document.querySelector('#content')?.textContent || ''") as? String,
                   text.contains(expected),
                   (try? await web.evaluateJavaScript("document.querySelectorAll('#content .katex').length") as? Int) ?? 0 > 0 {
                    try await settle()
                    return
                }
            }
            try await settle(0.05)
        }
        throw CheckFailure(message: "Math transcript did not render expected synthetic revision: \(expected)")
    }

    func bottomDistance(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        return document.isFlipped ? document.bounds.maxY - document.visibleRect.maxY : document.visibleRect.minY - document.bounds.minY
    }

    func scrollToBottom(_ scroll: NSScrollView) async throws {
        guard let document = scroll.documentView else { throw CheckFailure(message: "Missing transcript document") }
        let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
    }

    func updateLatest(_ text: String) {
        note.messages[note.messages.count - 1].text = text
    }
}

@main private struct MathTranscriptChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
            fputs("FAIL: Math transcript checks exceeded their deadline\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            do {
                try require(!NSScreen.screens.isEmpty, "Transcript checks require macOS window-server access")
                let fixture = try Fixture()
                do {
                    try await run(fixture)
                    await fixture.close()
                } catch {
                    await fixture.close()
                    throw error
                }
                print("PASS: 3 actual NoteView math transcript checks")
                exit(0)
            } catch {
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor private static func run(_ fixture: Fixture) async throws {
        try await fixture.waitForMath(containing: "Initial equation")
        let scroll = try fixture.transcript()
        try await fixture.scrollToBottom(scroll)
        try require(fixture.bottomDistance(scroll) < 6, "Could not establish initial latest-message position")

        var growing = "Streaming revision zero: $x+1$."
        for revision in 1...5 {
            growing += "\n\nRevision \(revision): " + Array(repeating: "The synthetic expression $a^2+b^2=c^2$ explains this step.", count: 5).joined(separator: " ")
            fixture.updateLatest(growing)
            try await fixture.waitForMath(containing: "Revision \(revision):")
            let gap = fixture.bottomDistance(scroll)
            // The scroll anchor sits above NoteView's 16-point bottom padding.
            try require(gap < 24, "Async math growth stopped following the latest message at revision \(revision), bottom gap \(gap)")
        }
        print("PASS: streaming math growth follows latest")

        fixture.window.setContentSize(NSSize(width: 360, height: 640))
        try await fixture.settle(0.75)
        try require(fixture.bottomDistance(scroll) < 24,
                    "Narrowing the note lost latest-message position: \(fixture.bottomDistance(scroll))")
        print("PASS: width-driven math reflow follows latest")

        guard let document = scroll.documentView else { throw CheckFailure(message: "Missing transcript document") }
        let topY = document.isFlipped ? CGFloat(80) : max(0, document.bounds.height - scroll.contentView.bounds.height - 80)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await fixture.settle()
        let before = scroll.contentView.bounds.origin.y
        let previousGap = fixture.bottomDistance(scroll)
        try require(fixture.bottomDistance(scroll) > 100, "Could not establish an earlier-history reading position")
        fixture.updateLatest(growing + "\n\nOffscreen update: " + Array(repeating: "$\\frac{x}{y}$ adds another step.", count: 30).joined(separator: " "))
        try await fixture.settle(0.8)
        let after = scroll.contentView.bounds.origin.y
        try require(abs(after - before) < 4, "Updating math moved the earlier-history reading position from \(before) to \(after); bottom gap changed from \(previousGap) to \(fixture.bottomDistance(scroll))")
        print("PASS: earlier-history reading position is preserved")
    }
}
