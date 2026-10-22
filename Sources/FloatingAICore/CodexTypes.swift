import Foundation

public struct ReasoningEffortOption: Identifiable, Codable, Sendable, Equatable {
    public let reasoningEffort: String
    public let description: String
    public var id: String { reasoningEffort }
    public init(reasoningEffort: String, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}

public struct CodexModel: Identifiable, Codable, Sendable, Equatable {
    /// The API's `model`, which may differ from its catalog entry's `id`.
    public let id: String
    public let displayName: String
    public let defaultReasoningEffort: String
    public let supportedReasoningEfforts: [ReasoningEffortOption]
    public let inputModalities: [String]
    public let isDefault: Bool
    public var supportsImages: Bool { inputModalities.contains("image") }

    public init(id: String, displayName: String, defaultReasoningEffort: String,
                supportedReasoningEfforts: [ReasoningEffortOption], inputModalities: [String] = ["text", "image"], isDefault: Bool = false) {
        self.id = id; self.displayName = displayName; self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.inputModalities = inputModalities; self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, model, displayName, defaultReasoningEffort, supportedReasoningEfforts, inputModalities, isDefault
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .model) ?? c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        defaultReasoningEffort = try c.decode(String.self, forKey: .defaultReasoningEffort)
        supportedReasoningEfforts = try c.decode([ReasoningEffortOption].self, forKey: .supportedReasoningEfforts)
        inputModalities = try c.decodeIfPresent([String].self, forKey: .inputModalities) ?? ["text", "image"]
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try c.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try c.encode(inputModalities, forKey: .inputModalities)
        try c.encode(isDefault, forKey: .isDefault)
    }
}

public struct ConnectionInfo: Sendable {
    public let version: String
    public let models: [CodexModel]
    public let accountKind: CodexAccountKind
    public var isLoggedIn: Bool { accountKind.isLoggedIn }
    public init(version: String, models: [CodexModel], accountKind: CodexAccountKind) {
        self.version = version; self.models = models; self.accountKind = accountKind
    }
    public init(version: String, models: [CodexModel], isLoggedIn: Bool) {
        self.init(version: version, models: models, accountKind: isLoggedIn ? .chatGPT : .none)
    }
}

public enum CodexEvent: Sendable, Equatable {
    case notification(method: String, params: JSONValue)
    case disconnected(String)
}

public enum CodexError: Error, LocalizedError, Equatable {
    case notConnected
    case protocolError(String)
    case server(code: Int, message: String)
    case timeout(String)
    case disconnected(String)
    case incompatibleVersion(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Codex is not connected. Reconnect in Settings."
        case .protocolError(let text): return "Codex protocol error: \(text)"
        case .server(_, let message): return message
        case .timeout(let method): return "Codex request timed out (\(method)). Your message may have arrived. Restore the conversation before retrying."
        case .disconnected(let text): return "Codex disconnected: \(text)"
        case .incompatibleVersion(let version): return "Codex \(version) has not been verified for chat mode. Supported versions: 0.134.x, 0.151.x and 0.163.x, including prereleases. Update Floating AI to support newer CLI versions."
        }
    }
}
