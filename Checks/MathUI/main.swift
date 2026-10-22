import AppKit
import SwiftUI
import WebKit

// Exercises the production renderer in a real, offline WKWebView. Every
// message is synthetic; no account, CLI, note store, or general clipboard is used.
private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

@MainActor private final class CheckWindow: NSWindow {
    private(set) var cancellationCount = 0
    override func cancelOperation(_ sender: Any?) { cancellationCount += 1 }
}

@MainActor private final class CheckScrollView: NSScrollView {
    private(set) var forwardedWheels = 0
    override func scrollWheel(with event: NSEvent) { forwardedWheels += 1 }
}

private final class CheckWheelEvent: NSEvent {
    private let target: NSWindow
    private let point: NSPoint
    private let delta: NSPoint
    init(window: NSWindow, point: NSPoint, delta: NSPoint) {
        target = window; self.point = point; self.delta = delta
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Synthetic wheel events are not decoded") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var scrollingDeltaX: CGFloat { delta.x }
    override var scrollingDeltaY: CGFloat { delta.y }
}

@MainActor private final class Fixture {
    let renderer: MathMessageRenderer
    let window: CheckWindow
    private(set) var heights: [CGFloat] = []
    private(set) var failed = false

    init(resourceDirectory: URL) {
        renderer = MathMessageRenderer(resourceDirectory: resourceDirectory)
        window = CheckWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Floating AI — offline math checks"
        window.contentView = renderer.webView
        renderer.onHeight = { [weak self] in self?.heights.append($0) }
        renderer.onFailure = { [weak self] in self?.failed = true }
        window.orderFront(nil)
    }

    func close() { renderer.stop(); window.close() }

    func evaluate(_ script: String) async throws -> Any? {
        try await renderer.webView.evaluateJavaScript(script)
    }

    func bool(_ script: String) async throws -> Bool {
        (try await evaluate(script) as? NSNumber)?.boolValue == true
    }

    func number(_ script: String) async throws -> Double {
        guard let result = try await evaluate(script) as? NSNumber else {
            throw CheckFailure(message: "JavaScript did not return a number: \(script)")
        }
        return result.doubleValue
    }

    func string(_ script: String) async throws -> String {
        guard let result = try await evaluate(script) as? String else {
            throw CheckFailure(message: "JavaScript did not return text: \(script)")
        }
        return result
    }

    func wait(for script: String, message: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await bool(script)) == true { return }
            if failed { throw CheckFailure(message: "Native math renderer reported a load/render failure: \(message)") }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw CheckFailure(message: message)
    }

    func ready() async throws {
        try await wait(for: "typeof window.renderMessage === 'function' && !!document.querySelector('#content')",
                       message: "Bundled math resources did not load", timeout: 30)
    }

    func render(_ text: String, dark: Bool = false) async throws {
        renderer.render(text: text, darkMode: dark)
        try await waitForCurrentRevision()
    }

    func waitForCurrentRevision() async throws {
        let revision = renderer.revision
        try await wait(for: "document.querySelector('#content')?.dataset.revision === '\(revision)'",
                       message: "Renderer did not finish revision \(revision)")
        // ResizeObserver/font loading can schedule an additional animation frame.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func resize(width: CGFloat) async throws {
        window.setContentSize(NSSize(width: width, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 180_000_000)
    }
}

@main private struct MathUIChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in await runChecks(); exit(0) }
        NSApplication.shared.run()
    }

    @MainActor private static func runChecks() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
            fputs("FAIL: Native math checks exceeded their deadline\n", stderr)
            exit(1)
        }
        do {
            try require(!NSScreen.screens.isEmpty, "Native math checks require macOS window-server access")
            var resourceDirectory: URL?
            let arguments = Array(CommandLine.arguments.dropFirst())
            var index = 0
            while index < arguments.count {
                guard arguments[index] == "--resource-dir", index + 1 < arguments.count else {
                    throw CheckFailure(message: "Usage: MathUIChecks --resource-dir PATH")
                }
                resourceDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                index += 2
            }
            guard let resourceDirectory else { throw CheckFailure(message: "Missing math resource directory") }
            let fixture = Fixture(resourceDirectory: resourceDirectory)
            defer { fixture.close() }
            try await fixture.ready()
            try await formatsAndMarkdown(fixture)
            try await codeCurrencyAndEscapes(fixture)
            try await streamingAndLatestRevision(fixture)
            try await malformedFormulaFallback(fixture)
            try await untrustedContent(fixture)
            try await contentSecurityPolicy(fixture)
            try await copyOriginalSources(fixture)
            try await responsiveLayout(fixture)
            try await appearanceAndLocalResources(fixture)
            try await keyboardAndLinks(fixture)
            try await saveSnapshots(fixture)
            try await wheelRoutingAndClipping(fixture)
            print("PASS: 11 native math rendering checks (\(resourceDirectory.path))")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func formatsAndMarkdown(_ fixture: Fixture) async throws {
        try await fixture.render(#"""
        **Energy:** $E=mc^2$ and \(x^2+y^2=z^2\).

        $$\frac{a}{b}$$

        \[\int_0^1 x^2\,dx=\frac{1}{3}\]

        - First item
        - Second item
        """#)
        let count = try await fixture.number("document.querySelectorAll('#content .katex').length")
        let displays = try await fixture.number("document.querySelectorAll('#content .katex-display').length")
        if count != 4 || displays != 2 {
            let html = try await fixture.string("document.querySelector('#content').innerHTML")
            throw CheckFailure(message: "All four supported math delimiter forms were not rendered: inline+block=\(count), display=\(displays); \(html.prefix(2000))")
        }
        let markdown = try await fixture.bool("!!document.querySelector('#content strong') && document.querySelectorAll('#content li').length === 2")
        try require(markdown, "Math rendering lost surrounding Markdown formatting")
        try require(!fixture.heights.isEmpty && fixture.heights.allSatisfy { $0.isFinite && $0 > 0 },
                    "The native layout bridge did not report finite positive heights")
    }

    @MainActor private static func codeCurrencyAndEscapes(_ fixture: Fixture) async throws {
        try await fixture.render(#"""
        `$x+y$` and `\(q+r\)` remain code.

        ```tex
        $$\frac{x}{y}$$
        <script>neverRun()</script>
        ```

        Tickets cost $5 and $10. The budget is $20. Escaped \$x+y\$ stays literal. Real $a+b$.
        """#)
        let count = try await fixture.number("document.querySelectorAll('#content .katex').length")
        let code = try await fixture.bool("document.querySelectorAll('#content code').length === 3 && document.querySelector('#content pre code').textContent.includes('$$\\\\frac{x}{y}$$')")
        let text = try await fixture.string("document.querySelector('#content').textContent")
        try require(count == 1 && code, "Code, currency, or escaped dollars were interpreted as math")
        try require(text.contains("$5 and $10") && text.contains("$20") && text.contains("$x+y$"),
                    "Currency or literal dollars disappeared from the message")
    }

    @MainActor private static func streamingAndLatestRevision(_ fixture: Fixture) async throws {
        let incomplete = #"Calculating: $$\frac{a}{b}"#
        try await fixture.render(incomplete)
        let text = try await fixture.string("document.querySelector('#content').textContent")
        try require(text.contains(#"\frac{a}{b}"#), "An incomplete streamed formula was hidden")
        try await fixture.render(incomplete + "$$")
        let completed = try await fixture.number("document.querySelectorAll('#content .katex-display').length")
        try require(completed == 1, "Completing a streamed formula did not render it")
        for index in 0..<12 { fixture.renderer.render(text: "Revision \(index): $x_{\(index)}$", darkMode: false) }
        try await fixture.waitForCurrentRevision()
        let final = try await fixture.string("document.querySelector('#content').textContent")
        try require(final.contains("Revision 11:") && !final.contains("Revision 10:"),
                    "A stale streaming update replaced the latest message")
    }

    @MainActor private static func malformedFormulaFallback(_ fixture: Fixture) async throws {
        try await fixture.render(#"Broken $\notARealTeXCommand{x}$, recursive $\def\a{\a}\a$, then valid $x+1$."#)
        let count = try await fixture.number("document.querySelectorAll('#content .katex').length")
        let text = try await fixture.string("document.querySelector('#content').textContent")
        try require(count == 1 && text.contains(#"\notARealTeXCommand{x}"#) && text.contains(#"\def\a{\a}\a"#),
                    "Invalid or excessively expanding math did not preserve readable source")
    }

    @MainActor private static func untrustedContent(_ fixture: Fixture) async throws {
        try await fixture.render(#"""
        <script>window.syntheticAttack=true</script>
        <img src="https://example.invalid/pixel" onerror="window.syntheticAttack=true">
        [unsafe](javascript:alert(1)) [file](file:///etc/passwd)
        ![private image](https://example.invalid/image)
        $\href{javascript:alert(1)}{click}$
        $\includegraphics{https://example.invalid/math-image}$
        $\htmlClass{unsafe}{x}$
        """#)
        let safe = try await fixture.bool("!window.syntheticAttack && !document.querySelector('#content script, #content img, #content iframe, #content object, #content embed, #content .unsafe') && Array.from(document.querySelectorAll('#content a')).every(a => /^https?:$/.test(a.protocol))")
        let text = try await fixture.string("document.querySelector('#content').textContent")
        try require(safe && text.contains("<script>") && text.contains("private image"),
                    "Untrusted message HTML, links, images, or KaTeX extensions became active content")
    }

    @MainActor private static func contentSecurityPolicy(_ fixture: Fixture) async throws {
        _ = try await fixture.evaluate("window.syntheticViolations=[]; document.addEventListener('securitypolicyviolation', e => window.syntheticViolations.push(e.effectiveDirective)); window.syntheticFetch='pending'; fetch('https://example.invalid/never-send').then(() => window.syntheticFetch='allowed', () => window.syntheticFetch='blocked'); true")
        try await fixture.wait(for: "window.syntheticFetch === 'blocked' && window.syntheticViolations.includes('connect-src')",
                               message: "The bundled document did not block outbound fetch through CSP")
        _ = try await fixture.evaluate("const attack=document.createElement('script'); attack.textContent='window.syntheticInlineScriptRan=true'; document.body.appendChild(attack); true")
        try await fixture.wait(for: "window.syntheticViolations.some(v => v.startsWith('script-src'))",
                               message: "Inline script injection was not rejected by CSP")
        let blocked = try await fixture.bool("!window.syntheticInlineScriptRan")
        try require(blocked, "An injected inline script executed")
        let originalURL = fixture.renderer.webView.url
        fixture.renderer.webView.load(URLRequest(url: URL(string: "https://example.invalid/blocked-navigation")!))
        try await Task.sleep(nanoseconds: 180_000_000)
        try require(fixture.renderer.webView.url == originalURL,
                    "The native navigation delegate allowed the message web view to leave bundled resources")
    }

    @MainActor private static func copyOriginalSources(_ fixture: Fixture) async throws {
        let source = #"""
        Equation:

        $$\frac{a}{b}$$

        ```swift
        let expression = "$x$"
        ```
        """#
        try await fixture.render(source)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        fixture.renderer.copySource(to: board)
        try require(board.string(forType: .string) == source, "Native Copy changed the original Markdown/LaTeX source")
        // Intercept the DOM copy command before clicking controls. This observes
        // the actual production selection without touching the user's clipboard.
        _ = try await fixture.evaluate("window.syntheticCopies=[]; window.syntheticOriginalExec=document.execCommand; document.execCommand=function(command){ if(command === 'copy'){ window.syntheticCopies.push(document.activeElement.value ?? window.getSelection().toString()); return true; } return false; }; document.querySelector('#content .copy-code').click(); document.querySelector('#content .copy-math').click(); true")
        let copies = try await fixture.bool("window.syntheticCopies.length === 2 && window.syntheticCopies[0].includes('let expression = \"$x$\"') && window.syntheticCopies[1] === '$$\\\\frac{a}{b}$$'")
        _ = try await fixture.evaluate("document.execCommand=window.syntheticOriginalExec; true")
        try require(copies, "Code/formula copy controls did not copy original source")
        let selectionScript = #"""
        (() => {
          const range=document.createRange();
          range.selectNodeContents(document.querySelector('#content .math-display'));
          const selection=window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          let copied='';
          const event=new Event('copy', {bubbles:true,cancelable:true});
          Object.defineProperty(event,'clipboardData',{value:{setData(type,text){if(type==='text/plain')copied=text;}}});
          document.querySelector('#content .math-display').dispatchEvent(event);
          selection.removeAllRanges();
          return copied;
        })()
        """#
        let selected = try await fixture.string(selectionScript)
        try require(selected == #"$$\frac{a}{b}$$"#, "Selecting and copying a formula lost its original LaTeX")
    }

    @MainActor private static func responsiveLayout(_ fixture: Fixture) async throws {
        let paragraph = Array(repeating: "A paragraph should wrap naturally around $x+y$ without clipping.", count: 18).joined(separator: " ")
        try await fixture.resize(width: 640)
        try await fixture.render(paragraph)
        let wide = try await fixture.number("document.querySelector('#content').getBoundingClientRect().height")
        try await fixture.resize(width: 280)
        let narrow = try await fixture.number("document.querySelector('#content').getBoundingClientRect().height")
        try require(narrow > wide, "Resizing a note did not reflow the rendered message")
        try require(fixture.heights.count >= 2 && fixture.heights.last! >= CGFloat(narrow) - 2,
                    "The native height did not follow the resized message")
        let terms = (0..<50).map { "x_{\($0)}" }.joined(separator: "+")
        try await fixture.render("$$" + terms + "$$")
        let contained = try await fixture.bool("document.documentElement.scrollWidth <= window.innerWidth + 2 && Array.from(document.querySelectorAll('#content .math-scroll, #content .math-display, #content .katex-display')).some(e => e.scrollWidth > e.clientWidth + 2 && ['auto','scroll'].includes(getComputedStyle(e).overflowX))")
        try require(contained, "A wide display equation overflowed the note instead of scrolling horizontally")
    }

    @MainActor private static func appearanceAndLocalResources(_ fixture: Fixture) async throws {
        try await fixture.render("Theme $x^2$", dark: false)
        let light = try await fixture.string("getComputedStyle(document.querySelector('#content')).color")
        try await fixture.render("Theme $x^2$", dark: true)
        let dark = try await fixture.string("getComputedStyle(document.querySelector('#content')).color")
        let theme = try await fixture.string("document.body.dataset.theme")
        try require(light != dark && theme == "dark", "Dark appearance did not update message and formula colors")
        let local = try await fixture.bool("location.protocol === 'floating-math:' && Array.from(document.querySelectorAll('script[src], link[href]')).every(e => new URL(e.src || e.href).protocol === 'floating-math:')")
        try require(local, "Renderer scripts or styles were not loaded from bundled local resources")
        let fonts = try await fixture.bool("document.fonts.check('16px KaTeX_Main')")
        try require(fonts, "Bundled KaTeX fonts failed to load")
    }

    @MainActor private static func keyboardAndLinks(_ fixture: Fixture) async throws {
        try await fixture.render("Read the [documentation](https://example.invalid/docs). Math: $x+y$.")
        var opened: [URL] = []
        fixture.renderer.openLink = { opened.append($0) }
        _ = try await fixture.evaluate("document.querySelector('#content a').click(); true")
        for _ in 0..<30 where opened.isEmpty { try await Task.sleep(nanoseconds: 40_000_000) }
        try require(opened.map(\.absoluteString) == ["https://example.invalid/docs"],
                    "A user-activated safe link did not use the external link handler")
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.makeFirstResponder(fixture.renderer.webView)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        let result = fixture.renderer.webView.routeEvent(escape)
        try require(result == nil && fixture.window.cancellationCount == 1,
                    "Escape in the math view did not reach the note window's collapse action")
        let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        try require(fixture.renderer.webView.routeEvent(copy) === copy,
                    "Native math key routing swallowed the standard Copy shortcut")
    }

    @MainActor private static func saveSnapshots(_ fixture: Fixture) async throws {
        let destination = URL(fileURLWithPath: "/private/tmp/floating-math-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sample = #"""
        **Math in your conversation**

        Energy is $E=mc^2$, and \(\alpha+\beta=\gamma\).

        $$\int_0^1 x^2\,dx=\frac{1}{3}$$

        \[A=\begin{pmatrix}1 & 2\\3 & 4\end{pmatrix}\]

        ```python
        formula = "$x^2$"  # code stays unchanged
        ```
        """#
        try await fixture.resize(width: 480)
        for (name, dark) in [("light", false), ("dark", true)] {
            try await fixture.render(sample, dark: dark)
            try await snapshot(fixture, to: destination.appendingPathComponent(name + ".png"))
        }
        try await fixture.resize(width: 260)
        let equation = (0..<35).map { "x_{\($0)}" }.joined(separator: "+")
        try await fixture.render("**Narrow note**\n\nThis text wraps beside $a+b$.\n\n$$" + equation + "$$")
        try await snapshot(fixture, to: destination.appendingPathComponent("narrow.png"))
        print("Snapshots: \(destination.path)")
    }

    @MainActor private static func snapshot(_ fixture: Fixture, to url: URL) async throws {
        // The production web view is transparent over the native conversation.
        // Supply that backing only for standalone PNG review, then restore it.
        _ = try await fixture.evaluate("document.documentElement.style.backgroundColor=document.body.dataset.theme==='dark'?'#242424':'#ffffff'; true")
        let image = try await fixture.renderer.webView.takeSnapshot(configuration: nil)
        _ = try await fixture.evaluate("document.documentElement.style.backgroundColor=''; true")
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(message: "Could not encode the native math snapshot")
        }
        try data.write(to: url)
    }

    @MainActor private static func wheelRoutingAndClipping(_ fixture: Fixture) async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let scroll = CheckScrollView(frame: NSRect(x: 0, y: 100, width: 400, height: 300))
        host.addSubview(scroll)
        fixture.window.setContentSize(host.frame.size)
        fixture.window.contentView = host
        scroll.documentView = fixture.renderer.webView
        fixture.renderer.webView.frame = NSRect(x: 0, y: 0, width: 400, height: 1000)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let web = fixture.renderer.webView
        let visible = web.visibleRect
        let inside = web.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        let vertical = CheckWheelEvent(window: fixture.window, point: inside, delta: NSPoint(x: 0, y: 20))
        try require(web.routeEvent(vertical) == nil && scroll.forwardedWheels == 1,
                    "Vertical scrolling over a formula did not reach the parent conversation scroll view")
        let horizontal = CheckWheelEvent(window: fixture.window, point: inside, delta: NSPoint(x: 20, y: 0))
        try require(web.routeEvent(horizontal) === horizontal && scroll.forwardedWheels == 1,
                    "Horizontal equation scrolling was forwarded away from the math view")
        var clippedPoint: NSPoint?
        for y in stride(from: CGFloat(10), to: CGFloat(500), by: CGFloat(20)) {
            let candidate = NSPoint(x: 20, y: y)
            let converted = web.convert(candidate, from: nil)
            if web.bounds.contains(converted) && !web.visibleRect.contains(converted) { clippedPoint = candidate; break }
        }
        guard let clippedPoint else { throw CheckFailure(message: "Wheel fixture did not expose a clipped portion of the tall math view") }
        let outside = CheckWheelEvent(window: fixture.window, point: clippedPoint, delta: NSPoint(x: 0, y: 20))
        try require(web.routeEvent(outside) === outside && scroll.forwardedWheels == 1,
                    "A clipped math view intercepted scrolling intended for another note control")
    }
}
