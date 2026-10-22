import AppKit
import Combine
import FloatingAICore

typealias Attachment = StoredAttachment
typealias ChatMessage = TranscriptMessage

@MainActor final class NoteState: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var model: String
    @Published var provider: ChatProvider
    var modelSelectionID: String { ChatModel.selectionID(provider: provider, modelID: model) }
    @Published var effort: String
    @Published var draft: String = ""
    @Published var composerHeight: Double = 64
    @Published var attachments: [Attachment] = []
    @Published var fileLibrary: [Attachment] = []
    @Published var isImportingFiles = false
    @Published var messages: [ChatMessage] = []
    @Published var isExpanded = false
    // A brief visible header preserves the second click's target while collapsing.
    @Published var isHeaderOnly = false
    @Published var isVisible = true
    @Published var isBusy = false
    @Published var isStopping = false
    @Published var isDeleting = false
    @Published var deletionPending = false
    @Published var retainedImagePaths: Set<String> = []
    var imageReferencesKnown = true
    @Published var needsReconciliation = false
    @Published var error: String?
    @Published var hasUnreadReply = false
    @Published var focusRequest = UUID()
    var threadID: String?
    var activeTurnID: String?
    var hasImages = false
    var hasFiles = false
    var compactX: Double?
    var compactY: Double?
    @Published var compactWidth: Double = 220
    @Published var compactHeight: Double = 40
    var expandedWidth: Double = 500
    var expandedHeight: Double = 640
    var displayID: UInt32?
    var pendingUserMessageID: String?
    @Published var pendingSubmission: PendingSubmission?

    init(id: UUID = UUID(), title: String = "Ask Me Anything", model: String = "", effort: String = "medium", provider: ChatProvider = .codex) {
        self.id = id
        self.provider = provider
        self.title = title
        self.model = model
        self.effort = effort
    }
}

typealias PendingSubmission = PendingMessage

struct CompactResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let top = Self(rawValue: 4)
    static let bottom = Self(rawValue: 8)
}

struct NoteWindowActions {
    var expand: () -> Void
    var collapse: () -> Void
    var hide: () -> Void
    var interaction: (_ name: String, _ active: Bool) -> Void
    var dragHover: (_ active: Bool) -> Void
    var collapseTitle: ((TimeInterval) -> Void)? = nil
    var delete: () -> Void = {}
    var beginCompactResize: (CompactResizeEdges, NSPoint) -> Bool = { _, _ in false }
    var updateCompactResize: (NSPoint) -> Void = { _ in }
    var endCompactResize: () -> Void = {}
    var resetSize: () -> Void = {}
}
