import AppKit
import SwiftUI
import FloatingAICore

/// NSTextView keeps native Chinese/Japanese composition and paste behavior intact.
struct ComposerView: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: UUID
    var onSend: () -> Void
    var onEscape: () -> Void
    var onImage: (NSImage) -> Void
    var onFiles: ([URL]) -> Void
    var onComposition: (Bool) -> Void
    var canFocus: () -> Bool = { true }
    var onImageData: ((Data) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let editor = ChatTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 8, height: 9)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 44)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.string = text
        editor.isEditable = context.environment.isEnabled
        scroll.documentView = editor
        context.coordinator.editor = editor
        updateCallbacks(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatTextView else { return }
        updateCallbacks(editor)
        editor.isEditable = context.environment.isEnabled
        // Never replace marked text while the input method owns it.
        if editor.string != text && !editor.hasMarkedText() {
            editor.replaceDraft(with: text)
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            let canFocus = canFocus
            DispatchQueue.main.async { [weak editor] in
                guard canFocus(), let editor, let window = editor.window, window.isKeyWindow else { return }
                // A queued focus request must not interrupt a title rename begun
                // after this request was scheduled.
                guard !(window.firstResponder is NoteTitleField),
                      (window.firstResponder as? NSTextView)?.isFieldEditor != true else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    private func updateCallbacks(_ editor: ChatTextView) {
        editor.onSend = onSend
        editor.onEscape = onEscape
        editor.onImage = onImage
        editor.onImageData = onImageData
        editor.onFiles = onFiles
        editor.onComposition = onComposition
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.editor?.onComposition?(false)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerView
        weak var editor: ChatTextView?
        var lastFocusRequest: UUID?

        init(_ parent: ComposerView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let viewportHeight = max(0, contentSize.height)
        if editor.minSize.height != viewportHeight {
            editor.minSize = NSSize(width: 0, height: viewportHeight)
            editor.sizeToFit()
        }
    }
}

/// A native grip keeps resizing separate from window dragging and text composition.
struct ComposerResizeHandle: NSViewRepresentable {
    var height: CGFloat
    var maximumHeight: CGFloat
    var onChange: (CGFloat) -> Void
    var onInteraction: (Bool) -> Void

    func makeNSView(context: Context) -> ComposerResizeView {
        let view = ComposerResizeView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ComposerResizeView, context: Context) { configure(view) }

    private func configure(_ view: ComposerResizeView) {
        view.height = height
        view.maximumHeight = maximumHeight
        view.onChange = onChange
        view.onInteraction = onInteraction
        view.toolTip = "Drag to resize the message box; double-click to reset"
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Resize message box")
        view.setAccessibilityValue("\(Int(height)) points")
    }

    static func dismantleNSView(_ view: ComposerResizeView, coordinator: ()) { view.endResize() }
}

final class ComposerResizeView: NSView {
    var height: CGFloat = 64
    var maximumHeight: CGFloat = 320
    var onChange: ((CGFloat) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    private var dragOrigin: (screenY: CGFloat, height: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 0.5).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { changeHeight(64); return }
        dragOrigin = (screenY(event), height)
        onInteraction?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        changeHeight(origin.height + screenY(event) - origin.screenY)
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil { mouseDragged(with: event) }
        endResize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endResize() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func accessibilityPerformIncrement() -> Bool { changeHeight(height + 16); return true }
    override func accessibilityPerformDecrement() -> Bool { changeHeight(height - 16); return true }

    func endResize() {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        onInteraction?(false)
    }

    private func screenY(_ event: NSEvent) -> CGFloat {
        window?.convertPoint(toScreen: event.locationInWindow).y ?? event.locationInWindow.y
    }

    private func changeHeight(_ value: CGFloat) {
        onChange?(max(44, min(maximumHeight, value)))
    }
}

final class ChatTextView: NSTextView {
    // A note's draft must not share undo actions with a title or another editor.
    private let draftUndoManager = UndoManager()
    override var undoManager: UndoManager? { draftUndoManager }

    // NSWindow's default actions use its window-wide manager. Handle the
    // responder actions here and publish the edited text back to SwiftUI.
    @objc func undo(_ sender: Any?) {
        guard isEditable, draftUndoManager.canUndo else { return }
        breakUndoCoalescing()
        draftUndoManager.undo()
        didChangeText()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, draftUndoManager.canRedo else { return }
        breakUndoCoalescing()
        draftUndoManager.redo()
        didChangeText()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return isEditable && draftUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && draftUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    func replaceDraft(with text: String) {
        breakUndoCoalescing()
        draftUndoManager.removeAllActions()
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    var onImage: ((NSImage) -> Void)?
    var onImageData: ((Data) -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onComposition: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isEditable && isReturn && !hasMarkedText() && !event.modifierFlags.contains(.shift) {
            onSend?()
            return
        }
        if event.keyCode == 53 && !hasMarkedText() {
            onEscape?()
            return
        }
        super.keyDown(with: event)
        onComposition?(hasMarkedText())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onComposition?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onComposition?(false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onComposition?(hasMarkedText())
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if importImages(from: .general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if importImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    func importImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        if let onImageData {
            for identifier in AttachmentImageCodec.encodedTypeIdentifiers {
                if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(identifier)) {
                    onImageData(data)
                    return true
                }
            }
        }
        if let image = NSImage(pasteboard: pasteboard) {
            onImage?(image)
            return true
        }
        return false
    }
}
