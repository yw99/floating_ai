import Foundation
import Darwin

/// Removes explicitly selected application-owned paths without following links beneath
/// their configured root. Directory descriptors keep a concurrent rename or symlink
/// substitution from redirecting recursive deletion into another directory.
public enum ConfinedFileDeletion {
    public enum Kind: Sendable { case file, directory }
    public struct Target: Sendable {
        public let root: URL
        public let components: [String]
        public let kind: Kind
        public init(root: URL, components: [String], kind: Kind) {
            self.root = root; self.components = components; self.kind = kind
        }
    }
    public enum Failure: Error, LocalizedError {
        case unsafePath, accessDenied, changed
        public var errorDescription: String? {
            switch self {
            case .unsafePath: return "Deletion stopped because a conversation data path is unsafe or contains a symbolic link. The note has been kept."
            case .accessDenied: return "The conversation's local files could not be deleted. Check their access permissions and retry. The note has been kept."
            case .changed: return "The conversation's local files changed during deletion. The note has been kept; retry deletion after other applications finish using it."
            }
        }
    }
    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { close(value) }
    }
    private struct OpenTarget {
        let parent: Descriptor
        let name: String
        let kind: Kind
        let device: dev_t
        let inode: ino_t
    }

    /// All paths and their existing descendants are checked before the first unlink.
    /// Missing paths are an idempotent success. Callers persist their deletion intent
    /// because I/O errors can still occur after some independent files were removed.
    public static func remove(_ targets: [Target]) throws {
        var opened: [OpenTarget] = []
        for target in targets {
            try validate(target.components)
            guard let parent = try folder(root: target.root, components: Array(target.components.dropLast())) else { continue }
            let name = target.components.last!
            guard let information = try node(parent.value, name) else { continue }
            try checkKind(information, expected: target.kind)
            var remaining = 100_000
            try preflight(parent.value, name, remaining: &remaining, depth: 0)
            opened.append(OpenTarget(parent: parent, name: name, kind: target.kind,
                                     device: information.st_dev, inode: information.st_ino))
        }
        for target in opened {
            guard let current = try node(target.parent.value, target.name) else { continue }
            guard current.st_dev == target.device, current.st_ino == target.inode else { throw Failure.changed }
            try checkKind(current, expected: target.kind)
            try removeNode(target.parent.value, target.name, depth: 0)
        }
    }

    /// Lists only a named directory under a configured root, never following links.
    public static func childNames(root: URL, components: [String]) throws -> [String] {
        if !components.isEmpty { try validate(components) }
        guard let directory = try folder(root: root, components: components) else { return [] }
        return try names(directory.value)
    }

    private static func validate(_ components: [String]) throws {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) }) else {
            throw Failure.unsafePath
        }
    }
    private static func canonicalRoot(_ url: URL) throws -> String {
        guard url.isFileURL else { throw Failure.unsafePath }
        if let resolved = realpath(url.path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        guard errno == ENOENT else { throw Failure.accessDenied }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw Failure.unsafePath }
        let name = url.lastPathComponent
        try validate([name])
        return try canonicalRoot(parent) + "/" + name
    }
    private static func folder(root: URL, components: [String]) throws -> Descriptor? {
        let absolute = try canonicalRoot(root)
        let parts = absolute.split(separator: "/").map(String.init) + components
        var current = Descriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        guard current.value >= 0 else { throw Failure.accessDenied }
        for part in parts {
            let next = openat(current.value, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                if let information = try node(current.value, part), information.st_mode & S_IFMT == S_IFLNK { throw Failure.unsafePath }
                throw Failure.accessDenied
            }
            current = Descriptor(next)
        }
        return current
    }
    private static func node(_ parent: Int32, _ name: String) throws -> stat? {
        var information = stat()
        guard fstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.accessDenied
        }
        return information
    }
    private static func checkKind(_ information: stat, expected: Kind? = nil) throws {
        let kind = information.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw Failure.unsafePath }
        if let expected {
            switch expected {
            case .file: guard kind == S_IFREG else { throw Failure.unsafePath }
            case .directory: guard kind == S_IFDIR else { throw Failure.unsafePath }
            }
        }
    }
    private static func names(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw Failure.accessDenied }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw Failure.accessDenied }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Failure.accessDenied }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
    }
    private static func preflight(_ parent: Int32, _ name: String, remaining: inout Int, depth: Int) throws {
        remaining -= 1
        guard remaining >= 0, depth <= 64 else { throw Failure.unsafePath }
        guard let information = try node(parent, name) else { return }
        try checkKind(information)
        guard information.st_mode & S_IFMT == S_IFDIR else { return }
        let child = Descriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        guard child.value >= 0 else { throw Failure.accessDenied }
        for item in try names(child.value) { try preflight(child.value, item, remaining: &remaining, depth: depth + 1) }
    }
    private static func removeNode(_ parent: Int32, _ name: String, depth: Int) throws {
        guard depth <= 64 else { throw Failure.unsafePath }
        guard let information = try node(parent, name) else { return }
        try checkKind(information)
        if information.st_mode & S_IFMT == S_IFDIR {
            let child = Descriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            guard child.value >= 0 else { throw Failure.accessDenied }
            for item in try names(child.value) { try removeNode(child.value, item, depth: depth + 1) }
            guard let current = try node(parent, name) else { return }
            guard current.st_dev == information.st_dev, current.st_ino == information.st_ino else { throw Failure.changed }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw Failure.accessDenied }
        } else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw Failure.accessDenied }
        }
    }
}
