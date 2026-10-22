import AppKit
import SwiftUI

enum CompactResizeGeometry {
    static let minimumSize = NSSize(width: 160, height: 36)
    static let maximumSize = NSSize(width: 640, height: 160)
    static let defaultSize = NSSize(width: 220, height: 40)
    static let edgeWidth: CGFloat = 6
    static let cornerWidth: CGFloat = 10

    static func edges(at point: NSPoint, in bounds: NSRect) -> CompactResizeEdges {
        guard bounds.contains(point) else { return [] }
        let left = point.x - bounds.minX, right = bounds.maxX - point.x
        let bottom = point.y - bounds.minY, top = bounds.maxY - point.y
        if left <= cornerWidth && bottom <= cornerWidth { return [.left, .bottom] }
        if left <= cornerWidth && top <= cornerWidth { return [.left, .top] }
        if right <= cornerWidth && bottom <= cornerWidth { return [.right, .bottom] }
        if right <= cornerWidth && top <= cornerWidth { return [.right, .top] }
        if left <= edgeWidth { return .left }
        if right <= edgeWidth { return .right }
        if bottom <= edgeWidth { return .bottom }
        if top <= edgeWidth { return .top }
        return []
    }

    static func resized(_ original: NSRect, edges: CompactResizeEdges, delta: NSPoint, within area: NSRect) -> NSRect {
        let minimum = NSSize(width: min(minimumSize.width, area.width), height: min(minimumSize.height, area.height))
        let maximum = NSSize(width: min(maximumSize.width, area.width), height: min(maximumSize.height, area.height))
        var result = original
        if edges.contains(.left) {
            result.origin.x = max(max(area.minX, original.maxX - maximum.width),
                                  min(original.minX + delta.x, original.maxX - minimum.width))
            result.size.width = original.maxX - result.minX
        } else if edges.contains(.right) {
            result.size.width = max(minimum.width, min(original.width + delta.x, min(maximum.width, area.maxX - original.minX)))
        }
        if edges.contains(.bottom) {
            result.origin.y = max(max(area.minY, original.maxY - maximum.height),
                                  min(original.minY + delta.y, original.maxY - minimum.height))
            result.size.height = original.maxY - result.minY
        } else if edges.contains(.top) {
            result.size.height = max(minimum.height, min(original.height + delta.y, min(maximum.height, area.maxY - original.minY)))
        }
        return result
    }
}

/// Only the compact perimeter participates in hit testing. The center remains
/// available to the existing title clicks, rename gestures and window dragging.
struct CompactResizeView: NSViewRepresentable {
    var active: Bool
    var onBegin: (CompactResizeEdges, NSPoint) -> Bool
    var onUpdate: (NSPoint) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> CompactResizeHandle {
        let view = CompactResizeHandle()
        configure(view)
        return view
    }
    func updateNSView(_ view: CompactResizeHandle, context: Context) { configure(view) }
    @MainActor private func configure(_ view: CompactResizeHandle) {
        view.onBegin = onBegin
        view.onUpdate = onUpdate
        view.onEnd = onEnd
        view.active = active
    }
    static func dismantleNSView(_ view: CompactResizeHandle, coordinator: ()) { view.endResize(deferred: true) }
}

final class CompactResizeHandle: NSView {
    var onBegin: ((CompactResizeEdges, NSPoint) -> Bool)?
    var onUpdate: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    var active = false {
        didSet {
            if !active { endResize(deferred: true) }
            if oldValue != active { window?.invalidateCursorRects(for: self) }
        }
    }
    private var isResizing = false
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard active, !isHiddenOrHasHiddenAncestor,
              !CompactResizeGeometry.edges(at: convert(point, from: superview), in: bounds).isEmpty else { return nil }
        return self
    }

    override func resetCursorRects() {
        guard active else { return }
        let corner = CompactResizeGeometry.cornerWidth, edge = CompactResizeGeometry.edgeWidth
        addCursorRect(NSRect(x: 0, y: corner, width: edge, height: max(0, bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: corner, width: edge, height: max(0, bounds.height - 2 * corner)), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: corner, y: 0, width: max(0, bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: corner, y: bounds.height - edge, width: max(0, bounds.width - 2 * corner), height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: 0, width: corner, height: corner), cursor: Self.ascendingCursor)
        addCursorRect(NSRect(x: bounds.width - corner, y: bounds.height - corner, width: corner, height: corner), cursor: Self.ascendingCursor)
        addCursorRect(NSRect(x: 0, y: bounds.height - corner, width: corner, height: corner), cursor: Self.descendingCursor)
        addCursorRect(NSRect(x: bounds.width - corner, y: 0, width: corner, height: corner), cursor: Self.descendingCursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard active, let window else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let edges = CompactResizeGeometry.edges(at: convert(event.locationInWindow, from: nil), in: bounds)
        guard !edges.isEmpty else { return }
        isResizing = onBegin?(edges, window.convertPoint(toScreen: event.locationInWindow)) == true
    }
    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window else { return }
        onUpdate?(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) { endResize() }
    override func rightMouseDown(with event: NSEvent) {
        // The manager-owned hosting view supplies Hide / Reset Size / Delete.
        window?.contentView?.rightMouseDown(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { endResize(deferred: true) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidHide() { super.viewDidHide(); endResize(deferred: true) }

    func endResize(deferred: Bool = false) {
        guard isResizing else { return }
        isResizing = false
        let completion = onEnd
        if deferred { DispatchQueue.main.async { completion?() } }
        else { completion?() }
    }

    private static let ascendingCursor = diagonalCursor(ascending: true)
    private static let descendingCursor = diagonalCursor(ascending: false)
    private static func diagonalCursor(ascending: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let path = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: ascending ? y : 18 - y) }
        path.move(to: point(3, 3)); path.line(to: point(15, 15))
        path.move(to: point(3, 8)); path.line(to: point(3, 3)); path.line(to: point(8, 3))
        path.move(to: point(10, 15)); path.line(to: point(15, 15)); path.line(to: point(15, 10))
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
        NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
}
