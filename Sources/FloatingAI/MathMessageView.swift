import AppKit
import SwiftUI
import WebKit

enum MathResources {
    static var directory: URL? {
        let manager = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("MathRendering", isDirectory: true)
        if Bundle.main.bundleURL.pathExtension == "app" {
            // A distributed app must work from its own resources, never a source checkout.
            return bundled
        }
        if let bundled, manager.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidate = sourceRoot.appendingPathComponent("Resources/MathRendering", isDirectory: true)
        return manager.fileExists(atPath: candidate.appendingPathComponent("index.html").path) ? candidate : nil
    }
}

/// Only bundled, explicitly named assets can be served. The web process receives
/// no file URL or read access to the user's files, notes, or CLI configuration.
final class MathAssetHandler: NSObject, WKURLSchemeHandler {
    private let assets: [String: (Data, String)]
    init(directory: URL?) {
        var loaded: [String: (Data, String)] = [:]
        let files = ["index.html": "text/html", "renderer.js": "text/javascript", "style.css": "text/css",
                     "katex.min.js": "text/javascript", "katex.min.css": "text/css",
                     "marked.umd.js": "text/javascript", "purify.min.js": "text/javascript"]
        if let directory {
            for (name, mime) in files {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)), data.count < 4_000_000 {
                    loaded["/" + name] = (data, mime)
                }
            }
            let fonts = directory.appendingPathComponent("fonts", isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                if name.range(of: #"^KaTeX_[A-Za-z0-9_-]+\.woff2$"#, options: .regularExpression) != nil,
                   let data = try? Data(contentsOf: file), data.count < 1_000_000 {
                    loaded["/fonts/" + name] = (data, "font/woff2")
                }
            }
        }
        assets = loaded
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "floating-math", url.host == "assets",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil,
              urlSchemeTask.request.httpMethod == "GET", let (data, mime) = assets[url.path] else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                            textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor final class MathWebView: WKWebView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if window != nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.routeEvent(event)
            }
        }
    }

    func routeEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        if event.type == .keyDown, event.keyCode == 53,
           let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) {
            window.cancelOperation(nil)
            return nil
        }
        if event.type == .scrollWheel, !event.modifierFlags.contains(.shift),
           abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
           containsPointerTarget(event.locationInWindow) {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    scroll.scrollWheel(with: event)
                    return nil
                }
                ancestor = view.superview
            }
        }
        return event
    }

    private func containsPointerTarget(_ pointInWindow: NSPoint) -> Bool {
        // A tall message can extend behind the composer outside the transcript's
        // clip view. Only intercept wheel events over the visible web content.
        guard !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(pointInWindow, from: nil)),
              let content = window?.contentView else { return false }
        let pointInParent = content.superview?.convert(pointInWindow, from: nil) ?? pointInWindow
        guard let target = content.hitTest(pointInParent) else { return false }
        return target === self || target.isDescendant(of: self)
    }

    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
}

@MainActor private final class MathLayoutBridge: NSObject, WKScriptMessageHandler {
    weak var owner: MathMessageRenderer?
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit invokes its view and script delegates on the main thread. The
        // macOS 13 SDK predates the corresponding Swift actor annotations.
        MainActor.assumeIsolated { owner?.receiveLayout(message) }
    }
}

@MainActor final class MathMessageRenderer: NSObject, WKNavigationDelegate {
    static let pageURL = URL(string: "floating-math://assets/index.html")!
    let webView: MathWebView
    var onHeight: ((CGFloat) -> Void)?
    var onFailure: (() -> Void)?
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var source = ""
    private(set) var revision = 0
    private(set) var renderedRevision = 0
    private(set) var completedRevision = 0
    private var darkMode = false
    private var ready = false
    private var stopped = false
    private var failed = false
    private var rendering = false
    private var pending: DispatchWorkItem?
    private let bridge = MathLayoutBridge()

    init(resourceDirectory: URL? = MathResources.directory) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(MathAssetHandler(directory: resourceDirectory), forURLScheme: "floating-math")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = MathWebView(frame: .zero, configuration: configuration)
        super.init()
        bridge.owner = self
        configuration.userContentController.add(bridge, name: "layout")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: Self.pageURL))
    }

    func render(text: String, darkMode: Bool) {
        guard !stopped, !failed, revision == 0 || source != text || self.darkMode != darkMode else { return }
        guard text.utf8.count <= 128_000 else { fail(); return }
        source = text
        self.darkMode = darkMode
        revision += 1
        schedule()
    }

    func copySource(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "layout")
        bridge.owner = nil
    }

    private func schedule() {
        guard ready, !stopped, !failed, !rendering, pending == nil, renderedRevision != revision else { return }
        let work = DispatchWorkItem { [weak self] in self?.submit() }
        pending = work
        // Throttle streaming updates without postponing rendering indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func submit() {
        pending = nil
        guard ready, !stopped, !failed else { return }
        rendering = true
        let submittedRevision = revision
        renderedRevision = submittedRevision
        webView.callAsyncJavaScript("return window.renderMessage(text, revision, darkMode);",
                                   arguments: ["text": source, "revision": submittedRevision, "darkMode": darkMode],
                                   in: nil, in: .page) { [weak self] result in
            guard let self, !self.stopped else { return }
            self.rendering = false
            switch result {
            case .success: self.completedRevision = submittedRevision; self.schedule()
            case .failure: self.fail()
            }
        }
    }

    fileprivate func receiveLayout(_ message: WKScriptMessage) {
        guard !stopped, !failed, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url == Self.pageURL,
              let body = message.body as? [String: Any], let receivedRevision = body["revision"] as? Int,
              receivedRevision == renderedRevision, let number = body["height"] as? NSNumber else { return }
        let height = number.doubleValue
        guard height.isFinite, height > 0, height <= 100_000 else { fail(); return }
        onHeight?(CGFloat(ceil(height)))
    }

    private func fail() {
        guard !failed, !stopped else { return }
        failed = true
        pending?.cancel()
        pending = nil
        onFailure?()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { ready = true; schedule() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { fail() }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { fail() }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            if !ready, navigationAction.targetFrame?.isMainFrame == true, url == Self.pageURL {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.isMainFrame,
               let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
               url.user == nil, url.password == nil {
                openLink(url)
            }
        }
    }
}

@MainActor struct MathMessageView: View {
    let text: String
    var onLayoutChange: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 28
    @State private var failed = false

    static func shouldRender(_ text: String) -> Bool {
        text.utf8.count <= 128_000 && (text.contains("$") || text.contains("\\(") || text.contains("\\["))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if failed {
                Text(text).font(.system(size: 14)).textSelection(.enabled)
            } else {
                MathWebContent(text: text, darkMode: colorScheme == .dark, onHeight: { value in
                    if abs(value - height) > 0.5 { onLayoutChange(); height = value }
                }, onFailure: { failed = true; onLayoutChange() })
                .frame(height: height)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Label("Copy message", systemImage: "doc.on.doc") }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private struct MathWebContent: NSViewRepresentable {
    let text: String
    let darkMode: Bool
    var onHeight: (CGFloat) -> Void
    var onFailure: () -> Void

    func makeCoordinator() -> MathMessageRenderer { MathMessageRenderer() }
    func makeNSView(context: Context) -> MathWebView {
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailure = onFailure
        context.coordinator.render(text: text, darkMode: darkMode)
        return context.coordinator.webView
    }
    func updateNSView(_ view: MathWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailure = onFailure
        context.coordinator.render(text: text, darkMode: darkMode)
    }
    static func dismantleNSView(_ view: MathWebView, coordinator: MathMessageRenderer) { coordinator.stop() }
}
