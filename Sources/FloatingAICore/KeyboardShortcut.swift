import Foundation

/// A physical key and the four standard macOS modifier flags. Keeping the
/// representation independent of AppKit makes saved preferences portable.
public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt32

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let openNote = KeyboardShortcut(keyCode: 31, modifiers: (1 << 20) | (1 << 19))
    public static let toggleKeepOpen = KeyboardShortcut(keyCode: 40, modifiers: (1 << 20) | (1 << 19))
    public static let hideNote = KeyboardShortcut(keyCode: 46, modifiers: (1 << 20) | (1 << 19))
    public static let deleteNote = KeyboardShortcut(keyCode: 51, modifiers: (1 << 20) | (1 << 19))
}

public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    /// Nil disables the action. An absent settings object or binding in an older
    /// document uses the default rather than treating it as disabled.
    public var openNote: KeyboardShortcut?
    public var toggleKeepOpen: KeyboardShortcut?
    public var hideNote: KeyboardShortcut?
    public var deleteNote: KeyboardShortcut?

    public init(openNote: KeyboardShortcut? = .openNote,
                toggleKeepOpen: KeyboardShortcut? = .toggleKeepOpen,
                hideNote: KeyboardShortcut? = .hideNote,
                deleteNote: KeyboardShortcut? = .deleteNote) {
        self.openNote = openNote
        self.toggleKeepOpen = toggleKeepOpen
        self.hideNote = hideNote
        self.deleteNote = deleteNote
    }

    private enum CodingKeys: String, CodingKey { case openNote, toggleKeepOpen, hideNote, deleteNote }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func binding(_ key: CodingKeys, default value: KeyboardShortcut) throws -> KeyboardShortcut? {
            container.contains(key) ? try container.decodeIfPresent(KeyboardShortcut.self, forKey: key) : value
        }
        self.init(openNote: try binding(.openNote, default: .openNote),
                  toggleKeepOpen: try binding(.toggleKeepOpen, default: .toggleKeepOpen),
                  hideNote: try binding(.hideNote, default: .hideNote),
                  deleteNote: try binding(.deleteNote, default: .deleteNote))
    }

    public func encode(to encoder: Encoder) throws {
        // Explicit nulls keep a disabled action disabled after a restart; an
        // omitted key would read back as the default.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(openNote, forKey: .openNote)
        try container.encode(toggleKeepOpen, forKey: .toggleKeepOpen)
        try container.encode(hideNote, forKey: .hideNote)
        try container.encode(deleteNote, forKey: .deleteNote)
    }
}
