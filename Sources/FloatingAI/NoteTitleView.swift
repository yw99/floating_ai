import AppKit
import SwiftUI

/// Native title fields and drag regions share the same menu and interaction lock.
/// Deletion runs only after menu tracking ends, so its confirmation cannot nest
/// inside an open context menu or be triggered by the initial right-click.
@MainActor final class NoteTitleContextMenu: NSObject {
    var canDelete = false
    var onHide: (() -> Void)?
    var onResetSize: (() -> Void)?
    var onDelete: (() -> Void)?
    var onInteraction: ((Bool) -> Void)?
    private enum SelectedAction { case hide, resetSize, delete }
    private var selectedAction: SelectedAction?

    func popUp(with event: NSEvent, for view: NSView,
               tracking: (NSMenu, NSEvent, NSView) -> Void = { NSMenu.popUpContextMenu($0, with: $1, for: $2) }) {
        selectedAction = nil
        onInteraction?(true)
        defer { onInteraction?(false) }
        tracking(makeMenu(), event, view)
        switch selectedAction {
        case .hide: onHide?()
        case .resetSize: onResetSize?()
        case .delete: onDelete?()
        case nil: break
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hide = NSMenuItem(title: "Hide Note", action: #selector(selectHide(_:)), keyEquivalent: "")
        hide.target = self
        hide.isEnabled = onHide != nil
        menu.addItem(hide)
        if onResetSize != nil {
            let reset = NSMenuItem(title: "Reset Size", action: #selector(selectResetSize(_:)), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Delete Note…", action: #selector(selectDelete(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canDelete
        menu.addItem(item)
        return menu
    }

    @objc private func selectDelete(_ sender: NSMenuItem) {
        guard canDelete, sender.isEnabled else { return }
        selectedAction = .delete
    }

    @objc private func selectHide(_ sender: NSMenuItem) {
        guard onHide != nil, sender.isEnabled else { return }
        selectedAction = .hide
    }

    @objc private func selectResetSize(_ sender: NSMenuItem) {
        guard onResetSize != nil else { return }
        selectedAction = .resetSize
    }
}

/// Responds promptly to single clicks while keeping the system double-click interval.
struct NoteTitleView: NSViewRepresentable {
    var title: String
    var fontSize: CGFloat
    var weight: NSFont.Weight
    var active: Bool
    var compactFrame: NSRect? = nil
    var onSingleClick: () -> Void
    var onCommit: (String) -> Void
    var onEditing: (Bool) -> Void
    var onSingleClickPreservingHeader: ((TimeInterval) -> Void)? = nil
    var canRename = true
    var canDelete = false
    var onHide: (() -> Void)? = nil
    var onResetSize: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onMenuInteraction: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NoteTitleField {
        let field = NoteTitleField(frame: .zero)
        configure(field)
        return field
    }

    func updateNSView(_ field: NoteTitleField, context: Context) { configure(field) }

    @MainActor private func configure(_ field: NoteTitleField) {
        field.onSingleClick = onSingleClick
        field.onCommit = onCommit
        field.onEditing = onEditing
        field.onSingleClickPreservingHeader = onSingleClickPreservingHeader
        field.compactFrame = compactFrame
        field.canRename = canRename
        field.titleContextMenu.canDelete = canDelete
        field.titleContextMenu.onHide = onHide
        field.titleContextMenu.onResetSize = onResetSize
        field.titleContextMenu.onDelete = onDelete
        field.titleContextMenu.onInteraction = onMenuInteraction
        field.font = .systemFont(ofSize: fontSize, weight: weight)
        field.update(title: title, active: active)
    }

    static func dismantleNSView(_ field: NoteTitleField, coordinator: ()) {
        field.deactivate()
    }
}

final class NoteTitleField: NSTextField, NSTextFieldDelegate {
    var onSingleClick: (() -> Void)?
    var onCommit: ((String) -> Void)?
    var onEditing: ((Bool) -> Void)?
    var onSingleClickPreservingHeader: ((TimeInterval) -> Void)?
    var compactFrame: NSRect?
    var canRename = true
    let titleContextMenu = NoteTitleContextMenu()

    private var active = false
    private var modelTitle = "Ask Me Anything"
    private var isRenaming = false
    private var isEndingRename = false
    private var mouseDownLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    fileprivate static var clickSequence: NoteTitleClickSequence?

    static func cancelClickSequence(in window: NSWindow) {
        if clickSequence?.window === window { clickSequence?.cancel() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = NoteTitleCell(textCell: "")
        delegate = self
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        textColor = .labelColor
        alignment = .left
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Note title")
        setAccessibilityHelp("Drag to move; click to expand or collapse; double-click to rename")
        toolTip = "Drag to move; click to expand or collapse; double-click to rename"
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    deinit {
        cancelPendingClick()
        NotificationCenter.default.removeObserver(self)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { active && isRenaming }
    override var needsPanelToBecomeKey: Bool { isRenaming }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(title: String, active: Bool) {
        modelTitle = Self.normalized(title)
        self.active = active
        if !active {
            mouseDownEvent = nil
            mouseDownLocation = nil
            cancelPendingClick()
            finishRename(commit: true, deferred: true)
        }
        if !isRenaming { stringValue = modelTitle }
    }

    func deactivate() {
        active = false
        mouseDownLocation = nil
        mouseDownEvent = nil
        cancelPendingClick()
        // A disappearing title may still own the field editor. Preserve its buffer,
        // but deliver the model change after SwiftUI finishes updating the view tree.
        finishRename(commit: true, deferred: true)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            cancelPendingClick()
            finishRename(commit: true, deferred: true)
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelPendingClick()
        finishRename(commit: true, deferred: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard canInteract else { return }
        if isRenaming { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        if Self.clickSequence?.handleDoubleClick(event) == true { return }
        cancelPendingClick()
        mouseDownLocation = event.locationInWindow
        mouseDownEvent = event
        dragged = false
        if event.clickCount >= 2 {
            mouseDownLocation = nil
            mouseDownEvent = nil
            beginRename()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard canInteract else { return }
        if isRenaming { super.rightMouseDown(with: event); return }
        cancelPendingClick()
        mouseDownLocation = nil
        mouseDownEvent = nil
        titleContextMenu.popUp(with: event, for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        if isRenaming { super.mouseDragged(with: event); return }
        guard !dragged, let start = mouseDownLocation, let mouseDownEvent, let window else { return }
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 {
            dragged = true
            Self.clickSequence?.cancel()
            // AppKit owns movement after this handoff and may consume mouseUp.
            // End the click gesture now so releasing a drag never toggles the note.
            self.mouseDownEvent = nil
            mouseDownLocation = nil
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window.performDrag(with: mouseDownEvent)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil; mouseDownEvent = nil }
        guard canInteract, !isRenaming, mouseDownLocation != nil, !dragged, event.clickCount == 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        scheduleSingleClick(at: event.locationInWindow)
    }

    fileprivate var canInteract: Bool {
        active && window?.isVisible == true && !isHiddenOrHasHiddenAncestor && alphaValue > 0
    }

    fileprivate func beginRename() {
        guard canInteract, canRename, !isRenaming, let window else { return }
        cancelPendingClick()
        isRenaming = true
        isEditable = true
        isSelectable = true
        stringValue = modelTitle
        // The owner must allow keyboard focus before a compact nonactivating panel
        // attempts to become key or install its native field editor.
        onEditing?(true)
        guard isRenaming, canInteract else { finishRename(commit: false); return }
        window.makeKeyAndOrderFront(nil)
        guard window.makeFirstResponder(self) else { finishRename(commit: false); return }
        // makeFirstResponder already installs the shared field editor. Calling
        // selectText here would replace it, emit didEndEditing, and immediately
        // turn this title back into a noneditable label before the first keystroke.
        guard let editor = currentEditor() as? NSTextView else { finishRename(commit: false); return }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    }

    private func finishRename(commit: Bool, deferred: Bool = false) {
        guard isRenaming, !isEndingRename else { return }
        isEndingRename = true
        let editor = currentEditor() as? NSTextView
        // Enter and Escape never reach here while marked text is active. A forced
        // hide/detach still preserves that visible buffer instead of losing it.
        let value = Self.normalized(editor?.string ?? stringValue)
        isRenaming = false
        window?.endEditing(for: self)
        isEditable = false
        isSelectable = false
        if commit { modelTitle = value }
        stringValue = modelTitle
        let commitCallback = onCommit
        let editingCallback = onEditing
        isEndingRename = false
        if commit {
            if deferred { DispatchQueue.main.async { commitCallback?(value) } }
            else { commitCallback?(value) }
        }
        // Only the title that began editing releases the owner's interaction lock.
        editingCallback?(false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isEndingRename else { return }
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isRenaming else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }
            finishRename(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            guard !textView.hasMarkedText() else { return false }
            finishRename(commit: false)
            return true
        }
        return false
    }

    private func scheduleSingleClick(at location: NSPoint) {
        Self.clickSequence?.cancel()
        guard let window else { return }
        let sequence = NoteTitleClickSequence(field: self, window: window, location: location)
        Self.clickSequence = sequence
        sequence.start()
    }

    private func cancelPendingClick() {
        guard let sequence = Self.clickSequence, sequence.origin === self,
              !sequence.didPerformSingleClick else { return }
        sequence.cancel()
    }

    @objc private func windowDidResignKey(_ notification: Notification) { cancelPendingClick() }
    @objc private func applicationDidResignActive(_ notification: Notification) {
        if Self.clickSequence?.window === window { Self.clickSequence?.cancel() }
    }
    @objc private func windowWillClose(_ notification: Notification) {
        if Self.clickSequence?.window === window { Self.clickSequence?.cancel() }
        deactivate()
    }

    private static func normalized(_ title: String) -> String {
        let value = title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Ask Me Anything" : value
    }
}

/// A speculative toggle can replace the title view and move its hit region. Keep
/// arbitration at window scope until the full system interval has elapsed, then
/// restore the original presentation if a slower second click requests a rename.
fileprivate final class NoteTitleClickSequence {
    weak var origin: NoteTitleField?
    weak var window: NSWindow?
    private(set) var didPerformSingleClick = false
    private var isRestoringTitle = false
    private let originalTitleRect: NSRect
    private let delay: TimeInterval
    private let interval: TimeInterval
    private let headerGrace: TimeInterval
    private var singleClickWork: DispatchWorkItem?
    private var expiryWork: DispatchWorkItem?
    private var localMouseMonitor: Any?
    private var outsideMouseMonitor: Any?

    init(field: NoteTitleField, window: NSWindow, location: NSPoint) {
        origin = field
        self.window = window
        originalTitleRect = window.convertToScreen(field.convert(field.bounds, to: nil))
        interval = NSEvent.doubleClickInterval
        let point = window.convertPoint(toScreen: location)
        // Keep a visible title strip at the original position if shrinking now
        // would send a slower second click into the application underneath.
        // Chat content still collapses after 100 ms everywhere on the title.
        let remainsInPanel = field.compactFrame.map { $0.contains(point) } ?? true
        let preservesHeader = !remainsInPanel && field.onSingleClickPreservingHeader != nil
        delay = remainsInPanel || preservesHeader ? min(0.1, interval) : interval
        headerGrace = preservesHeader ? max(0, interval + 0.04 - delay) : 0
    }

    func start() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.handleDoubleClick(event) { return nil }
            self.cancel()
            return event
        }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.cancel()
        }
        let singleClick = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let field = self.origin, field.canInteract, self.window === field.window else {
                self.cancel()
                return
            }
            // Set this before the callback: its resize can synchronously resign
            // the panel and asynchronously dismantle the original title view.
            self.didPerformSingleClick = true
            if self.headerGrace > 0, let collapse = field.onSingleClickPreservingHeader {
                collapse(self.headerGrace)
            } else {
                field.onSingleClick?()
            }
        }
        singleClickWork = singleClick
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: singleClick)
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        expiryWork = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + interval + 0.04, execute: expiry)
    }

    @discardableResult func handleDoubleClick(_ event: NSEvent) -> Bool {
        guard !isRestoringTitle, event.type == .leftMouseDown, event.clickCount >= 2,
              let window, event.window === window, window.isVisible,
              originalTitleRect.contains(window.convertPoint(toScreen: event.locationInWindow)) else { return false }
        singleClickWork?.cancel()
        if !didPerformSingleClick {
            cancel()
            origin?.beginRename()
            return true
        }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let current = Self.activeTitle(in: window.contentView) else { cancel(); return true }
        if current === origin {
            // The first toggle may have been blocked by an ongoing interaction.
            cancel()
            current.beginRename()
        } else {
            isRestoringTitle = true
            current.onSingleClick?()
            // SwiftUI installs or reactivates the restored title on its next pass.
            renameRestoredTitle(replacing: ObjectIdentifier(current))
        }
        return true
    }

    func cancel() {
        singleClickWork?.cancel()
        expiryWork?.cancel()
        singleClickWork = nil
        expiryWork = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        localMouseMonitor = nil
        outsideMouseMonitor = nil
        if NoteTitleField.clickSequence === self { NoteTitleField.clickSequence = nil }
    }

    private static func activeTitle(in view: NSView?) -> NoteTitleField? {
        guard let view else { return nil }
        if let field = view as? NoteTitleField, field.canInteract { return field }
        for child in view.subviews {
            if let field = activeTitle(in: child) { return field }
        }
        return nil
    }

    private func renameRestoredTitle(replacing previous: ObjectIdentifier, attempts: Int = 12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self else { return }
            guard let window = self.window, window.isVisible,
                  NSApp.keyWindow == nil || NSApp.keyWindow === window else { self.cancel(); return }
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = Self.activeTitle(in: window.contentView), ObjectIdentifier(field) != previous {
                self.cancel()
                field.beginRename()
            } else if attempts > 0 {
                self.renameRestoredTitle(replacing: previous, attempts: attempts - 1)
            } else {
                self.cancel()
            }
        }
    }
}

/// NSTextField's default label layout sits at the top of a tall frame. Keep both
/// its drawing and shared field editor centered in the compact and expanded rows.
private final class NoteTitleCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let height = min(drawing.height, cellSize(forBounds: rect).height)
        drawing.origin.y += (drawing.height - height) / 2
        drawing.size.height = height
        return drawing
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
