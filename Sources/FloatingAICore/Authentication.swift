import Foundation

/// Persist only this selection; credentials never belong in the notes document.
public enum AuthenticationMode: String, Codable, Sendable, CaseIterable {
    case codexSignIn
    case openAIAPIKey
}

/// A short-lived launch credential. Descriptions and reflection deliberately omit its value.
public enum CodexAuthentication: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case codexSignIn
    case apiKey(String)

    public var mode: AuthenticationMode {
        if case .apiKey = self { return .openAIAPIKey }
        return .codexSignIn
    }
    public var description: String { mode == .openAIAPIKey ? "apiKey([redacted])" : "codexSignIn" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["mode": mode.rawValue]) }
}

public enum CodexAccountKind: String, Sendable, Equatable {
    case none
    case chatGPT
    case apiKey
    case unsupported

    public init(account: JSONValue) {
        switch account["type"].string {
        case "chatgpt": self = .chatGPT
        case "apiKey": self = .apiKey
        case nil where account == .null: self = .none
        default: self = .unsupported
        }
    }
    public var isLoggedIn: Bool { self == .chatGPT || self == .apiKey }
}
