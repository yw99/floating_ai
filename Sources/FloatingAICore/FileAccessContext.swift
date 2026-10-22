import Foundation
import Darwin

public struct FileAccessContext: Sendable, Equatable {
    public let directory: URL
    public let scratchDirectory: URL
    public let toolExecutable: URL
    public init(directory: URL, scratchDirectory: URL, toolExecutable: URL) {
        self.directory = directory.standardizedFileURL
        self.scratchDirectory = scratchDirectory.standardizedFileURL
        self.toolExecutable = toolExecutable.standardizedFileURL
    }

    /// A file belongs to exactly one flat note directory. No traversal, sibling
    /// roots, symbolic links, directories, devices or pipes are accepted.
    public func validatedPath(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.deletingLastPathComponent() == directory,
              AttachmentStore.isManagedFilename(url.lastPathComponent) else { throw AttachmentError.outsideNote }
        for candidate in [directory, directory.deletingLastPathComponent(), url] {
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AttachmentError.outsideNote }
        }
        return url
    }

    /// The descriptor is opened without following links and the bounded bytes are
    /// copied into the parser. Parsing never reopens a model-supplied path.
    public func readData(path: String) throws -> Data {
        let url = try validatedPath(path)
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw AttachmentError.unreadable }
        defer { close(folder) }
        let fd = openat(folder, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AttachmentError.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AttachmentError.invalidFile }
        guard info.st_size <= AttachmentStore.maximumFileBytes else { throw AttachmentError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw AttachmentError.unreadable }
            guard data.count + count <= AttachmentStore.maximumFileBytes else { throw AttachmentError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    public func runRead(path: String, page: Int? = nil) async throws -> JSONValue {
        _ = try validatedPath(path)
        if let page, !(1...100_000).contains(page) { throw AttachmentError.malformed }
        guard FileManager.default.isExecutableFile(atPath: toolExecutable.path) else { throw AttachmentError.unavailable }
        let runner = AttachmentReadProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                runner.start(context: self, path: path, page: page, continuation: continuation)
            }
        } onCancel: { runner.cancel() }
    }
}

/// Separate process bounds malformed documents and keeps decoding off the UI.
private final class AttachmentReadProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var overflow = false
    private var reachedEOF = false
    private var exitStatus: Int32?
    private var output = Data()
    private var waiter: CheckedContinuation<JSONValue, Error>?
    private let limit = 12 * 1024 * 1024

    func start(context: FileAccessContext, path: String, page: Int?, continuation: CheckedContinuation<JSONValue, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        waiter = continuation
        let child = Process(), pipe = Pipe()
        process = child
        child.executableURL = context.toolExecutable
        child.arguments = ["read", "--root", context.directory.path, "--scratch", context.scratchDirectory.path, "--path", path] +
            (page.map { ["--page", String($0)] } ?? [])
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        child.currentDirectoryURL = context.directory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [self] finished in
            lock.lock(); exitStatus = finished.terminationStatus; lock.unlock()
            completeIfReady()
        }
        do { try child.run() }
        catch {
            child.terminationHandler = nil
            process = nil; waiter = nil; lock.unlock()
            continuation.resume(throwing: AttachmentError.unavailable); return
        }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock()
                if output.count + chunk.count <= limit { output.append(chunk) }
                else { overflow = true; if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
                lock.unlock()
            }
            try? pipe.fileHandleForReading.close()
            lock.lock(); reachedEOF = true; lock.unlock()
            completeIfReady()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if let process = self.process, process.isRunning {
                self.timedOut = true; kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Either process termination or the pipe EOF can arrive first. Waiting on
    /// NSConcreteTask after a cancellation can miss its run-loop notification;
    /// finish once both independently delivered events have been observed.
    private func completeIfReady() {
        lock.lock()
        guard reachedEOF, let status = exitStatus, let completion = waiter else { lock.unlock(); return }
        waiter = nil
        let child = process; process = nil
        let result = output, didCancel = cancelled, didTimeOut = timedOut, didOverflow = overflow
        lock.unlock()
        child?.terminationHandler = nil
        if didCancel { completion.resume(throwing: CancellationError()) }
        else if didTimeOut { completion.resume(throwing: AttachmentError.timeout) }
        else if didOverflow || status != 0 { completion.resume(throwing: AttachmentError.malformed) }
        else if let value = try? JSONDecoder().decode(JSONValue.self, from: result) { completion.resume(returning: value) }
        else { completion.resume(throwing: AttachmentError.malformed) }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
