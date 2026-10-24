import AppKit
import FloatingAICore
import SwiftUI

private typealias NoteShortcut = FloatingAICore.KeyboardShortcut

enum ShortcutSettingsValidation {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func validate(_ settings: KeyboardShortcutSettings, menu: NSMenu?) throws {
        let actions: [(String, NoteShortcut?)] = [("Open Recent Note", settings.openNote),
                                                  ("Toggle Keep Notes Expanded", settings.toggleKeepOpen),
                                                  ("Hide Note", settings.hideNote),
                                                  ("Delete Note", settings.deleteNote)]
        for (index, (title, shortcut)) in actions.enumerated() {
            guard let shortcut else { continue }
            if let other = actions[..<index].first(where: { $0.1 == shortcut }) {
                throw Failure(message: "\(title) and \(other.0) cannot use the same shortcut. Choose a different combination.")
            }
            try shortcut.validate()
            if let title = menu.flatMap({ conflictingItem(shortcut, in: $0) }) {
                throw Failure(message: "This shortcut is already used by \(title) in Floating AI. Choose another combination.")
            }
        }
    }

    private static func conflictingItem(_ shortcut: NoteShortcut, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let submenu = item.submenu, let title = conflictingItem(shortcut, in: submenu) { return title }
            guard !item.keyEquivalent.isEmpty, !shortcut.keyEquivalent.isEmpty else { continue }
            var modifiers = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            if item.keyEquivalent.lowercased() != item.keyEquivalent { modifiers.insert(.shift) }
            if item.keyEquivalent.lowercased() == shortcut.keyEquivalent.lowercased(), modifiers == shortcut.modifierFlags {
                return item.title
            }
        }
        return nil
    }
}

@MainActor struct ShortcutSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard Shortcuts").font(.headline)
            row("Open Recent Note", binding: \.openNote, defaultShortcut: .openNote)
            Text("Works from any app while Floating AI is running. Opens the most recently used note, or New Note if none exist. In a focused, expanded note, it collapses the note instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Toggle Keep Notes Expanded", binding: \.toggleKeepOpen, defaultShortcut: .toggleKeepOpen)
            row("Hide Note", binding: \.hideNote, defaultShortcut: .hideNote)
            row("Delete Note", binding: \.deleteNote, defaultShortcut: .deleteNote)
            Text("These work while a note has keyboard focus. Toggle Keep Notes Expanded changes the setting for all notes. Delete Note asks for confirmation first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.shortcutError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.openNoteShortcutError, error != store.shortcutError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if store.keyboardShortcuts.openNote != nil, !store.openNoteShortcutActive, !store.isRecordingShortcut {
                HStack {
                    Text("The Open Recent Note global shortcut is not active.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.retryGlobalShortcut != nil {
                        Button("Retry") {
                            do { try store.retryGlobalShortcut?(); store.shortcutError = nil }
                            catch { store.shortcutError = error.localizedDescription }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text("Click a shortcut to change it; press Esc to cancel. Other apps may use the same keys. Change or disable a shortcut if it interferes with your workflow.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { store.isRecordingShortcut = false }
    }

    private func row(_ title: String, binding: WritableKeyPath<KeyboardShortcutSettings, NoteShortcut?>,
                     defaultShortcut: NoteShortcut) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout)
            Spacer(minLength: 6)
            ShortcutRecorder(shortcut: store.keyboardShortcuts[keyPath: binding], label: title,
                             onBegin: { store.shortcutError = nil; store.isRecordingShortcut = true },
                             onEnd: { store.isRecordingShortcut = false },
                             onError: { store.shortcutError = $0 },
                             onCapture: { update(binding, to: $0) })
                .frame(width: 112, height: 24)
            Button {
                _ = update(binding, to: nil)
            } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).help("Disable \(title)")
                .accessibilityLabel("Disable \(title)")
                .disabled(store.keyboardShortcuts[keyPath: binding] == nil || store.isRecordingShortcut)
            Button {
                _ = update(binding, to: defaultShortcut)
            } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Restore default for \(title)")
                .accessibilityLabel("Restore default for \(title)")
                .disabled(store.isRecordingShortcut)
        }
    }

    private func update(_ binding: WritableKeyPath<KeyboardShortcutSettings, NoteShortcut?>,
                        to shortcut: NoteShortcut?) -> Bool {
        var updated = store.keyboardShortcuts
        updated[keyPath: binding] = shortcut
        do {
            try ShortcutSettingsValidation.validate(updated, menu: NSApp.mainMenu)
            if binding == \KeyboardShortcutSettings.openNote, shortcut != nil,
               shortcut == store.keyboardShortcuts.openNote, !store.openNoteShortcutActive {
                try store.retryGlobalShortcut?()
            }
            return store.updateKeyboardShortcuts(updated)
        } catch {
            store.shortcutError = error.localizedDescription
            return false
        }
    }
}

@MainActor struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: FloatingAICore.KeyboardShortcut?
    var label: String
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onError: (String) -> Void
    var onCapture: (FloatingAICore.KeyboardShortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(ShortcutRecorderButton.beginRecording(_:))
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onBegin = onBegin
        button.onEnd = onEnd
        button.onError = onError
        button.onCapture = onCapture
        button.setAccessibilityLabel("\(label) shortcut")
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.endRecording() }
}

@MainActor final class ShortcutRecorderButton: NSButton {
    var shortcut: FloatingAICore.KeyboardShortcut?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var onCapture: ((FloatingAICore.KeyboardShortcut) -> Bool)?
    private(set) var isRecording = false
    private var pendingShortcut: FloatingAICore.KeyboardShortcut?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        title = pendingShortcut != nil ? "Release keys…" :
            (isRecording ? "Press shortcut…" : (shortcut?.displayLabel ?? "Disabled"))
    }

    @objc func beginRecording(_ sender: Any?) {
        guard !isRecording, let window else { return }
        guard window.makeFirstResponder(self) else { return }
        isRecording = true
        onBegin?()
        refreshTitle()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isRecording, event.window === self.window else { return event }
            if event.type == .keyUp {
                guard let candidate = self.pendingShortcut, event.keyCode == candidate.keyCode else { return event }
                // Register only after the captured key is released, so holding
                // it cannot immediately invoke the new global shortcut.
                if self.onCapture?(candidate) == true { self.shortcut = candidate }
                self.endRecording()
                return nil
            }
            if event.keyCode == 53 { self.endRecording(); return nil }
            if event.keyCode == 48 { self.endRecording(); return event }
            guard self.pendingShortcut == nil, !event.isARepeat else { return nil }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let candidate = NoteShortcut(keyCode: event.keyCode, modifiers: UInt32(modifiers.rawValue))
            do {
                try candidate.validate()
                self.pendingShortcut = candidate
                self.refreshTitle()
            } catch { self.onError?(error.localizedDescription) }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording() }
        }
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        pendingShortcut = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        refreshTitle()
        onEnd?()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}
