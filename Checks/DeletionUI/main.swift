import AppKit
import FloatingAICore
import SwiftUI

// Production controls and panel lifecycle with temporary app storage only.
// No real CLI, account, user note, or conversation history is touched.
private struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

private final class EmptyKeyStore: APIKeyStore, @unchecked Sendable {
    func read() throws -> String? { nil }
    func save(_ key: String) throws { throw CheckFailure(message: "Unexpected credential save") }
    func delete() throws { throw CheckFailure(message: "Unexpected credential deletion") }
}

@MainActor private final class ConfirmationDriver: NSObject {
    let choice: String
    let exerciseReturn: Bool
    var captured = false
    private(set) var exercisedReturn = false
    private(set) var foundDialog = false
    private(set) var safeKeyboardCancellation = false
    private(set) var deleteIsDestructive = false
    private var timer: Timer?
    private var deadline = Date()
    private var appearedAt: Date?
    private(set) var buttonDiagnostics = ""

    init(choice: String, exerciseReturn: Bool = false) { self.choice = choice; self.exerciseReturn = exerciseReturn }

    func start() {
        deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(checkDialog(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }

    func stop() { timer?.invalidate(); timer = nil }

    @objc private func checkDialog(_ timer: Timer) {
        guard let modal = NSApplication.shared.modalWindow, let content = modal.contentView else {
            if Date() > deadline { stop(); NSApplication.shared.abortModal() }
            return
        }
        if appearedAt == nil { appearedAt = Date(); return }
        guard Date().timeIntervalSince(appearedAt!) >= 0.5 else { return }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let buttons = buttons(in: content)
        guard let cancel = buttons.first(where: { $0.title == "Cancel" }),
              let delete = buttons.first(where: { $0.title == "Delete Note" }),
              let selected = buttons.first(where: { $0.title == choice }) else {
            if Date() > deadline { stop(); NSApplication.shared.abortModal() }
            return
        }
        foundDialog = true
        safeKeyboardCancellation = delete.keyEquivalent != "\r" && modal.defaultButtonCell !== delete.cell &&
            (cancel.keyEquivalent == "\r" || cancel.keyEquivalent == "\u{1b}" || modal.defaultButtonCell === cancel.cell)
        deleteIsDestructive = delete.hasDestructiveAction
        buttonDiagnostics = buttons.map { "\($0.title): key=\($0.keyEquivalent.unicodeScalars.map(\.value)), default=\(modal.defaultButtonCell === $0.cell), destructive=\($0.hasDestructiveAction)" }.joined(separator: "; ")
        if choice == "Cancel", let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                                   CGWindowID(modal.windowNumber), .boundsIgnoreFraming) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/preview-delete-confirmation.png")
                captured = (try? png.write(to: destination)) != nil
            }
        }
        if exerciseReturn, !exercisedReturn {
            exercisedReturn = true
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: modal.windowNumber, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            modal.sendEvent(enter)
            return
        }
        stop()
        selected.performClick(nil)
    }
}

@MainActor private final class ComposerDraft: ObservableObject {
    @Published var text = ""
    var sends = 0
}

private struct UndoComposer: View {
    @ObservedObject var draft: ComposerDraft
    let focusRequest = UUID()
    var body: some View {
        ComposerView(text: $draft.text, focusRequest: focusRequest,
                     onSend: { draft.sends += 1; draft.text = "" }, onEscape: {},
                     onImage: { _ in }, onFiles: { _ in }, onComposition: { _ in })
    }
}

@main struct DeletionUIChecks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { await runChecks() }
        // Native button tracking needs the same outer AppKit event loop as the
        // app; an async CLI main alone is insufficient for mouse dispatch.
        application.run()
    }

    @MainActor private static func runChecks() async {
        do {
            try titleMenuDefersDeletionUntilSelection()
            try titleMenuCancelAndDisabledKeepNote()
            try compactResizeGeometryPreservesAnchors()
            try await titleMenuHidesCompactAndExpandedNotes()
            try await disabledComposerCannotSend()
            try await composerUndoSurvivesDraftReplacement()
            try await composerUndoIsIsolatedAndPreservesComposition()
            try composerPastePrefersEncodedImages()
            try require(!NSScreen.screens.isEmpty, "Native panel checks require macOS window-server access")
            try await headerHideAcceptsClicksAroundItsSymbol()
            try await compactResizeKeepsFocusAndIndependentSizes()
            try await compactResizeResetAndHideDuringGesture()
            try await resizedTitleKeepsClickAndRenameBehavior()
            try await confirmationRequiresExplicitDeletionChoice()
            try await hidingAndDeletingHaveDifferentLifecycles()
            try await failedDeletionKeepsPanelAndHistoryReference()
            try await queuedCreationCannotResurrectDeletedPanel()
            print("PASS: 16 native note-action UI checks")
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func mouseEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor private static func titleMenuDefersDeletionUntilSelection() throws {
        let controller = NoteTitleContextMenu()
        controller.canDelete = true
        var events: [String] = []
        controller.onDelete = { events.append("delete") }
        controller.onInteraction = { events.append($0 ? "lock" : "unlock") }
        var menuCorrect = false
        var deletionWasDeferred = false
        controller.popUp(with: mouseEvent(), for: NSView()) { menu, _, _ in
            let index = menu.indexOfItem(withTitle: "Delete Note…")
            menuCorrect = index >= 0 && menu.items[index].isEnabled
            events.append("tracking")
            if index >= 0 { menu.performActionForItem(at: index) }
            deletionWasDeferred = events == ["lock", "tracking"]
            events.append("tracked")
        }
        try require(menuCorrect, "Title context menu is missing its deletion action")
        try require(deletionWasDeferred, "Deletion started while the context menu was still tracking")
        try require(events == ["lock", "tracking", "tracked", "delete", "unlock"],
                    "The context menu released collapse protection before confirmation")
    }

    @MainActor private static func titleMenuCancelAndDisabledKeepNote() throws {
        let controller = NoteTitleContextMenu()
        controller.canDelete = true
        var deletions = 0
        var interactions: [Bool] = []
        controller.onDelete = { deletions += 1 }
        controller.onInteraction = { interactions.append($0) }
        controller.popUp(with: mouseEvent(), for: NSView()) { _, _, _ in }
        try require(deletions == 0 && interactions == [true, false], "Right-clicking or cancelling deleted a note")
        controller.canDelete = false
        var disabled = false
        controller.popUp(with: mouseEvent(), for: NSView()) { menu, _, _ in
            let index = menu.indexOfItem(withTitle: "Delete Note…")
            disabled = index >= 0 && !menu.items[index].isEnabled
            if index >= 0 { menu.performActionForItem(at: index) }
        }
        try require(disabled && deletions == 0, "A disabled title action deleted a busy note")
    }

    @MainActor private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews { if let result = descendant(type, in: child) { return result } }
        return nil
    }

    @MainActor private static func disabledComposerCannotSend() async throws {
        var sent = 0
        var imported = 0
        let composer = ComposerView(text: .constant("Keep this draft"), focusRequest: UUID(),
                                    onSend: { sent += 1 }, onEscape: {}, onImage: { _ in imported += 1 },
                                    onFiles: { _ in imported += 1 }, onComposition: { _ in })
        let host = NSHostingView(rootView: composer.disabled(true))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if descendant(ChatTextView.self, in: host) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let editor = descendant(ChatTextView.self, in: host) else {
            throw CheckFailure(message: "The production native composer did not mount")
        }
        try require(!editor.isEditable, "SwiftUI disabled state did not disable the native composer")
        editor.paste(nil)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                    isARepeat: false, keyCode: 36)!
        editor.keyDown(with: enter)
        try require(sent == 0 && imported == 0 && editor.string == "Keep this draft",
                    "The disabled composer sent or imported content")
        withExtendedLifetime(host) {}
    }

    @MainActor private static func fixture() -> (URL, AppStore, NoteWindowManager) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-delete-ui-\(UUID())")
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        return (directory, store, NoteWindowManager(store: store))
    }

    @MainActor private static func mountComposer(_ draft: ComposerDraft) async throws -> (NSWindow, ChatTextView) {
        let host = NSHostingView(rootView: UndoComposer(draft: draft))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if let editor = descendant(ChatTextView.self, in: host) {
                window.makeFirstResponder(editor)
                return (window, editor)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.close()
        throw CheckFailure(message: "The production composer did not mount for Undo checks")
    }

    @MainActor private static func type(_ text: String, in editor: ChatTextView) async throws {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        try await settle()
    }

    @MainActor private static func composerUndoSurvivesDraftReplacement() async throws {
        let draft = ComposerDraft()
        let (window, editor) = try await mountComposer(draft)
        defer { window.close() }
        try await type("Already sent", in: editor)
        try require(draft.text == "Already sent" && editor.undoManager?.canUndo == true,
                    "Typing did not update the binding or register Undo")
        try require(editor.tryToPerform(Selector(("undo:")), with: nil), "Native editor did not route Undo")
        try await settle()
        try require(editor.string.isEmpty && draft.text.isEmpty, "Typing Undo failed: editor=\(editor.string.debugDescription), binding=\(draft.text.debugDescription)")
        try require(editor.tryToPerform(Selector(("redo:")), with: nil), "Native editor did not route Redo")
        try await settle()
        try require(editor.string == "Already sent" && draft.text == "Already sent", "Typing Redo failed")

        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: enter)
        try await settle()
        try require(draft.sends == 1 && editor.string.isEmpty, "Send did not clear the mounted editor")
        try require(editor.undoManager?.canUndo == false && editor.undoManager?.canRedo == false,
                    "Send retained stale Undo or Redo actions")
        _ = editor.tryToPerform(Selector(("undo:")), with: nil)
        try require(editor.string.isEmpty, "Undo restored an already-sent message")

        try await type("Next draft", in: editor)
        try require(editor.tryToPerform(Selector(("undo:")), with: nil), "Next draft did not route Undo")
        try await settle()
        try require(editor.string.isEmpty, "Undo in the next draft crossed the send boundary")
        try require(editor.tryToPerform(Selector(("redo:")), with: nil), "Next draft did not route Redo")
        try await settle()
        try require(editor.string == "Next draft", "Redo in the next draft failed")
        draft.text = "Recovered pending text"
        try await settle()
        try require(editor.string == draft.text && editor.undoManager?.canUndo == false && editor.undoManager?.canRedo == false,
                    "Externally recovered text retained stale editing history")
    }

    @MainActor private static func composerUndoIsIsolatedAndPreservesComposition() async throws {
        let first = ComposerDraft(), second = ComposerDraft()
        let (firstWindow, firstEditor) = try await mountComposer(first)
        let (secondWindow, secondEditor) = try await mountComposer(second)
        defer { firstWindow.close(); secondWindow.close() }
        try await type("First note", in: firstEditor)
        try await type("Second note", in: secondEditor)
        try require(firstEditor.undoManager !== secondEditor.undoManager,
                    "Different message editors share an Undo manager")
        second.text = ""
        try await settle()
        try require(firstEditor.undoManager?.canUndo == true && secondEditor.undoManager?.canUndo == false,
                    "Clearing another draft removed this editor's history")
        try require(firstEditor.tryToPerform(Selector(("undo:")), with: nil), "First editor did not route Undo")
        try require(firstEditor.string.isEmpty && secondEditor.string.isEmpty, "Undo changed another editor")

        secondEditor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(secondEditor.hasMarkedText(), "The native marked-text fixture did not start composition")
        second.text = "External replacement"
        try await settle()
        try require(secondEditor.hasMarkedText() && secondEditor.string == "候选",
                    "External draft replacement interrupted active input-method composition")
        secondEditor.unmarkText()
        second.text = "Recovered after composition"
        try await settle()
        try require(secondEditor.string == second.text && secondEditor.undoManager?.canUndo == false,
                    "Draft replacement after composition did not reset Undo")
    }

    @MainActor private static func composerPastePrefersEncodedImages() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // Deliberately malformed bytes must reach the bounded codec unchanged,
        // rather than asking AppKit to decode a pasteboard image first.
        let encoded = Data("malformed image fixture".utf8)
        try require(board.setData(encoded, forType: .png), "Could not create the private image pasteboard")
        let editor = ChatTextView()
        var received: Data?, nativeImages = 0
        editor.onImageData = { received = $0 }
        editor.onImage = { _ in nativeImages += 1 }
        try require(editor.importImages(from: board) && received == encoded && nativeImages == 0,
                    "Composer paste decoded an image before the bounded importer")
    }

    @MainActor private static func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }

    private static func compactResizeGeometryPreservesAnchors() throws {
        let area = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = NSRect(x: 200, y: 200, width: 220, height: 40)
        let edges: [CompactResizeEdges] = [.left, .right, .top, .bottom,
                                         [.left, .top], [.left, .bottom], [.right, .top], [.right, .bottom]]
        for edge in edges {
            for delta in [NSPoint(x: -1000, y: -1000), NSPoint(x: 1000, y: 1000), NSPoint(x: 30, y: 15)] {
                let result = CompactResizeGeometry.resized(frame, edges: edge, delta: delta, within: area)
                try require(area.contains(result) && (160...640).contains(result.width) && (36...160).contains(result.height),
                            "A compact resize exceeded its display or size limits")
                if edge.contains(.left) { try require(result.maxX == frame.maxX, "Left resizing moved its opposite edge") }
                if edge.contains(.right) { try require(result.minX == frame.minX, "Right resizing moved its opposite edge") }
                if edge.contains(.top) { try require(result.minY == frame.minY, "Top resizing moved its opposite edge") }
                if edge.contains(.bottom) { try require(result.maxY == frame.maxY, "Bottom resizing moved its opposite edge") }
            }
        }
        try require(CompactResizeGeometry.edges(at: NSPoint(x: 110, y: 20), in: NSRect(x: 0, y: 0, width: 220, height: 40)).isEmpty,
                    "The resize perimeter intercepts the title center")
        try require(CompactResizeGeometry.edges(at: NSPoint(x: 8, y: 8), in: NSRect(x: 0, y: 0, width: 220, height: 40)) == [.left, .bottom],
                    "Corner resizing does not win over edge dragging")
    }

    @MainActor private static func compactFixture() async throws -> (URL, AppStore, NoteWindowManager, NoteState, NSWindow, CompactResizeHandle) {
        let (directory, store, manager) = fixture()
        let note = store.createNote(title: "Compact resize fixture \(UUID())", model: "fictional-model", effort: "medium")
        let screen = NSScreen.screens[0].visibleFrame
        note.compactX = screen.midX - 110
        note.compactY = screen.midY + 100
        manager.restore()
        try await settle()
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == note.title }),
              let content = panel.contentView, let handle = descendant(CompactResizeHandle.self, in: content) else {
            throw CheckFailure(message: "The real compact resize overlay did not mount")
        }
        return (directory, store, manager, note, panel, handle)
    }

    @MainActor private static func resizeEvent(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @MainActor private static func beginResize(_ handle: CompactResizeHandle, panel: NSWindow, delta: NSPoint) throws -> NSPoint {
        let local = NSPoint(x: handle.bounds.maxX - 3, y: handle.bounds.minY + 3)
        let point = handle.convert(local, to: nil)
        let content = panel.contentView!
        let target = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        try require(target === handle, "The compact drag background steals an edge resize click")
        let end = NSPoint(x: panel.convertPoint(toScreen: point).x + delta.x,
                          y: panel.convertPoint(toScreen: point).y + delta.y)
        handle.mouseDown(with: resizeEvent(.leftMouseDown, point: point, window: panel))
        handle.mouseDragged(with: resizeEvent(.leftMouseDragged, point: panel.convertPoint(fromScreen: end), window: panel))
        return end
    }

    @MainActor private static func compactResizeKeepsFocusAndIndependentSizes() async throws {
        let (directory, store, manager, note, panel, handle) = try await compactFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = panel.frame
        let previousKey = NSApplication.shared.keyWindow
        try require(!panel.isKeyWindow && !handle.acceptsFirstResponder && !handle.needsPanelToBecomeKey,
                    "The compact resize handle requests keyboard focus")
        let end = try beginResize(handle, panel: panel, delta: NSPoint(x: 120, y: -30))
        try require(panel.frame.size == NSSize(width: 340, height: 70) && note.compactWidth == 220,
                    "Live resizing failed or saved partial dimensions before mouseUp")
        handle.mouseUp(with: resizeEvent(.leftMouseUp, point: panel.convertPoint(fromScreen: end), window: panel))
        try await settle()
        try require(!note.isExpanded && !panel.isKeyWindow && NSApplication.shared.keyWindow === previousKey,
                    "Resizing expanded the note or stole keyboard focus")
        try require(note.compactWidth == 340 && note.compactHeight == 70 && note.expandedWidth == 500 && note.expandedHeight == 640,
                    "Compact and expanded sizes were mixed")
        try require(panel.frame.minX == original.minX && panel.frame.maxY == original.maxY,
                    "Bottom-right resizing moved its opposite corner")
        manager.show(note: note)
        try await settle()
        manager.hide(note: note)
        manager.showAll()
        try await settle()
        try require(panel.frame.size == NSSize(width: 340, height: 70) && panel.frame.minX == original.minX && panel.frame.maxY == original.maxY,
                    "Expand/collapse lost the compact size or anchor")
        let saved = try NotePersistence(directory: directory).load()
        try require(saved.notes.first?.compactWidth == 340 && saved.notes.first?.compactHeight == 70,
                    "The resized compact dimensions were not persisted")
        let restored = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(restored.notes.first?.compactWidth == 340 && restored.notes.first?.compactHeight == 70,
                    "Restart lost the compact size")
        await restored.shutdown()
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func compactResizeResetAndHideDuringGesture() async throws {
        let (directory, store, manager, note, panel, handle) = try await compactFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try beginResize(handle, panel: panel, delta: NSPoint(x: 100, y: -40))
        manager.hide(note: note)
        try await settle()
        try require(!note.isVisible && !panel.isVisible && note.compactWidth == 320 && note.compactHeight == 80,
                    "Hiding during resize lost the current dimensions or reopened the panel")
        manager.showAll()
        try await settle()
        let beforeReset = panel.frame
        func titles(_ view: NSView) -> [NoteTitleField] {
            (view as? NoteTitleField).map { [$0] } ?? view.subviews.flatMap(titles)
        }
        guard let title = titles(panel.contentView!).first(where: { $0.titleContextMenu.onResetSize != nil }) else {
            throw CheckFailure(message: "The compact title does not offer Reset Size")
        }
        var resetFound = false
        title.titleContextMenu.popUp(with: mouseEvent(), for: title) { menu, _, _ in
            let index = menu.indexOfItem(withTitle: "Reset Size")
            resetFound = index >= 0
            if index >= 0 { menu.performActionForItem(at: index) }
        }
        try await settle()
        try require(resetFound && panel.frame.size == NSSize(width: 220, height: 40) && panel.frame.maxY == beforeReset.maxY,
                    "Reset Size failed to restore the default at the same top edge")
        try require(note.expandedWidth == 500 && note.expandedHeight == 640 && !panel.isKeyWindow,
                    "Reset Size changed the expanded dimensions or focused the note")
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func resizedTitleKeepsClickAndRenameBehavior() async throws {
        let (directory, store, manager, note, panel, handle) = try await compactFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let end = try beginResize(handle, panel: panel, delta: NSPoint(x: 100, y: -30))
        handle.mouseUp(with: resizeEvent(.leftMouseUp, point: panel.convertPoint(fromScreen: end), window: panel))
        try await settle()
        func visibleTitle(_ view: NSView) -> NoteTitleField? {
            if let title = view as? NoteTitleField, title.frame.width < 360 && title.titleContextMenu.onResetSize != nil { return title }
            for child in view.subviews { if let result = visibleTitle(child) { return result } }
            return nil
        }
        guard let title = visibleTitle(panel.contentView!) else { throw CheckFailure(message: "The resized title is missing") }
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        let content = panel.contentView!
        try require(content.hitTest(content.superview?.convert(point, from: nil) ?? point) === title,
                    "The compact resize overlay intercepts a title-center click")
        title.mouseDown(with: resizeEvent(.leftMouseDown, point: point, window: panel))
        title.mouseUp(with: resizeEvent(.leftMouseUp, point: point, window: panel))
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(!note.isExpanded, "The title click no longer respects its 100 ms interval")
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(note.isExpanded, "The resized title no longer expands promptly")
        manager.hide(note: note)
        manager.showAll()
        try await settle()
        // This is a separate gesture after the programmatic hide/show. A real
        // menu click would cancel the earlier single-click arbitration monitor.
        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.05) * 1_000_000_000))
        guard let renamed = visibleTitle(panel.contentView!) else { throw CheckFailure(message: "The compact title did not return") }
        let renamePoint = renamed.convert(NSPoint(x: renamed.bounds.midX, y: renamed.bounds.midY), to: nil)
        renamed.mouseDown(with: resizeEvent(.leftMouseDown, point: renamePoint, window: panel, clicks: 2))
        try await settle()
        try require(renamed.isEditable, "Double-clicking a resized title no longer starts renaming")
        manager.finishTitleEditingAll()
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func click(_ point: NSPoint, in window: NSWindow) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                guard let content = window.contentView,
                      let target = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else {
                    continuation.resume(); return
                }
                if target is NSButton { NSApplication.shared.postEvent(up, atStart: true) }
                target.mouseDown(with: down)
                if !(target is NSButton) { target.mouseUp(with: up) }
                // Native NSButtons consume mouseUp during tracking; SwiftUI
                // actions leave it in the event queue for normal dispatch.
                if let next = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                    target.mouseUp(with: next)
                }
                continuation.resume()
            }
        }
    }

    @MainActor private static func headerHideAcceptsClicksAroundItsSymbol() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Header hit fixture \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == note.title }),
              let content = panel.contentView,
              let hide = descendants(content).first(where: { $0.accessibilityLabel() == "Hide Note" }) as? NoteHeaderButton.Button else {
            throw CheckFailure(message: "Could not find the production Hide Note accessibility element")
        }
        let buttons = descendants(content).compactMap { $0 as? NoteHeaderButton.Button }
        try require(buttons.count == 3 && buttons.allSatisfy { $0.bounds.width >= 28 && $0.bounds.height >= 28 },
                    "A header action has a hit area smaller than 28×28 points: \(buttons.map { "\($0.accessibilityLabel() ?? "?"): \($0.bounds.size)" })")
        try require(buttons.allSatisfy { !$0.mouseDownCanMoveWindow && $0.acceptsFirstMouse(for: nil) },
                    "A header action permits background dragging or rejects the first click")
        for offset in [NSPoint(x: 0, y: 9), NSPoint(x: 9, y: 9), NSPoint(x: -9, y: 9),
                       NSPoint(x: 9, y: -9), NSPoint(x: -9, y: -9)] {
            manager.show(note: note)
            try await settle()
            panel.resignKey()
            let frame = hide.convert(hide.bounds, to: nil)
            await click(NSPoint(x: frame.midX + offset.x, y: frame.midY + offset.y), in: panel)
            try await settle()
            try require(!note.isVisible && !panel.isVisible,
                        "An off-symbol minus click missed Hide Note at offset \(offset)")
            try require(store.notes.contains(where: { $0.id == note.id }), "The Hide action deleted its note")
        }
        manager.show(note: note)
        try await settle()
        guard let collapse = buttons.first(where: { $0.accessibilityLabel() == "Collapse Note" }),
              let delete = buttons.first(where: { $0.accessibilityLabel() == "Delete Note" }) else {
            throw CheckFailure(message: "The header lost its collapse or delete control")
        }
        let collapseFrame = collapse.convert(collapse.bounds, to: nil)
        await click(NSPoint(x: collapseFrame.midX - 9, y: collapseFrame.midY + 9), in: panel)
        try await settle()
        try require(!note.isExpanded && note.isVisible && panel.isVisible,
                    "The collapse control hid the note or missed its off-symbol click")
        manager.show(note: note)
        try await settle()
        let cancel = ConfirmationDriver(choice: "Cancel")
        cancel.start()
        let deleteFrame = delete.convert(delete.bounds, to: nil)
        await click(NSPoint(x: deleteFrame.midX + 9, y: deleteFrame.midY - 9), in: panel)
        cancel.stop()
        try require(cancel.foundDialog && store.notes.contains(where: { $0.id == note.id }),
                    "The delete control missed its off-symbol click or bypassed confirmation")
        store.notes.removeAll { $0.id == note.id }
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func titleMenuHidesCompactAndExpandedNotes() async throws {
        try require(!NSScreen.screens.isEmpty, "Native title-menu checks require macOS window-server access")
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Hide-menu fixture \(UUID())", model: "fictional-model", effort: "medium")
        for expanded in [false, true] {
            if expanded { manager.show(note: note) } else { manager.restore() }
            try await settle()
            guard let panel = NSApplication.shared.windows.first(where: { $0.title == note.title }),
                  let title = descendant(NoteTitleField.self, in: panel.contentView!) else {
                throw CheckFailure(message: "The title context-menu fixture did not mount")
            }
            var didTrack = false
            var wasDeferred = false
            // Use the menu attached to the real title field, including its
            // production window-manager hide closure and interaction lock.
            title.titleContextMenu.popUp(with: mouseEvent(), for: title) { menu, _, _ in
                let index = menu.indexOfItem(withTitle: "Hide Note")
                didTrack = index >= 0 && menu.items[index].isEnabled
                if index >= 0 { menu.performActionForItem(at: index) }
                wasDeferred = note.isVisible
            }
            try await settle()
            try require(didTrack && wasDeferred && !note.isVisible && !panel.isVisible,
                        "The title menu did not hide the \(expanded ? "expanded" : "compact") note after tracking")
            try require(store.notes.contains(where: { $0.id == note.id }) && !note.deletionPending,
                        "Hide Note removed or marked the note for deletion")
        }
        store.notes.removeAll { $0.id == note.id }
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func chooseConfirmation(_ choice: String, store: AppStore, note: NoteState,
                                                      exerciseReturn: Bool = false) async -> ConfirmationDriver {
        await withCheckedContinuation { continuation in
            // Real button actions enter AppKit from its event loop. Invoking a
            // nested modal loop directly inside Swift's async main task can
            // corrupt that task's executor state on macOS 14 / Swift 5.10.
            DispatchQueue.main.async {
                let driver = ConfirmationDriver(choice: choice, exerciseReturn: exerciseReturn)
                driver.start()
                store.requestDeleteNote(note)
                driver.stop()
                continuation.resume(returning: driver)
            }
        }
    }

    @MainActor private static func confirmationRequiresExplicitDeletionChoice() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Example note", model: "fictional-model", effort: "medium")
        let cancel = await chooseConfirmation("Cancel", store: store, note: note)
        try await settle()
        try require(cancel.foundDialog, "The real deletion confirmation did not appear")
        try require(cancel.safeKeyboardCancellation, "The confirmation lacks safe keyboard cancellation (\(cancel.buttonDiagnostics))")
        try require(cancel.deleteIsDestructive, "Delete Note is not marked as destructive in the confirmation")
        try require(cancel.captured, "Could not capture the fictional deletion confirmation for visual review")
        try require(store.notes.contains(where: { $0.id == note.id }) && !note.deletionPending && !note.isDeleting,
                    "Cancelling the real confirmation removed or marked the note for deletion")
        let saved = try NotePersistence(directory: directory).load()
        try require(saved.notes.contains(where: { $0.id == note.id && $0.deletionPending != true }),
                    "Cancelling the confirmation wrote a deletion journal")
        let enter = await chooseConfirmation("Cancel", store: store, note: note, exerciseReturn: true)
        try await settle()
        try require(enter.exercisedReturn && store.notes.contains(where: { $0.id == note.id }) && !note.deletionPending,
                    "Pressing Return in the real confirmation triggered destructive deletion")
        let delete = await chooseConfirmation("Delete Note", store: store, note: note)
        try await settle()
        try require(delete.foundDialog && !store.notes.contains(where: { $0.id == note.id }),
                    "Choosing Delete Note in the real confirmation did not delete the note")
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func hidingAndDeletingHaveDifferentLifecycles() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = "Delete UI fixture \(UUID())"
        let note = store.createNote(title: title, model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == title }) else {
            throw CheckFailure(message: "The fixture note did not create its native panel")
        }
        manager.hide(note: note)
        try require(!panel.isVisible && store.notes.contains(where: { $0.id == note.id }), "Hide removed the note")
        manager.show(note: note)
        try require(panel.isVisible, "A hidden note could not reopen")
        await store.deleteNote(note)
        try await settle()
        try require(!store.notes.contains(where: { $0.id == note.id }), "Confirmed deletion kept the empty note")
        try require(!panel.isVisible && panel.contentView == nil && panel.delegate == nil,
                    "Deleted note retained a live native panel or subscriptions")
        manager.show(note: note)
        try await settle()
        try require(!panel.isVisible && panel.contentView == nil, "A stale show request resurrected a deleted panel")
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func queuedCreationCannotResurrectDeletedPanel() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = "Queued deletion fixture \(UUID())"
        let note = store.createNote(title: title, model: "fictional-model", effort: "medium")
        // Both @Published observer tasks are queued before the run loop resumes.
        store.notes.removeAll { $0.id == note.id }
        try await settle()
        try require(!NSApplication.shared.windows.contains(where: { $0.title == title && $0.isVisible }),
                    "A queued notes publication resurrected a removed note")
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func failedDeletionKeepsPanelAndHistoryReference() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = "Failed deletion fixture \(UUID())"
        let note = store.createNote(title: title, model: "fictional-model", effort: "medium")
        note.threadID = "unconnected-fixture-thread"
        manager.show(note: note)
        try await settle()
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == title }) else {
            throw CheckFailure(message: "The failure fixture did not create its native panel")
        }
        await store.deleteNote(note)
        try await settle()
        try require(store.notes.contains(where: { $0.id == note.id }) && note.threadID == "unconnected-fixture-thread",
                    "Failed backend deletion discarded the note or its original history reference")
        try require(panel.isVisible && panel.contentView != nil && panel.delegate != nil && note.error != nil,
                    "Failed deletion closed the panel or did not display its error")
        store.notes.removeAll { $0.id == note.id }
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }
}
