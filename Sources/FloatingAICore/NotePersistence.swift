import Foundation

public struct StoredAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    public var kind: Kind?
    public var byteCount: Int64?
    /// Migration-only alias for an image shared by pre-library versions.
    public var legacyPath: String?
    public enum Kind: String, Codable, Sendable { case image, file }
    public var isImage: Bool { kind != .file }
    public init(id: UUID = UUID(), path: String, name: String, kind: Kind? = nil, byteCount: Int64? = nil) {
        self.id = id; self.path = path; self.name = name; self.kind = kind; self.byteCount = byteCount
    }
}

public struct PendingMessage: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [StoredAttachment]
    public var model: String
    public var effort: String
    public var previousUserMessageID: String?
    public init(text: String, attachments: [StoredAttachment], model: String, effort: String, previousUserMessageID: String? = nil) {
        self.text = text; self.attachments = attachments; self.model = model; self.effort = effort
        self.previousUserMessageID = previousUserMessageID
    }
    public func matchesNewReceipt(_ message: TranscriptMessage?) -> Bool {
        guard let message else { return false }
        return message.role == "user" && message.id != previousUserMessageID && message.text == text &&
            message.imagePaths == attachments.filter(\.isImage).map(\.path) &&
            message.fileAttachments == attachments.filter { !$0.isImage }
    }
}

public struct StoredNote: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var model: String
    public var effort: String
    /// Missing in older documents means Codex. Unknown providers fail decoding.
    public var provider: ChatProvider?
    public var threadID: String?
    public var activeTurnID: String?
    public var draft: String
    public var attachments: [StoredAttachment]
    public var hasImages: Bool
    public var hasFiles: Bool?
    public var isVisible: Bool
    public var compactX: Double?
    public var compactY: Double?
    public var compactWidth: Double?
    public var compactHeight: Double?
    /// Only files owned by this note appear in its reusable attachment library.
    public var fileLibrary: [StoredAttachment]?
    public var expandedWidth: Double
    public var expandedHeight: Double
    public var composerHeight: Double?
    public var displayID: UInt32?
    public var pendingSubmission: PendingMessage?
    public var needsReconciliation: Bool?
    public var deletionPending: Bool?
    /// Historical image references, including images shared by copied notes.
    /// Nil on legacy notes means references may need to be recovered from history.
    public var referencedImagePaths: [String]?
    public init(id: UUID, title: String, model: String, effort: String, threadID: String? = nil,
                activeTurnID: String? = nil, draft: String = "", attachments: [StoredAttachment] = [],
                hasImages: Bool = false, isVisible: Bool = true, compactX: Double? = nil,
                compactY: Double? = nil, expandedWidth: Double = 500, expandedHeight: Double = 640,
                displayID: UInt32? = nil, pendingSubmission: PendingMessage? = nil, needsReconciliation: Bool? = nil,
                composerHeight: Double? = nil, provider: ChatProvider? = nil,
                deletionPending: Bool? = nil, referencedImagePaths: [String]? = nil,
                compactWidth: Double? = nil, compactHeight: Double? = nil,
                fileLibrary: [StoredAttachment]? = nil, hasFiles: Bool? = nil) {
        self.id = id; self.title = title; self.model = model; self.effort = effort
        self.provider = provider
        self.threadID = threadID; self.activeTurnID = activeTurnID; self.draft = draft
        self.attachments = attachments; self.hasImages = hasImages; self.isVisible = isVisible
        self.hasFiles = hasFiles
        self.compactX = compactX; self.compactY = compactY
        self.compactWidth = compactWidth; self.compactHeight = compactHeight
        self.fileLibrary = fileLibrary
        self.expandedWidth = expandedWidth; self.expandedHeight = expandedHeight
        self.displayID = displayID; self.pendingSubmission = pendingSubmission
        self.needsReconciliation = needsReconciliation
        self.deletionPending = deletionPending
        self.referencedImagePaths = referencedImagePaths
        self.composerHeight = composerHeight.map { Self.normalizedComposerHeight($0) }
    }

    public static func normalizedComposerHeight(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 64 }
        return min(320, max(44, value))
    }
    public static func normalizedCompactWidth(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 220 }
        return min(640, max(160, value))
    }
    public static func normalizedCompactHeight(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 40 }
        return min(160, max(36, value))
    }
}

public struct AppDocument: Codable, Sendable {
    public var version: Int = 1
    public var cliPath: String = ""
    public var defaultModelID: String = ""
    public var defaultEffort: String = ""
    public var defaultProvider: ChatProvider?
    public var claudeCLIPath: String?
    public var claudeEnabled: Bool?
    /// Absent in older documents; callers retain the existing Codex sign-in mode.
    /// Unknown values must fail decoding rather than select a billing mode.
    public var authenticationMode: AuthenticationMode?
    public var inactiveNoteOpacity: Double?
    public var notes: [StoredNote] = []
    public init() {}

    public static func normalizedInactiveNoteOpacity(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0.6 }
        return min(1, max(0.2, value))
    }
}

public struct NotePersistence {
    public let directory: URL
    public var documentURL: URL { directory.appendingPathComponent("notes.json") }
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> AppDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return AppDocument() }
        let document = try JSONDecoder().decode(AppDocument.self, from: Data(contentsOf: documentURL))
        guard document.version == 1 else { throw PersistenceError.unsupportedVersion(document.version) }
        return document
    }
    public func save(_ document: AppDocument) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
    }
    public func attachmentDirectory(noteID: UUID) throws -> URL {
        let url = directory.appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(noteID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func removeUnusedAttachments(for noteID: UUID, referencedPaths: [String], remainingNotes: [StoredNote],
                                        ownedAttachments: [StoredAttachment] = []) throws {
        // Older notes may refer to a copied image in another note's directory.
        // Until their history has been read, preserving that file is safer than
        // breaking a surviving conversation that is currently offline.
        let unknownLegacyImages = remainingNotes.contains(where: { $0.hasImages && $0.referencedImagePaths == nil })
        let modernPaths = Set(ownedAttachments.filter { $0.kind != nil }.map(\.path))
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        var protected: Set<String> = []
        for note in remainingNotes {
            let paths = (note.referencedImagePaths ?? []) + note.attachments.map(\.path)
            let library = (note.fileLibrary ?? []).map(\.path)
            let pending = note.pendingSubmission?.attachments.map(\.path) ?? []
            protected.formUnion((paths + library + pending).map(normalized))
        }
        let prefix = directory.standardizedFileURL.appendingPathComponent("Attachments").path + "/"
        var candidates = Set<[String]>()
        for name in try ConfinedFileDeletion.childNames(root: directory, components: ["Attachments", noteID.uuidString]) {
            candidates.insert([noteID.uuidString, name])
        }
        for path in referencedPaths {
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            if absolute.hasPrefix(prefix) {
                candidates.insert(absolute.dropFirst(prefix.count).split(separator: "/").map(String.init))
            }
        }
        let targets: [ConfinedFileDeletion.Target] = candidates.compactMap { parts -> ConfinedFileDeletion.Target? in
            guard parts.count == 2, UUID(uuidString: parts[0]) != nil,
                  AttachmentStore.isManagedFilename(parts[1]) else { return nil }
            let path = directory.appendingPathComponent("Attachments").appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).path
            if unknownLegacyImages && parts[1].hasSuffix(".png") && !modernPaths.contains(path) { return nil }
            guard !protected.contains(normalized(path)) else { return nil }
            return .init(root: directory, components: ["Attachments"] + parts, kind: .file)
        }
        try ConfinedFileDeletion.remove(targets)
        try ConfinedFileDeletion.remove([.init(root: directory, components: ["FileScratch", noteID.uuidString], kind: .directory)])
    }
    public enum PersistenceError: LocalizedError {
        case unsupportedVersion(Int)
        public var errorDescription: String? {
            switch self { case .unsupportedVersion(let version): return "Unsupported note data version: \(version). The original file has been preserved." }
        }
    }
}
