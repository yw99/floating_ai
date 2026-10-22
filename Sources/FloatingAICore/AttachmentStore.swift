import Foundation
import Darwin

/// Immutable, uniquely named copies. Paths supplied by a CLI never become imports.
public struct AttachmentStore: Sendable {
    public static let maximumFileBytes: Int64 = 100 * 1024 * 1024
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func noteDirectory(_ noteID: UUID) -> URL {
        directory.appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent(noteID.uuidString, isDirectory: true)
    }

    public static func isManagedFilename(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        return UUID(uuidString: ext.isEmpty ? name : url.deletingPathExtension().lastPathComponent) != nil &&
            ext.count <= 16 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    public func owns(_ attachment: StoredAttachment, noteID: UUID) -> Bool {
        let url = URL(fileURLWithPath: attachment.path).standardizedFileURL
        return url.deletingLastPathComponent() == noteDirectory(noteID).standardizedFileURL &&
            Self.isManagedFilename(url.lastPathComponent)
    }

    public func importFile(_ source: URL, noteID: UUID, name: String? = nil,
                           kind: StoredAttachment.Kind = .file) throws -> StoredAttachment {
        guard source.isFileURL else { throw AttachmentError.invalidFile }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw AttachmentError.unreadable }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.invalidFile }
        guard info.st_size <= Self.maximumFileBytes else { throw AttachmentError.tooLarge }
        let destination = try prepareDirectory(noteID)
        let id = UUID()
        let originalExtension = source.pathExtension.lowercased()
        let ext = originalExtension.count <= 16 && originalExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) ? originalExtension : "bin"
        let url = destination.appendingPathComponent(id.uuidString + (ext.isEmpty ? "" : "." + ext))
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AttachmentError.storage }
        var succeeded = false
        defer { close(output); if !succeeded { try? FileManager.default.removeItem(at: url) } }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), total: Int64 = 0
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw AttachmentError.unreadable }
            total += Int64(count)
            guard total <= Self.maximumFileBytes else { throw AttachmentError.tooLarge }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { throw AttachmentError.storage }
                    offset += written
                }
            }
        }
        guard fsync(output) == 0 else { throw AttachmentError.storage }
        succeeded = true
        return StoredAttachment(id: id, path: url.path, name: name ?? source.lastPathComponent, kind: kind, byteCount: total)
    }

    public func storePNG(_ data: Data, noteID: UUID, name: String) throws -> StoredAttachment {
        guard data.count <= Self.maximumFileBytes else { throw AttachmentError.tooLarge }
        let id = UUID(), folder = try prepareDirectory(noteID)
        let url = folder.appendingPathComponent(id.uuidString + ".png")
        let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw AttachmentError.storage }
        var succeeded = false
        defer { close(output); if !succeeded { try? FileManager.default.removeItem(at: url) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw AttachmentError.storage }
                offset += written
            }
        }
        guard fsync(output) == 0 else { throw AttachmentError.storage }
        succeeded = true
        return StoredAttachment(id: id, path: url.path, name: name, kind: .image, byteCount: Int64(data.count))
    }

    private func prepareDirectory(_ noteID: UUID) throws -> URL {
        let folder = noteDirectory(noteID)
        try Self.rejectLinkedDirectories([folder.deletingLastPathComponent(), folder])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Do not follow a substituted per-note folder or Attachments directory.
        for url in [folder, folder.deletingLastPathComponent()] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw AttachmentError.invalidFile }
        }
        return folder
    }

    public static func rejectLinkedDirectories(_ directories: [URL]) throws {
        for directory in directories {
            var information = stat()
            if lstat(directory.path, &information) == 0 {
                guard information.st_mode & S_IFMT == S_IFDIR else { throw AttachmentError.invalidFile }
            } else if errno != ENOENT { throw AttachmentError.storage }
        }
    }
}

public enum AttachmentError: Error, LocalizedError {
    case invalidFile, unreadable, tooLarge, storage, unavailable, outsideNote, unsupported, timeout, malformed
    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "Choose a regular file, not a folder or symbolic link."
        case .unreadable: return "This attachment could not be read. Check that it is available locally."
        case .tooLarge: return "This file exceeds the 100 MB attachment limit."
        case .storage: return "The attachment could not be saved. Check available disk space and permissions."
        case .unavailable: return "The bundled file reader is missing. Rebuild or reinstall Floating AI."
        case .outsideNote: return "Only files attached to this note can be read."
        case .unsupported: return "This file format is not supported by the file reader. Use PDF, DOCX, XLSX, or a text file."
        case .timeout: return "Reading this attachment timed out. Try a smaller file or a specific PDF page."
        case .malformed: return "This file could not be parsed. It may be damaged, encrypted, or too large to process."
        }
    }
}

/// A reversible wire envelope keeps native CLI history authoritative while the UI
/// displays the original message and document cards instead of a path manifest.
public enum AttachmentMessage {
    private static let prefix = "[Floating AI attached files v1]\n"
    private struct Envelope: Codable {
        let message: String
        let files: [StoredAttachment]
    }
    public static func encode(text: String, attachments: [StoredAttachment]) -> String {
        let files = attachments.filter { !$0.isImage }
        guard !files.isEmpty || text.hasPrefix(prefix) else { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Envelope(message: text, files: files)), let json = String(data: data, encoding: .utf8) else { return text }
        return prefix + json
    }
    public static func decode(_ text: String) -> (text: String, files: [StoredAttachment]) {
        guard text.hasPrefix(prefix), text.utf8.count <= 2 * 1024 * 1024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.dropFirst(prefix.count).utf8)),
              envelope.files.count <= 100,
              envelope.files.allSatisfy({ !$0.isImage }) else { return (text, []) }
        return (envelope.message, envelope.files)
    }
}
