import AppKit
import Carbon
import FloatingAICore

enum KeyboardShortcutError: LocalizedError {
    case invalid(String)
    case systemConflict
    case systemCheckFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .systemConflict:
            return "This shortcut is enabled in macOS Keyboard Shortcuts. Choose another combination or change it in System Settings."
        case .systemCheckFailed(let status):
            return "Could not check macOS keyboard shortcuts (\(status)). Your previous shortcut has been kept."
        case .registrationFailed(let status):
            return "Could not enable this shortcut (\(status)). It may be in use by another app. Your previous shortcut has been kept."
        }
    }
}

extension KeyboardShortcut {
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(modifiers)) }

    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        self.init(keyCode: event.keyCode,
                  modifiers: UInt32(event.modifierFlags.intersection(Self.modifierMask).rawValue))
    }

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        return keyCode == event.keyCode && modifierFlags == event.modifierFlags.intersection(Self.modifierMask)
    }

    func validate() throws {
        guard Self.supportedKeyCodes.contains(keyCode),
              modifierFlags.subtracting(Self.modifierMask).isEmpty else {
            throw KeyboardShortcutError.invalid("Choose a regular key with Command or Control.")
        }
        guard !modifierFlags.intersection([.command, .control]).isEmpty else {
            throw KeyboardShortcutError.invalid("Include Command or Control so the shortcut does not replace normal typing.")
        }
        let flags = modifierFlags
        let reserved = (keyCode == 48 && flags.contains(.command)) ||
            (keyCode == 53 && flags == [.command, .option]) ||
            (keyCode == 12 && (flags == [.command, .control] ||
                               flags == [.command, .shift] || flags == [.command, .shift, .option]))
        guard !reserved else {
            throw KeyboardShortcutError.invalid("This combination is reserved for switching apps, Force Quit, locking, or logging out. Choose another shortcut.")
        }
    }

    var displayLabel: String {
        let flags = modifierFlags
        return (flags.contains(.control) ? "⌃" : "") +
            (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") +
            (flags.contains(.command) ? "⌘" : "") + keyLabel
    }

    /// Suitable for matching existing application menu commands. Nonprintable
    /// keys return AppKit's menu-equivalent character where one exists.
    var keyEquivalent: String {
        switch keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        case 76: return "\u{3}"
        case 117: return "\u{7f}"
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default: return layoutCharacter?.lowercased() ?? ""
        }
    }

    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        return (flags.contains(.command) ? UInt32(cmdKey) : 0) |
            (flags.contains(.option) ? UInt32(optionKey) : 0) |
            (flags.contains(.control) ? UInt32(controlKey) : 0) |
            (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }

    private var keyLabel: String {
        if let named = Self.keyNames[keyCode] { return named }
        return layoutCharacter?.uppercased() ?? "Key \(keyCode)"
    }

    private var layoutCharacter: String? {
        // Input methods need not expose layout data. The current keyboard
        // layout is the fallback, preserving useful labels while an IME runs.
        let sources = [TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                       TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()]
        for source in sources.compactMap({ $0 }) {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) > 0 else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, characters.count, &length, &characters)
            if status == noErr && length > 0 {
                let value = String(utf16CodeUnits: characters, count: length)
                if value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return value }
            }
        }
        return nil
    }

    private static let keyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 64: "F17",
        65: "Keypad .", 67: "Keypad ×", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "⌤", 78: "Keypad −", 79: "F18", 80: "F19", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20", 91: "Keypad 8", 92: "Keypad 9",
        95: "Keypad ,", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    private static let supportedKeyCodes = Set(UInt16(0)...UInt16(51)).union(keyNames.keys).union([93, 94])
}

/// Injectable to exercise failure and delivery paths without occupying real
/// system shortcuts or requiring Accessibility/Input Monitoring permission.
@MainActor protocol HotKeyRegistrationBackend: AnyObject {
    func enabledSystemShortcuts() throws -> [KeyboardShortcut]
    func register(_ shortcut: KeyboardShortcut, id: UInt32,
                  onEvent: @escaping (UInt32, Bool) -> Void) throws
    func unregister(id: UInt32)
}

@MainActor final class GlobalKeyboardShortcut {
    private let backend: any HotKeyRegistrationBackend
    private let onPressed: () -> Void
    private var activeID: UInt32?
    private var keyIsDown = false
    private static var nextID: UInt32 = 1
    private(set) var currentShortcut: KeyboardShortcut?

    init(backend: (any HotKeyRegistrationBackend)? = nil, onPressed: @escaping () -> Void) {
        self.backend = backend ?? CarbonHotKeyRegistrationBackend()
        self.onPressed = onPressed
    }

    func setShortcut(_ shortcut: KeyboardShortcut?) throws {
        guard shortcut != currentShortcut else { return }
        guard let shortcut else { disable(); return }
        try shortcut.validate()
        guard !(try backend.enabledSystemShortcuts()).contains(shortcut) else {
            throw KeyboardShortcutError.systemConflict
        }
        let newID = Self.nextID
        Self.nextID &+= 1
        // Register before retiring the old binding, so a failed change leaves
        // the working shortcut untouched. IDs reject already queued events.
        try backend.register(shortcut, id: newID) { [weak self] id, isPressed in
            self?.handleEvent(id: id, isPressed: isPressed)
        }
        let oldID = activeID
        activeID = newID
        currentShortcut = shortcut
        keyIsDown = false
        if let oldID { backend.unregister(id: oldID) }
    }

    func disable() {
        if let activeID { backend.unregister(id: activeID) }
        activeID = nil
        currentShortcut = nil
        keyIsDown = false
    }

    private func handleEvent(id: UInt32, isPressed: Bool) {
        guard id == activeID else { return }
        if !isPressed { keyIsDown = false; return }
        guard !keyIsDown else { return }
        keyIsDown = true
        onPressed()
    }
}

/// Coordinates preference changes and shortcut recording without accidentally
/// enabling a binding whose original registration failed.
@MainActor final class ShortcutConfigurationController {
    private let global: GlobalKeyboardShortcut
    private var recording = false
    private var resumeAfterRecording = false
    private(set) var settings: KeyboardShortcutSettings
    private(set) var error: String?

    var isOpenActive: Bool { global.currentShortcut != nil && global.currentShortcut == settings.openNote }

    init(settings: KeyboardShortcutSettings, global: GlobalKeyboardShortcut) {
        self.settings = settings
        self.global = global
        do { try global.setShortcut(settings.openNote) }
        catch { self.error = error.localizedDescription }
    }

    func update(_ settings: KeyboardShortcutSettings) throws {
        // A local binding change must remain possible even when the global
        // binding could not be registered at launch.
        if settings.openNote != self.settings.openNote {
            do {
                try global.setShortcut(settings.openNote)
                error = nil
                if recording { resumeAfterRecording = global.currentShortcut != nil }
            } catch {
                self.error = error.localizedDescription
                throw error
            }
        }
        self.settings = settings
    }

    func beginRecording() {
        guard !recording else { return }
        recording = true
        resumeAfterRecording = isOpenActive
        global.disable()
    }

    func endRecording() {
        guard recording else { return }
        recording = false
        let shouldResume = resumeAfterRecording
        resumeAfterRecording = false
        guard shouldResume, global.currentShortcut == nil else { return }
        do {
            try global.setShortcut(settings.openNote)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Explicit retry is separate from a local setting change or canceled
    /// recording, neither of which should revive an inactive global binding.
    func retryOpenShortcut() throws {
        do {
            try global.setShortcut(settings.openNote)
            error = nil
            if recording { resumeAfterRecording = isOpenActive }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func disable(restoring settings: KeyboardShortcutSettings? = nil) {
        recording = false
        resumeAfterRecording = false
        global.disable()
        if let settings { self.settings = settings }
    }
}

@MainActor private final class CarbonHotKeyRegistrationBackend: HotKeyRegistrationBackend {
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var callbacks: [UInt32: (UInt32, Bool) -> Void] = [:]
    private static let signature: OSType = 0x4641494B // FAIK

    func enabledSystemShortcuts() throws -> [KeyboardShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanaged)
        guard status == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            throw KeyboardShortcutError.systemCheckFailed(status)
        }
        return array.compactMap { item in
            guard (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let key = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let mods = item[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                  key.uint64Value <= UInt16.max else { return nil }
            let value = mods.uint32Value
            var flags: NSEvent.ModifierFlags = []
            if value & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if value & UInt32(optionKey) != 0 { flags.insert(.option) }
            if value & UInt32(controlKey) != 0 { flags.insert(.control) }
            if value & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            return KeyboardShortcut(keyCode: key.uint16Value, modifiers: UInt32(flags.rawValue))
        }
    }

    func register(_ shortcut: KeyboardShortcut, id: UInt32,
                  onEvent: @escaping (UInt32, Bool) -> Void) throws {
        try installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw KeyboardShortcutError.registrationFailed(status)
        }
        registrations[id] = reference
        callbacks[id] = onEvent
    }

    func unregister(id: UInt32) {
        callbacks.removeValue(forKey: id)
        if let reference = registrations.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let backend = Unmanaged<CarbonHotKeyRegistrationBackend>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == CarbonHotKeyRegistrationBackend.signature,
                      let callback = backend.callbacks[identifier.id] else { return OSStatus(eventNotHandledErr) }
                callback(identifier.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw KeyboardShortcutError.registrationFailed(status) }
    }

    deinit {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
