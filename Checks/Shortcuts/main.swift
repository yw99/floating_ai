import AppKit
import FloatingAICore

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(description: message) }
}

private func rejected(_ body: () throws -> Void, _ message: String) throws {
    do { try body() } catch is KeyboardShortcutError { return }
    throw Failure(description: message)
}

@MainActor private final class FakeBackend: HotKeyRegistrationBackend {
    var systemShortcuts: [KeyboardShortcut] = []
    var failSystemCheck = false
    var failRegistration = false
    var registrations: [UInt32: KeyboardShortcut] = [:]
    var callbacks: [UInt32: (UInt32, Bool) -> Void] = [:]
    var operations: [String] = []

    func enabledSystemShortcuts() throws -> [KeyboardShortcut] {
        if failSystemCheck { throw KeyboardShortcutError.systemCheckFailed(-1) }
        return systemShortcuts
    }

    func register(_ shortcut: KeyboardShortcut, id: UInt32,
                  onEvent: @escaping (UInt32, Bool) -> Void) throws {
        operations.append("register:\(id)")
        if failRegistration { throw KeyboardShortcutError.registrationFailed(-2) }
        registrations[id] = shortcut
        callbacks[id] = onEvent
    }

    func unregister(id: UInt32) {
        operations.append("unregister:\(id)")
        registrations[id] = nil
        // Keep queued delivery callbacks deliberately: stale Carbon events
        // must not trigger an action after replacement or disablement.
    }

    func send(id: UInt32, pressed: Bool) { callbacks[id]?(id, pressed) }
}

@MainActor private func checks() throws {
    let defaults = KeyboardShortcutSettings()
    try check(defaults.openNote?.keyCode == 31 && defaults.toggleKeepOpen?.keyCode == 40 &&
              defaults.hideNote?.keyCode == 46 && defaults.deleteNote?.keyCode == 51,
              "Default key codes changed")
    try check([defaults.openNote, defaults.toggleKeepOpen, defaults.hideNote, defaults.deleteNote]
                .allSatisfy { $0?.modifierFlags == [.command, .option] }, "Default modifiers changed")
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    try check(decoder.decode(KeyboardShortcutSettings.self, from: encoder.encode(defaults)) == defaults,
              "Default bindings did not round-trip")
    let disabled = KeyboardShortcutSettings(openNote: nil, toggleKeepOpen: nil, hideNote: nil, deleteNote: nil)
    try check(decoder.decode(KeyboardShortcutSettings.self, from: encoder.encode(disabled)) == disabled,
              "Disabled bindings became enabled after reload")
    // Settings saved before Hide and Delete existed keep their bindings and gain the new defaults.
    let earlier = Data(#"{"openNote":null,"toggleKeepOpen":{"keyCode":38,"modifiers":1572864}}"#.utf8)
    try check(decoder.decode(KeyboardShortcutSettings.self, from: earlier) ==
              KeyboardShortcutSettings(openNote: nil, toggleKeepOpen: KeyboardShortcut(keyCode: 38, modifiers: 1572864)),
              "Earlier saved settings lost a binding or did not receive the new defaults")
    print("PASS shortcut defaults and persistence")

    let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                modifierFlags: [.command, .option, .capsLock, .numericPad, .function],
                                timestamp: 0, windowNumber: 0, context: nil,
                                characters: "O", charactersIgnoringModifiers: "O",
                                isARepeat: false, keyCode: 31)!
    try check(KeyboardShortcut.openNote.matches(event), "Incidental modifiers blocked a matching shortcut")
    try check(KeyboardShortcut(event: event) == .openNote, "Recorder did not normalize event modifiers")
    try check(!KeyboardShortcut.toggleKeepOpen.matches(event), "Different key matched")
    try check(!KeyboardShortcut(keyCode: 31, modifiers: UInt32(NSEvent.ModifierFlags.command.rawValue)).matches(event),
              "Extra intentional modifier incorrectly matched")
    print("PASS event matching and recorder normalization")

    try KeyboardShortcut.openNote.validate()
    try KeyboardShortcut.toggleKeepOpen.validate()
    try KeyboardShortcut.hideNote.validate()
    try KeyboardShortcut.deleteNote.validate()
    try KeyboardShortcut(keyCode: 123, modifiers: UInt32(NSEvent.ModifierFlags.control.rawValue)).validate()
    for invalid in [KeyboardShortcut(keyCode: 31, modifiers: 0),
                    KeyboardShortcut(keyCode: 31, modifiers: UInt32(NSEvent.ModifierFlags.shift.rawValue)),
                    KeyboardShortcut(keyCode: 31, modifiers: UInt32(NSEvent.ModifierFlags.option.rawValue)),
                    KeyboardShortcut(keyCode: 55, modifiers: UInt32(NSEvent.ModifierFlags.command.rawValue)),
                    KeyboardShortcut(keyCode: UInt16.max, modifiers: UInt32(NSEvent.ModifierFlags.command.rawValue)),
                    KeyboardShortcut(keyCode: 31, modifiers: UInt32.max)] {
        try rejected({ try invalid.validate() }, "Invalid shortcut was accepted: \(invalid)")
    }
    for (key, flags): (UInt16, NSEvent.ModifierFlags) in [
        (48, [.command]), (48, [.command, .shift]), (53, [.command, .option]),
        (12, [.command, .control]), (12, [.command, .shift]), (12, [.command, .shift, .option])
    ] {
        try rejected({ try KeyboardShortcut(keyCode: key, modifiers: UInt32(flags.rawValue)).validate() },
                     "Essential system shortcut was accepted")
    }
    print("PASS typing protection, invalid keys, and reserved combinations")

    try check(!KeyboardShortcut.openNote.displayLabel.isEmpty, "Shortcut label is empty")
    try check(!KeyboardShortcut.openNote.keyEquivalent.isEmpty, "Current keyboard layout could not label O")
    try check(KeyboardShortcut.openNote.displayLabel.hasPrefix("⌥⌘"), "Modifier label order changed")
    let arrow = KeyboardShortcut(keyCode: 123, modifiers: UInt32(NSEvent.ModifierFlags.control.rawValue))
    try check(arrow.displayLabel == "⌃←" && !arrow.keyEquivalent.isEmpty, "Nonletter key display failed")
    try check(KeyboardShortcut.deleteNote.displayLabel == "⌥⌘⌫" && KeyboardShortcut.deleteNote.keyEquivalent == "\u{8}",
              "Delete key display failed")
    print("PASS current-layout and special-key labels")

    let backend = FakeBackend()
    var count = 0
    let controller = GlobalKeyboardShortcut(backend: backend) { count += 1 }
    try controller.setShortcut(.openNote)
    let firstID = try unwrap(backend.registrations.keys.first)
    backend.send(id: firstID, pressed: true)
    backend.send(id: firstID, pressed: true)
    try check(count == 1, "Holding the shortcut repeated the action")
    backend.send(id: firstID, pressed: false)
    backend.send(id: firstID, pressed: true)
    try check(count == 2, "A new press did not trigger after release")
    try controller.setShortcut(.openNote)
    try check(backend.operations.count == 1, "Unchanged binding was re-registered")
    print("PASS global dispatch, release, repeat suppression, and unchanged setting")

    backend.failRegistration = true
    try rejected({ try controller.setShortcut(.toggleKeepOpen) }, "Registration failure was ignored")
    try check(controller.currentShortcut == .openNote && backend.registrations[firstID] == .openNote,
              "Failed registration removed the previous shortcut")
    backend.failRegistration = false
    backend.systemShortcuts = [.toggleKeepOpen]
    let beforeConflict = backend.operations.count
    try rejected({ try controller.setShortcut(.toggleKeepOpen) }, "Enabled system shortcut was accepted")
    try check(controller.currentShortcut == .openNote && backend.operations.count == beforeConflict,
              "Conflict changed the registration")
    backend.systemShortcuts = []
    backend.failSystemCheck = true
    try rejected({ try controller.setShortcut(.toggleKeepOpen) }, "Failed system inspection was ignored")
    try check(controller.currentShortcut == .openNote && backend.registrations[firstID] == .openNote,
              "System inspection failure removed the previous shortcut")
    backend.failSystemCheck = false
    print("PASS registration failures and system conflicts preserve the old binding")

    try controller.setShortcut(.toggleKeepOpen)
    let secondID = try unwrap(backend.registrations.keys.first)
    try check(secondID != firstID, "Replacement reused a queued-event identifier")
    try check(backend.operations.suffix(2) == ["register:\(secondID)", "unregister:\(firstID)"],
              "Old shortcut was removed before the new one registered")
    backend.send(id: firstID, pressed: true)
    backend.send(id: secondID, pressed: true)
    backend.send(id: firstID, pressed: false)
    backend.send(id: secondID, pressed: true)
    try check(count == 3, "Stale press/release affected the current shortcut")
    try controller.setShortcut(nil)
    backend.send(id: secondID, pressed: false)
    backend.send(id: secondID, pressed: true)
    try check(count == 3 && backend.registrations.isEmpty && controller.currentShortcut == nil,
              "Disabled shortcut still triggered")
    try controller.setShortcut(.openNote)
    let thirdID = try unwrap(backend.registrations.keys.first)
    backend.send(id: thirdID, pressed: true)
    try check(count == 4, "Re-enabling retained stale key-down state")
    controller.disable()
    try check(backend.registrations.isEmpty, "Explicit shutdown did not unregister")
    print("PASS transactional replacement, stale events, disabling, and re-enabling")

    let inactiveBackend = FakeBackend()
    inactiveBackend.failRegistration = true
    let inactiveGlobal = GlobalKeyboardShortcut(backend: inactiveBackend) {}
    let inactive = ShortcutConfigurationController(settings: defaults, global: inactiveGlobal)
    try check(!inactive.isOpenActive && inactive.error != nil, "Initial registration failure was hidden")
    let localChange = KeyboardShortcutSettings(openNote: .openNote,
                                               toggleKeepOpen: KeyboardShortcut(keyCode: 38, modifiers: 1 << 20))
    let failedAttempts = inactiveBackend.operations.count
    try inactive.update(localChange)
    try check(inactive.settings == localChange && inactiveBackend.operations.count == failedAttempts,
              "Changing the local shortcut retried a failed global registration")
    inactive.beginRecording()
    inactiveBackend.failRegistration = false
    inactive.endRecording()
    try check(!inactive.isOpenActive && inactiveBackend.operations.count == failedAttempts,
              "Canceling recording enabled a previously inactive shortcut")
    try inactive.retryOpenShortcut()
    try check(inactive.isOpenActive && inactive.error == nil && inactive.settings == localChange,
              "Explicit retry did not recover the same inactive shortcut")
    inactive.disable()
    try inactive.update(KeyboardShortcutSettings(openNote: .toggleKeepOpen, toggleKeepOpen: nil))
    try check(inactive.isOpenActive && inactive.error == nil, "Explicit new global shortcut did not recover")
    inactive.disable()
    print("PASS initial failure, independent local changes, and inactive recording cancellation")

    let recordingBackend = FakeBackend()
    let recordingGlobal = GlobalKeyboardShortcut(backend: recordingBackend) {}
    let configuration = ShortcutConfigurationController(settings: defaults, global: recordingGlobal)
    try check(configuration.isOpenActive, "Initial valid shortcut was not active")
    configuration.beginRecording()
    configuration.beginRecording()
    try check(!configuration.isOpenActive && recordingBackend.registrations.isEmpty, "Recording left shortcut active")
    configuration.endRecording()
    try check(configuration.isOpenActive, "Canceling recording did not restore the previous active shortcut")
    configuration.beginRecording()
    try configuration.update(localChange)
    try check(!configuration.isOpenActive, "Local change prematurely enabled the suspended global shortcut")
    configuration.endRecording()
    try check(configuration.isOpenActive && configuration.settings == localChange,
              "Recording a local shortcut did not preserve and restore the global shortcut")

    configuration.beginRecording()
    let replacement = KeyboardShortcutSettings(openNote: .toggleKeepOpen, toggleKeepOpen: nil)
    try configuration.update(replacement)
    let afterNewBinding = recordingBackend.operations.count
    configuration.endRecording()
    try check(configuration.isOpenActive && configuration.settings == replacement &&
              recordingBackend.operations.count == afterNewBinding,
              "New binding registered during recording was registered again")

    configuration.beginRecording()
    recordingBackend.failRegistration = true
    let previous = configuration.settings
    try rejected({ try configuration.update(defaults) }, "Failed preference change was accepted")
    try check(configuration.settings == previous, "Failed preference change replaced saved preferences")
    configuration.endRecording()
    try check(!configuration.isOpenActive && configuration.error != nil, "Failed restoration did not report inactive state")
    recordingBackend.failRegistration = false
    configuration.beginRecording()
    configuration.endRecording()
    try check(!configuration.isOpenActive, "Repeated recording silently revived a failed shortcut")

    try configuration.update(defaults)
    configuration.beginRecording()
    try configuration.update(disabled)
    configuration.endRecording()
    try check(configuration.settings == disabled && !configuration.isOpenActive && recordingBackend.registrations.isEmpty,
              "Disabled binding was restored after recording")
    try configuration.update(defaults)
    configuration.beginRecording()
    configuration.disable()
    configuration.endRecording()
    try check(!configuration.isOpenActive && recordingBackend.registrations.isEmpty,
              "Shutdown resumed a pending recording registration")
    print("PASS active recording lifecycle, transactional updates, failures, and disabled state")

    try configuration.update(replacement)
    recordingBackend.failRegistration = true
    try rejected({ try configuration.update(defaults) }, "Failed rollback was ignored")
    configuration.disable(restoring: defaults)
    try check(configuration.settings == defaults && !configuration.isOpenActive && recordingBackend.registrations.isEmpty,
              "Failed rollback left controller preferences out of sync")
    try rejected({ try configuration.retryOpenShortcut() }, "Retry failure was ignored")
    try check(configuration.settings == defaults && !configuration.isOpenActive, "Failed retry changed preferences")
    recordingBackend.failRegistration = false
    try configuration.retryOpenShortcut()
    try check(configuration.isOpenActive && configuration.settings == defaults && configuration.error == nil,
              "Explicit retry failed to recover rolled-back preferences")
    configuration.disable()
    print("PASS failed rollback alignment and explicit same-binding retry")
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw Failure(description: "Missing fixture registration") }
    return value
}

@main private enum ShortcutChecks {
    @MainActor static func main() {
        do {
            try checks()
            print("All 10 shortcut checks passed (fake registration; no real shortcut occupied).")
            if CommandLine.arguments.contains("--native-registration") {
                _ = NSApplication.shared
                let native = GlobalKeyboardShortcut {}
                defer { native.disable() }
                let smokeKey = KeyboardShortcut(keyCode: 90, modifiers: UInt32(
                    NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue))
                try native.setShortcut(smokeKey)
                try check(native.currentShortcut == smokeKey, "Native registration was not retained")
                native.disable()
                try check(native.currentShortcut == nil, "Native registration did not clear")
                print("PASS native Carbon registration and cleanup (⌃⌥⇧⌘F20; no key event sent)")
            }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
