import AppKit
import FloatingAICore
import SwiftUI

// Real production SwiftUI controls and confirmation dialogs, using only
// temporary unsent notes. No CLI, account, Keychain, or user note is accessed.
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

@MainActor private final class ModalDriver: NSObject {
    let choice: String
    let pressReturn: Bool
    private var timer: Timer?
    private var deadline = Date()
    private(set) var found = false
    private(set) var safeDefault = false
    private(set) var includesCount = false
    private(set) var usedReturn = false
    private(set) var diagnostics = ""

    init(choice: String, pressReturn: Bool = false) { self.choice = choice; self.pressReturn = pressReturn }
    func start() {
        deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }
    func stop() { timer?.invalidate(); timer = nil }
    @objc private func tick() {
        guard let modal = NSApplication.shared.modalWindow, let content = modal.contentView else {
            if Date() > deadline { stop(); NSApplication.shared.abortModal() }
            return
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content), buttons = views.compactMap { $0 as? NSButton }
        diagnostics = "buttons=" + buttons.map { "\($0.title):key=\($0.keyEquivalent.unicodeScalars.map(\.value)),default=\(modal.defaultButtonCell === $0.cell),destructive=\($0.hasDestructiveAction)" }.joined(separator: ";") + ";texts=" + views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "|")
        guard let cancel = buttons.first(where: { $0.title == "Cancel" }),
              let delete = buttons.first(where: { $0.title == "Delete 2 Notes" }),
              let selected = buttons.first(where: { $0.title == choice }) else {
            if Date() > deadline { stop(); NSApplication.shared.abortModal() }
            return
        }
        found = true
        includesCount = views.compactMap { ($0 as? NSTextField)?.stringValue }.contains("Delete 2 notes permanently?")
        safeDefault = delete.hasDestructiveAction && delete.keyEquivalent != "\r" && modal.defaultButtonCell !== delete.cell &&
            (cancel.keyEquivalent == "\r" || cancel.keyEquivalent == "\u{1b}" || modal.defaultButtonCell === cancel.cell)
        if pressReturn && !usedReturn {
            usedReturn = true
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: modal.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)!
            modal.sendEvent(enter)
        } else {
            stop()
            selected.performClick(nil)
        }
    }
}

@MainActor private final class Fixture {
    let directory: URL
    let store: AppStore
    let notes: [NoteState]
    let window: NSWindow
    var showCalls = 0
    var hideCalls = 0
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-ai-manage-ui-\(UUID())")
        store = AppStore(directory: directory, apiKeyStore: EmptyKeyStore())
        let first = store.createNote(title: "Hidden first", model: "codex:fixture", effort: "medium")
        let second = store.createNote(title: "Hidden second", model: "claude:fixture", effort: "medium")
        let last = store.createNote(title: "Retained note", model: "codex:fixture", effort: "medium")
        first.isVisible = false
        second.isVisible = false
        first.draft = "Keep first draft"
        second.draft = "Keep second draft"
        last.draft = "Keep retained draft"
        notes = [first, second, last]
        store.persist()
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Manage Notes UI fixture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ManageNotesView(store: store,
            onShow: { [weak self] _ in self?.showCalls += 1 }, onHide: { [weak self] _ in self?.hideCalls += 1 }))
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func close() async {
        window.close()
        await store.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

@main private struct ManageNotesUIChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in await runChecks(); exit(0) }
        NSApplication.shared.run()
    }

    @MainActor private static func runChecks() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            fputs("FAIL: Manage Notes UI checks exceeded their deadline\n", stderr)
            exit(1)
        }
        do {
            try require(!NSScreen.screens.isEmpty, "Native controls require macOS window-server access")
            try await selectionDoesNotOpenHiddenNotes()
            try await cancellationPreservesAllNotes()
            try await explicitBatchDeletionUpdatesSelection()
            print("PASS: 3 native Manage Notes UI checks")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func settle() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    @MainActor private static func buttons(in fixture: Fixture) -> [NSButton] {
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(descendants)
        }
        return fixture.window.contentView.map(descendants) ?? []
    }
    @MainActor private static func isCheckbox(_ button: NSButton) -> Bool {
        String(describing: type(of: button.superview!)).contains("Checkbox")
    }
    @MainActor private static func selectedCount(in fixture: Fixture) -> Int {
        // The enabled batch action and exact confirmation count independently
        // verify that these native checkbox states reached SwiftUI's Binding.
        buttons(in: fixture).filter { isCheckbox($0) && $0.state != .off }.count
    }
    @MainActor private static func find(_ label: String, in fixture: Fixture) throws -> NSButton {
        let all = buttons(in: fixture)
        // SwiftUI draws button labels itself on macOS 14. Its in-process AX
        // tree is absent without an assistive-technology client, so locate the
        // actual AppKit controls in their production header/list/footer order.
        if label.hasPrefix("Select Hidden ") {
            let title = String(label.dropFirst("Select ".count))
            let checkboxes = all.filter(isCheckbox)
            guard let index = fixture.store.notes.firstIndex(where: { $0.title == title }),
                  checkboxes.indices.contains(index) else { throw CheckFailure(message: "Missing production checkbox: \(label)") }
            return checkboxes[index]
        }
        let commands = all.filter { !isCheckbox($0) }
        let labels = ["Select All", "Deselect All", "Show", "Hide", "Delete Selected…"]
        guard commands.count == labels.count, let index = labels.firstIndex(of: label) else {
            throw CheckFailure(message: "Unexpected production controls while finding \(label): \(commands.count) buttons")
        }
        return commands[index]
    }
    @MainActor private static func enabled(_ label: String, in fixture: Fixture) throws -> Bool {
        try find(label, in: fixture).isEnabled
    }
    @MainActor private static func press(_ label: String, in fixture: Fixture, driver: ModalDriver? = nil) async throws {
        let button = try find(label, in: fixture)
        // AppKit's nested modal loop must begin outside Swift's async task.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                driver?.start()
                if isCheckbox(button) {
                    // SwiftUI's checkbox mouse handler updates its Bool binding;
                    // NSButton.performClick alone can leave a mixed cell state.
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: fixture.window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                    guard let content = fixture.window.contentView,
                          let target = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else {
                        driver?.stop(); continuation.resume(); return
                    }
                    if target is NSButton { NSApplication.shared.postEvent(up, atStart: true) }
                    target.mouseDown(with: down)
                    if !(target is NSButton) { target.mouseUp(with: up) }
                    if let leftover = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                        target.mouseUp(with: leftover)
                    }
                } else { button.performClick(nil) }
                driver?.stop()
                continuation.resume()
            }
        }
        try await settle()
    }
    @MainActor private static func selectHidden(_ fixture: Fixture) async throws {
        try await settle()
        try await press("Select Hidden first", in: fixture)
        try await press("Select Hidden second", in: fixture)
        let states = buttons(in: fixture).filter(isCheckbox).map { $0.state.rawValue }
        try require(selectedCount(in: fixture) == 2, "The hidden-note checkboxes did not select two notes: \(states)")
        let canDelete = try enabled("Delete Selected…", in: fixture)
        try require(canDelete, "Native checkbox selections did not enable the batch action")
    }
    @MainActor private static func exercise(_ check: (Fixture) async throws -> Void) async throws {
        let fixture = Fixture()
        do { try await check(fixture); await fixture.close() }
        catch { await fixture.close(); throw error }
    }

    @MainActor private static func selectionDoesNotOpenHiddenNotes() async throws {
        try await exercise { fixture in
            try await selectHidden(fixture)
            try await press("Select All", in: fixture)
            try require(selectedCount(in: fixture) == 3, "Select All did not select all rows")
            try await press("Deselect All", in: fixture)
            try require(selectedCount(in: fixture) == 0, "Deselect All kept selected rows")
            let canDelete = try enabled("Delete Selected…", in: fixture)
            try require(!canDelete, "An empty selection can be deleted")
            try require(fixture.showCalls == 0 && fixture.hideCalls == 0 && fixture.notes.prefix(2).allSatisfy { !$0.isVisible },
                        "Selecting hidden notes showed or hid their windows")
            try await busySelectionDisablesDeletion(fixture)
        }
    }

    @MainActor private static func cancellationPreservesAllNotes() async throws {
        try await exercise { fixture in
            try await selectHidden(fixture)
            for pressReturn in [false, true] {
                let driver = ModalDriver(choice: "Cancel", pressReturn: pressReturn)
                try await press("Delete Selected…", in: fixture, driver: driver)
                try require(driver.found && driver.includesCount && driver.safeDefault,
                            "Batch confirmation lacks its count, destructive action, or safe cancel default: found=\(driver.found),count=\(driver.includesCount),safe=\(driver.safeDefault); \(driver.diagnostics)")
                try require(!pressReturn || driver.usedReturn, "Return cancellation was not exercised")
                let saved = try NotePersistence(directory: fixture.directory).load()
                try require(saved.notes.count == 3 && saved.notes.allSatisfy { $0.deletionPending != true } &&
                            fixture.store.notes.allSatisfy { !$0.deletionPending && !$0.isDeleting },
                            "Cancelling or pressing Return changed notes or wrote deletion markers")
                try require(fixture.notes[0].draft == "Keep first draft" && fixture.notes[1].draft == "Keep second draft" &&
                            fixture.notes.prefix(2).allSatisfy { !$0.isVisible } && fixture.showCalls == 0 && fixture.hideCalls == 0,
                            "Cancelling changed hidden-note visibility or drafts")
            }
        }
    }

    @MainActor private static func explicitBatchDeletionUpdatesSelection() async throws {
        try await exercise { fixture in
            try await selectHidden(fixture)
            let driver = ModalDriver(choice: "Delete 2 Notes")
            try await press("Delete Selected…", in: fixture, driver: driver)
            try require(driver.found && driver.includesCount, "The selected count was missing from the real confirmation")
            for _ in 0..<50 where fixture.store.isDeletingNotes || fixture.store.notes.count != 1 { try await settle() }
            try require(fixture.store.notes.map(\.id) == [fixture.notes[2].id] && fixture.notes[2].draft == "Keep retained draft",
                        "Batch deletion removed the wrong notes")
            let canDelete = try enabled("Delete Selected…", in: fixture)
            try require(selectedCount(in: fixture) == 0 && !canDelete && fixture.store.noteDeletionSummary == "Deleted 2 notes.",
                        "Successful deletion did not clear selection or update the result status")
            let saved = try NotePersistence(directory: fixture.directory).load()
            try require(saved.notes.map(\.id) == [fixture.notes[2].id] && fixture.showCalls == 0 && fixture.hideCalls == 0,
                        "Batch deletion was not persisted or opened a hidden note")
            try require(fixture.notes.prefix(2).allSatisfy { !$0.isVisible }, "Deleting hidden notes changed their visibility")
        }
    }

    @MainActor private static func busySelectionDisablesDeletion(_ fixture: Fixture) async throws {
        try await selectHidden(fixture)
        fixture.notes[1].isBusy = true
        try await settle()
        let canDelete = try enabled("Delete Selected…", in: fixture)
        try require(!canDelete, "A selected generating note did not disable deletion")
        try require(fixture.store.deletionUnavailableReason(for: Array(fixture.notes.prefix(2)))?.contains("Stop the selected notes") == true,
                    "The disabled selection has no explanatory status")
        let driver = ModalDriver(choice: "Cancel")
        try await press("Delete Selected…", in: fixture, driver: driver)
        try require(!driver.found && fixture.store.notes.count == 3 && fixture.store.notes.allSatisfy { !$0.deletionPending },
                    "A disabled delete action opened confirmation or changed notes")
        fixture.notes[1].isBusy = false
    }
}
