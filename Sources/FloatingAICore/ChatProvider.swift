import Foundation

public enum ChatProvider: String, Codable, Sendable, CaseIterable {
    case codex, claude
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}

/// A menu identity includes the backend; only displayName is shown to the user.
public struct ChatModel: Identifiable, Equatable, Sendable {
    public let provider: ChatProvider
    public let model: CodexModel
    public init(provider: ChatProvider, model: CodexModel) {
        self.provider = provider; self.model = model
    }
    public static func selectionID(provider: ChatProvider, modelID: String) -> String {
        provider.rawValue + ":" + modelID
    }
    public var id: String { Self.selectionID(provider: provider, modelID: nativeID) }
    public var nativeID: String { model.id }
    public var displayName: String { model.displayName }
    public var defaultReasoningEffort: String { model.defaultReasoningEffort }
    public var supportedReasoningEfforts: [ReasoningEffortOption] { model.supportedReasoningEfforts }
    public var inputModalities: [String] { model.inputModalities }
    public var supportsImages: Bool { model.supportsImages }
    public var isDefault: Bool { model.isDefault }
}
