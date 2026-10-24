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
            if ProcessInfo.processInfo.environment["FLOATING_AI_SHORTCUTS_ONLY"] == "1" {
                try await shortcutRecorderCapturesAndCancels()
                print("PASS: native shortcut recorder and settings preview")
                exit(0)
            }
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
            try await keepExpandedPreferencePersistsAndDefaults()
            try await settingsKeepExpandedToggleUpdatesPreference()
            try await focusLossObeysKeepExpandedPreference()
            try await keepExpandedPreservesOtherNotesAndCancelsQueuedCollapse()
            try await keepExpandedAllowsExplicitCollapseAndHide()
            try await recentNoteShortcutRecallsHiddenAndFallsBack()
            try await recentNoteTrackingIgnoresPassivePresentation()
            try await keepExpandedShortcutRespectsFocusAndConfiguration()
            try await hideAndDeleteShortcutsActOnFocusedNote()
            try await recentNoteShortcutCollapsesOnlyFocusedNote()
            try await noteShortcutsPreserveCompositionAndSheets()
            try await shortcutRecorderCapturesAndCancels()
            try await shortcutSettingsRejectConflictsAndPersist()
            try await shortcutSaveFailureRollsBackOrDisablesRegistration()
            print("PASS: 30 native note-action UI checks")
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

    @MainActor private static func keepExpandedPreferencePersistsAndDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-keep-expanded-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(!fresh.keepNotesExpanded, "A new installation unexpectedly disables automatic collapse")
        await fresh.shutdown()
        let persistence = NotePersistence(directory: directory)
        let legacy = Data(#"{"version":1,"cliPath":"","defaultModelID":"","defaultEffort":"","notes":[]}"#.utf8)
        try legacy.write(to: persistence.documentURL, options: .atomic)
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(!store.keepNotesExpanded, "A legacy document changed the default collapse behavior")
        store.keepNotesExpanded = true
        try await Task.sleep(nanoseconds: 400_000_000)
        let enabledDocument = try persistence.load()
        try require(enabledDocument.keepNotesExpanded == true, "Enabling Keep Notes Expanded was not autosaved")
        let restored = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(restored.keepNotesExpanded, "Restart lost Keep Notes Expanded")
        await restored.shutdown()
        store.keepNotesExpanded = false
        try await Task.sleep(nanoseconds: 400_000_000)
        let disabledDocument = try persistence.load()
        try require(disabledDocument.keepNotesExpanded == false, "Disabling Keep Notes Expanded was not autosaved")
        await store.shutdown()
    }

    @MainActor private static func fixturePanel(for note: NoteState) throws -> NSWindow {
        guard let panel = NSApplication.shared.windows.first(where: { $0.title == note.title }) else {
            throw CheckFailure(message: "The Keep Notes Expanded fixture panel did not mount")
        }
        return panel
    }

    @MainActor private static func settingsKeepExpandedToggleUpdatesPreference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-settings-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        let host = NSHostingView(rootView: SettingsView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        try await settle()
        host.layoutSubtreeIfNeeded()
        func checkboxes(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton, let parent = button.superview,
               String(describing: Swift.type(of: parent)).contains("Checkbox") { return [button] }
            return view.subviews.flatMap { checkboxes(in: $0) }
        }
        let buttons = checkboxes(in: host)
        // The Settings view has one native checkbox; SwiftUI draws its label.
        try require(buttons.count == 1, "Settings did not expose its Keep Notes Expanded checkbox")
        let toggle = buttons[0]
        try require(toggle.state == .off && !store.keepNotesExpanded, "Settings showed the wrong initial preference")
        toggle.scrollToVisible(toggle.bounds)
        host.layoutSubtreeIfNeeded()
        // SwiftUI's native checkbox updates its binding through mouse handling;
        // NSButton.performClick can change only its cell state on macOS 14.
        let point = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        await click(point, in: window)
        try await settle()
        try require(store.keepNotesExpanded && toggle.state == .on, "The Settings checkbox did not enable Keep Notes Expanded")
        await click(point, in: window)
        try await settle()
        try require(!store.keepNotesExpanded && toggle.state == .off, "The Settings checkbox did not disable Keep Notes Expanded")
        await store.shutdown()
    }

    @MainActor private static func resignWithoutSchedulingCollapse(_ panel: NSWindow) {
        // Isolate each notification/monitor from the independent resign-key path.
        let delegate = panel.delegate
        panel.delegate = nil
        panel.resignKey()
        panel.delegate = delegate
    }

    @MainActor private static func postOutsideClick(in window: NSWindow) {
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: NSPoint(x: 10, y: 10),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }

    @MainActor private static func focusLossObeysKeepExpandedPreference() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Blur fixture \(UUID())", model: "fictional-model", effort: "medium")
        let outside = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 80, height: 60),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        outside.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        defer { outside.close() }
        for enabled in [false, true] {
            store.keepNotesExpanded = enabled
            for trigger in ["window resign", "outside click", "app deactivate"] {
                manager.show(note: note)
                try await settle()
                let panel = try fixturePanel(for: note)
                try require(note.isExpanded, "The blur fixture did not expand")
                if trigger == "window resign" {
                    panel.resignKey()
                } else {
                    resignWithoutSchedulingCollapse(panel)
                    if trigger == "outside click" { postOutsideClick(in: outside) }
                    else { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared) }
                }
                try await Task.sleep(nanoseconds: 350_000_000)
                try require(note.isExpanded == enabled,
                            "\(trigger) ignored Keep Notes Expanded = \(enabled)")
            }
        }
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func keepExpandedPreservesOtherNotesAndCancelsQueuedCollapse() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = store.createNote(title: "First open fixture \(UUID())", model: "fictional-model", effort: "medium")
        let second = store.createNote(title: "Second open fixture \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: first)
        try await settle()
        manager.show(note: second)
        try await settle()
        try require(!first.isExpanded && second.isExpanded, "The default mode stopped collapsing the previous note")
        manager.show(note: first)
        try await settle()
        let panel = try fixturePanel(for: first)
        panel.resignKey() // Queues the existing 180 ms automatic collapse.
        store.keepNotesExpanded = true
        try await settle()
        try require(first.isExpanded, "Enabling Keep Notes Expanded failed to cancel an already queued collapse")
        manager.show(note: second)
        try await settle()
        try require(first.isExpanded && second.isExpanded, "Opening another note collapsed an expanded note with the option enabled")
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func keepExpandedAllowsExplicitCollapseAndHide() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.keepNotesExpanded = true
        let note = store.createNote(title: "Explicit collapse fixture \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        let panel = try fixturePanel(for: note)
        func expandedTitle(in view: NSView) -> NoteTitleField? {
            if let title = view as? NoteTitleField, title.onSingleClickPreservingHeader != nil { return title }
            return view.subviews.compactMap { expandedTitle(in: $0) }.first
        }
        guard let title = expandedTitle(in: panel.contentView!) else {
            throw CheckFailure(message: "The expanded title control is missing")
        }
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        title.mouseDown(with: resizeEvent(.leftMouseDown, point: point, window: panel))
        title.mouseUp(with: resizeEvent(.leftMouseUp, point: point, window: panel))
        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.3) * 1_000_000_000))
        try require(!note.isExpanded && note.isVisible, "Keep Notes Expanded blocked an explicit title collapse")
        manager.show(note: note)
        try await settle()
        panel.cancelOperation(nil)
        try await settle()
        try require(!note.isExpanded && note.isVisible, "Keep Notes Expanded blocked Escape")
        manager.show(note: note)
        try await settle()
        manager.hide(note: note)
        try require(!note.isExpanded && !note.isVisible && !panel.isVisible,
                    "Keep Notes Expanded blocked Hide Note")
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func shortcutEvent(in window: NSWindow, keyCode: UInt16 = 40,
                                                flags: NSEvent.ModifierFlags = [.command, .option],
                                                repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: keyCode == 40 ? "k" : "j", charactersIgnoringModifiers: keyCode == 40 ? "k" : "j",
                         isARepeat: repeatKey, keyCode: keyCode)!
    }

    @MainActor private static func recentNoteShortcutRecallsHiddenAndFallsBack() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try require(!manager.showMostRecentNote(), "An empty store did not request the new-note flow")
        let first = store.createNote(title: "Recent first \(UUID())", model: "fictional-model", effort: "medium")
        let second = store.createNote(title: "Recent second \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: first)
        try await settle()
        manager.show(note: second)
        try await settle()
        manager.show(note: first)
        try await settle()
        let firstPanel = try fixturePanel(for: first)
        try require(store.recentNoteIDs.prefix(2) == [first.id, second.id], "Explicit use did not maintain most-recent order")
        manager.hide(note: first)
        try require(manager.showMostRecentNote(), "The most recently used hidden note was not recalled")
        try await settle()
        try require(first.isExpanded && first.isVisible && firstPanel.isKeyWindow,
                    "Recall did not expand and focus the hidden note")
        let focusBefore = first.focusRequest
        try require(manager.showMostRecentNote(), "An already open recent note was not handled")
        try await settle()
        try require(first.focusRequest != focusBefore && NSApp.windows.filter { $0.title == first.title }.count == 1,
                    "Recall duplicated the panel or did not refocus its composer")
        await store.deleteNote(first)
        try await settle()
        try require(manager.showMostRecentNote(), "Deleting the most recent note lost the previous-note fallback")
        try await settle()
        try require(second.isExpanded && second.isVisible, "Recall did not fall back to the remaining note")
        second.deletionPending = true
        try require(manager.showMostRecentNote(), "An incomplete deletion incorrectly requested another new note")
        store.notes.removeAll()
        try await settle()
        try require(!manager.showMostRecentNote(), "Stale recent IDs reopened a deleted note")
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func recentNoteTrackingIgnoresPassivePresentation() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = store.createNote(title: "Passive first \(UUID())", model: "fictional-model", effort: "medium")
        let second = store.createNote(title: "Passive second \(UUID())", model: "fictional-model", effort: "medium")
        store.recentNoteIDs = []
        manager.restore()
        try await settle()
        manager.showAll()
        first.hasUnreadReply = true
        try await settle()
        try require(store.recentNoteIDs.isEmpty, "Restore, Show All, or background updates changed recent-note ordering")
        manager.show(note: second)
        try await settle()
        let expected = store.recentNoteIDs
        manager.hideAll()
        manager.showAll()
        try await settle()
        try require(store.recentNoteIDs == expected, "Show All selected notes in presentation order")
        try require(store.persist(), "The recent-note fixture could not save")
        let restored = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(restored.recentNoteIDs.first == second.id, "The last actively used note was forgotten after restart")
        await restored.shutdown()
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func keepExpandedShortcutRespectsFocusAndConfiguration() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Local shortcut \(UUID())", model: "fictional-model", effort: "medium")
        note.draft = "Do not change this draft"
        manager.show(note: note)
        try await settle()
        let panel = try fixturePanel(for: note)
        try require(panel.isKeyWindow, "The local shortcut fixture did not acquire keyboard focus")
        let key = shortcutEvent(in: panel)
        try require(panel.performKeyEquivalent(with: key) && store.keepNotesExpanded,
                    "Cmd-Option-K did not toggle the shared Keep Notes Expanded setting")
        try require(note.shortcutNotice == "Keep Notes Expanded: On", "The local toggle did not report its new state")
        try require(panel.performKeyEquivalent(with: shortcutEvent(in: panel, repeatKey: true)) && store.keepNotesExpanded,
                    "Holding the shortcut repeatedly toggled the setting")
        panel.sendEvent(key)
        try require(!store.keepNotesExpanded && note.shortcutNotice == "Keep Notes Expanded: Off",
                    "A note-panel key event did not toggle the same setting")
        store.isRecordingShortcut = true
        _ = panel.performKeyEquivalent(with: key)
        try require(!store.keepNotesExpanded, "The note shortcut fired during shortcut recording")
        store.isRecordingShortcut = false
        store.keyboardShortcuts.toggleKeepOpen = nil
        _ = panel.performKeyEquivalent(with: key)
        try require(!store.keepNotesExpanded, "Disabling the local shortcut left it active")
        store.keyboardShortcuts.toggleKeepOpen = FloatingAICore.KeyboardShortcut(keyCode: 38, modifiers: UInt32(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        _ = panel.performKeyEquivalent(with: key)
        try require(!store.keepNotesExpanded, "Changing the local shortcut retained the old combination")
        try require(panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 38, flags: [.command, .shift])) && store.keepNotesExpanded,
                    "The customized local shortcut did not take effect")
        panel.resignKey()
        _ = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 38, flags: [.command, .shift]))
        try require(store.keepNotesExpanded, "An unfocused note handled the local shortcut")
        try require(note.draft == "Do not change this draft", "A shortcut modified the message draft")
        try await Task.sleep(nanoseconds: 2_600_000_000)
        try require(note.shortcutNotice == nil, "Shortcut feedback did not dismiss itself")
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func hideAndDeleteShortcutsActOnFocusedNote() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Hide delete shortcut \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        let panel = try fixturePanel(for: note)
        try require(panel.isKeyWindow, "The hide/delete shortcut fixture did not acquire keyboard focus")
        try require(panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 46, repeatKey: true)) && note.isVisible,
                    "A held Cmd-Option-M hid the note from a repeated key")
        try require(panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 46)) && !note.isVisible && !panel.isVisible,
                    "Cmd-Option-M did not hide the focused note")
        try require(store.notes.contains(where: { $0.id == note.id }), "Hiding by shortcut removed the note")
        manager.show(note: note)
        try await settle()
        panel.resignKey()
        _ = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 46))
        try require(note.isVisible, "An unfocused note handled the hide shortcut")
        store.keyboardShortcuts.hideNote = nil
        manager.show(note: note)
        try await settle()
        try require(!panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 46)) && note.isVisible,
                    "A disabled hide shortcut still hid the note")

        // The real confirmation runs; a stray or repeated key must not open it.
        var handled = false
        let repeated = await chooseConfirmation("Cancel", store: store, note: note) {
            handled = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 51, repeatKey: true))
        }
        try require(handled && !repeated.foundDialog, "A held Cmd-Option-Delete opened the deletion confirmation")
        let cancel = await chooseConfirmation("Cancel", store: store, note: note) {
            handled = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 51))
        }
        try await settle()
        try require(handled && cancel.foundDialog && store.notes.contains(where: { $0.id == note.id }) && !note.deletionPending,
                    "Cmd-Option-Delete skipped the confirmation, or Cancel deleted the note")
        store.keyboardShortcuts.deleteNote = nil
        manager.show(note: note)
        try await settle()
        let disabled = await chooseConfirmation("Cancel", store: store, note: note) {
            handled = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 51))
        }
        try require(!handled && !disabled.foundDialog, "A disabled delete shortcut still asked to delete the note")
        store.keyboardShortcuts.deleteNote = .deleteNote
        manager.show(note: note)
        try await settle()
        try require(panel.isKeyWindow, "The note did not regain focus after cancelling deletion")
        let delete = await chooseConfirmation("Delete Note", store: store, note: note) {
            handled = panel.performKeyEquivalent(with: shortcutEvent(in: panel, keyCode: 51))
        }
        try await settle()
        try require(handled && delete.foundDialog && !store.notes.contains(where: { $0.id == note.id }),
                    "Confirming Cmd-Option-Delete did not delete the focused note")
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func recentNoteShortcutCollapsesOnlyFocusedNote() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try require(!manager.collapseFocusedNote(), "Collapse reported success without any note")
        let note = store.createNote(title: "Collapse shortcut \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        let panel = try fixturePanel(for: note)
        try require(panel.isKeyWindow && note.isExpanded, "The collapse fixture did not focus an expanded note")
        try require(manager.collapseFocusedNote() && !note.isExpanded && note.isVisible,
                    "The global shortcut did not collapse the focused, expanded note")
        try await settle()
        try require(!manager.collapseFocusedNote(), "A collapsed note was collapsed again instead of reopened")

        // Kept expanded but unfocused: the shortcut jumps back instead of collapsing.
        store.keepNotesExpanded = true
        manager.show(note: note)
        try await settle()
        panel.resignKey()
        try await settle()
        try require(note.isExpanded && !manager.collapseFocusedNote() && note.isExpanded,
                    "An unfocused, expanded note collapsed instead of being refocused")
        try require(manager.showMostRecentNote(), "The unfocused note was not recalled")
        try await settle()
        try require(panel.isKeyWindow && note.isExpanded, "The shortcut did not jump back to the unfocused note")

        guard let content = panel.contentView, let editor = descendant(ChatTextView.self, in: content) else {
            throw CheckFailure(message: "The collapse fixture did not mount its editor")
        }
        panel.makeFirstResponder(editor)
        editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = manager.collapseFocusedNote()
        try require(note.isExpanded && editor.hasMarkedText(), "Collapsing by shortcut discarded input-method composition")
        editor.unmarkText()
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func noteShortcutsPreserveCompositionAndSheets() async throws {
        let (directory, store, manager) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = store.createNote(title: "Protected shortcut \(UUID())", model: "fictional-model", effort: "medium")
        manager.show(note: note)
        try await settle()
        let panel = try fixturePanel(for: note)
        guard let content = panel.contentView, let editor = descendant(ChatTextView.self, in: content) else {
            throw CheckFailure(message: "The shortcut composition fixture did not mount its editor")
        }
        panel.makeFirstResponder(editor)
        editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(editor.hasMarkedText(), "The shortcut fixture did not enter marked-text composition")
        _ = panel.performKeyEquivalent(with: shortcutEvent(in: panel))
        try require(!store.keepNotesExpanded && editor.hasMarkedText(), "The toggle interfered with active input-method composition")
        let focusBefore = note.focusRequest
        try require(manager.showMostRecentNote(), "Recall did not handle a note with active composition")
        try require(editor.hasMarkedText() && panel.firstResponder === editor && note.focusRequest == focusBefore,
                    "Recalling an open note discarded composition or redirected its editor")
        editor.unmarkText()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        panel.beginSheet(sheet, completionHandler: { _ in })
        try await settle()
        _ = panel.performKeyEquivalent(with: shortcutEvent(in: panel))
        try require(!store.keepNotesExpanded, "The shortcut toggled a setting behind an attached sheet")
        try require(manager.showMostRecentNote() && panel.attachedSheet === sheet,
                    "Recall dismissed or bypassed an attached sheet")
        panel.endSheet(sheet)
        sheet.close()
        store.notes.removeAll()
        try await settle()
        await store.shutdown()
        withExtendedLifetime(manager) {}
    }

    @MainActor private static func shortcutRecorderCapturesAndCancels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-shortcut-recorder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        var configurations = 0
        store.configureKeyboardShortcuts = { _ in configurations += 1 }
        store.openNoteShortcutActive = true // Visual state only; registration remains faked.
        let host = NSHostingView(rootView: ShortcutSettingsView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 448, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setContentSize(NSSize(width: 448, height: 320))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle()
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CheckFailure(message: "The shortcut settings preview could not allocate its bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(message: "The shortcut settings preview could not encode PNG")
        }
        let preview = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/preview-shortcuts.png")
        try png.write(to: preview, options: .atomic)
        guard let recorder = descendant(ShortcutRecorderButton.self, in: host) else {
            throw CheckFailure(message: "The native shortcut recorder did not mount")
        }
        recorder.performClick(nil)
        try require(recorder.isRecording && store.isRecordingShortcut, "Clicking a shortcut did not enter recording mode")
        NSApp.postEvent(shortcutEvent(in: window, keyCode: 38, flags: [.command, .shift]), atStart: false)
        NSApp.postEvent(shortcutEvent(in: window, keyCode: 38, flags: [.command, .shift], repeatKey: true), atStart: false)
        try await settle()
        try require(recorder.isRecording && store.isRecordingShortcut && configurations == 0 && store.keyboardShortcuts.openNote == .openNote,
                    "Recording activated a shortcut while its key was still held")
        NSApp.postEvent(shortcutEvent(in: window, keyCode: 38, flags: [], type: .keyUp), atStart: false)
        try await settle()
        let custom = FloatingAICore.KeyboardShortcut(keyCode: 38, modifiers: UInt32(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        try require(!recorder.isRecording && !store.isRecordingShortcut && store.keyboardShortcuts.openNote == custom && configurations == 1,
                    "Recording did not capture a real key event and restore normal shortcut handling")
        recorder.performClick(nil)
        NSApp.postEvent(shortcutEvent(in: window), atStart: false)
        NSApp.postEvent(shortcutEvent(in: window, keyCode: 53, flags: []), atStart: false)
        try await settle()
        try require(!recorder.isRecording && !store.isRecordingShortcut && store.keyboardShortcuts.openNote == custom && configurations == 1,
                    "Escape did not cancel recording without changing the shortcut")
        recorder.performClick(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(!recorder.isRecording && !store.isRecordingShortcut, "Losing Settings focus left shortcut recording active")
        recorder.performClick(nil)
        host.removeFromSuperview()
        window.contentView = nil
        try await settle()
        try require(!store.isRecordingShortcut, "Closing the recorder left global shortcuts suspended")
        await store.shutdown()
    }

    @MainActor private static func shortcutSettingsRejectConflictsAndPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-shortcut-preferences-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = NotePersistence(directory: directory)
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        let initial = store.keyboardShortcuts
        var duplicate = initial
        duplicate.toggleKeepOpen = duplicate.openNote
        do {
            try ShortcutSettingsValidation.validate(duplicate, menu: nil)
            throw CheckFailure(message: "The two note actions accepted identical shortcuts")
        } catch is ShortcutSettingsValidation.Failure {}
        var localDuplicate = initial
        localDuplicate.deleteNote = localDuplicate.hideNote
        do {
            try ShortcutSettingsValidation.validate(localDuplicate, menu: nil)
            throw CheckFailure(message: "Hide Note and Delete Note accepted identical shortcuts")
        } catch let failure as ShortcutSettingsValidation.Failure {
            try require(failure.message.contains("Delete Note and Hide Note"), "The duplicate message did not name both actions")
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Fixture existing action", action: nil, keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(item)
        do {
            try ShortcutSettingsValidation.validate(initial, menu: menu)
            throw CheckFailure(message: "A shortcut silently replaced an existing application menu action")
        } catch is ShortcutSettingsValidation.Failure {}
        try require(store.keyboardShortcuts == initial, "Conflict checks changed saved preferences")
        let custom = FloatingAICore.KeyboardShortcut(keyCode: 38, modifiers: UInt32(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        let disabled = KeyboardShortcutSettings(openNote: nil, toggleKeepOpen: custom)
        try require(store.updateKeyboardShortcuts(disabled), "Custom and disabled shortcuts could not be saved")
        let restored = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(restored.keyboardShortcuts == disabled, "Restart lost a customized or disabled shortcut")
        await restored.shutdown()
        await store.shutdown()
        let legacy = Data(#"{"version":1,"cliPath":"","defaultModelID":"","defaultEffort":"","notes":[]}"#.utf8)
        try legacy.write(to: persistence.documentURL, options: .atomic)
        let migrated = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        try require(migrated.keyboardShortcuts == KeyboardShortcutSettings() && migrated.recentNoteIDs.isEmpty,
                    "Existing notes did not receive the default shortcuts without a migration")
        await migrated.shutdown()
    }

    @MainActor private static func shortcutSaveFailureRollsBackOrDisablesRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-shortcut-save-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        defer { store.configureKeyboardShortcuts = nil; store.disableGlobalShortcut = nil }
        let persistence = NotePersistence(directory: directory)
        let original = store.keyboardShortcuts
        var replacement = original
        replacement.openNote = FloatingAICore.KeyboardShortcut(keyCode: 38, modifiers: UInt32(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        try require(store.persist(), "Could not create the shortcut storage-failure fixture")
        let savedData = try Data(contentsOf: persistence.documentURL)
        var attempts: [KeyboardShortcutSettings] = []
        var disabled = 0
        store.disableGlobalShortcut = { [weak store] in disabled += 1; store?.openNoteShortcutActive = false }
        store.configureKeyboardShortcuts = { settings in
            attempts.append(settings)
            throw CheckFailure(message: "Synthetic registration failure")
        }
        try require(!store.updateKeyboardShortcuts(replacement) && store.keyboardShortcuts == original && disabled == 0,
                    "Registration failure replaced preferences or disabled the previous shortcut")
        let afterRegistrationFailure = try Data(contentsOf: persistence.documentURL)
        try require(afterRegistrationFailure == savedData, "Registration failure wrote new preferences to disk")

        // Block atomic replacement using a directory at the temporary document
        // path. No chmod, live app data, or system shortcut registration is used.
        try FileManager.default.removeItem(at: persistence.documentURL)
        try FileManager.default.createDirectory(at: persistence.documentURL, withIntermediateDirectories: false)
        attempts.removeAll()
        store.configureKeyboardShortcuts = { settings in attempts.append(settings) }
        try require(!store.updateKeyboardShortcuts(replacement), "A failed save reported shortcut configuration success")
        try require(attempts == [replacement, original] && store.keyboardShortcuts == original && disabled == 0,
                    "A failed save did not restore the previous shortcut and preferences")
        try require(store.shortcutError?.contains("previous shortcuts have been kept") == true,
                    "A rolled-back save failure did not explain that the previous shortcuts were retained")

        attempts.removeAll()
        store.openNoteShortcutActive = true
        store.configureKeyboardShortcuts = { settings in
            attempts.append(settings)
            if settings == original { throw CheckFailure(message: "Synthetic rollback registration failure") }
        }
        try require(!store.updateKeyboardShortcuts(replacement), "A failed shortcut rollback reported success")
        try require(attempts == [replacement, original] && store.keyboardShortcuts == original && disabled == 1 && !store.openNoteShortcutActive,
                    "A failed rollback left the unpersisted global shortcut active")
        try require(store.shortcutError?.contains("Open Recent Note is inactive") == true,
                    "A failed rollback did not explain the inactive global shortcut")

        try FileManager.default.removeItem(at: persistence.documentURL)
        try savedData.write(to: persistence.documentURL, options: .atomic)
        attempts.removeAll()
        store.configureKeyboardShortcuts = { [weak store] settings in
            attempts.append(settings)
            store?.openNoteShortcutActive = settings.openNote != nil
        }
        try require(store.updateKeyboardShortcuts(replacement) && store.openNoteShortcutActive && store.shortcutError == nil,
                    "Explicit retry could not restore a shortcut after storage recovered")
        let recovered = try persistence.load()
        try require(recovered.keyboardShortcuts == replacement, "Explicit retry did not save the replacement shortcut")
        await store.shutdown()
    }

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
                                                      exerciseReturn: Bool = false,
                                                      trigger: (@MainActor () -> Void)? = nil) async -> ConfirmationDriver {
        await withCheckedContinuation { continuation in
            // Real button actions enter AppKit from its event loop. Invoking a
            // nested modal loop directly inside Swift's async main task can
            // corrupt that task's executor state on macOS 14 / Swift 5.10.
            DispatchQueue.main.async {
                let driver = ConfirmationDriver(choice: choice, exerciseReturn: exerciseReturn)
                driver.start()
                if let trigger { trigger() } else { store.requestDeleteNote(note) }
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
