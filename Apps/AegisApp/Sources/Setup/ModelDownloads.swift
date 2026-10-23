import AegisKit
import CryptoKit
import Foundation

/// The models setup fetches in the background (ADR-0030): this Mac's chat model and the meaning model, from Hugging
/// Face at pinned revisions. Each file arrives as `.part`, is checked by SHA-256, and only then takes its real name;
/// finished files are kept, so a later run fetches only what's missing.
@MainActor @Observable
final class ModelDownloads {
    enum State: Equatable {
        case idle, downloading, ready
        case failed(String)
    }

    static let shared = ModelDownloads()

    private(set) var state = State.idle
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = 0
    private var running = false

    var fraction: Double {
        total > 0 ? Double(received) / Double(total) : state == .ready ? 1 : 0
    }

    /// Aegis's Models folder.
    static let folder = ModelChoice.aegisFolder?.appendingPathComponent("Models", isDirectory: true)

    /// Starts, or retries after a failure; does nothing while running.
    func start(_ models: [ModelFiles] = [ModelChoice.current.files, .meaning]) {
        Task { await fetch(models) }
    }

    /// Fetches what isn't in place yet; true once everything is, false if a file failed or a fetch is already running.
    @discardableResult
    func fetch(_ models: [ModelFiles], into folder: URL? = ModelDownloads.folder) async -> Bool {
        guard !running, let folder else { return false }
        running = true
        defer { running = false }
        let needed = models.filter { !Self.inHuggingFaceCache($0) }
        let missing = needed.flatMap { model in
            model.files.map { (model, $0) }.filter { !Self.inPlace($0.1, at: folder.appendingPathComponent($0.0.folderName)) }
        }
        total = needed.reduce(0) { $0 + $1.bytes }
        received = total - missing.reduce(0) { $0 + $1.1.bytes }
        let free = (try? folder.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let remaining = total - received
        guard remaining == 0 || free > remaining + 1_000_000_000 else {
            state = .failed("Needs \(HUDFormat.bytes(Double(remaining + 1_000_000_000))) free on this Mac.")
            return false
        }
        state = .downloading
        for (model, file) in missing {
            do {
                try await download(file, of: model, into: folder.appendingPathComponent(model.folderName))
            } catch {
                state = .failed(error.localizedDescription)
                return false
            }
        }
        state = .ready
        return true
    }

    private func download(_ file: ModelFiles.File, of model: ModelFiles, into folder: URL) async throws {
        guard let source = model.source(file) else { throw URLError(.badURL) }
        let target = folder.appendingPathComponent(file.path)
        let part = target.appendingPathExtension("part")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = received
        try await FileFetch(part: part) { written in
            Task { @MainActor in self.received = before + written }
        }.run(source)
        let sum = try await Task.detached { try Self.sha256(of: part) }.value
        guard sum == file.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw CocoaError(.fileReadCorruptFile)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        received = before + file.bytes
    }

    /// A file takes its real name only after its check, so one of the right size is a finished one.
    private static func inPlace(_ file: ModelFiles.File, at folder: URL) -> Bool {
        let size = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.path).path)[.size] as? Int64
        return size == file.bytes
    }

    /// A chat model already in a developer's pinned Hugging Face snapshot, which ModelService also loads from.
    private static func inHuggingFaceCache(_ model: ModelFiles) -> Bool {
        model != .meaning && FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + model.repository.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots/\(model.revision)/config.json").path)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file over a download task, which writes to disk as it goes, with progress every 8 MB.
private final class FileFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable { // privacy-guard: allow-network ADR-0030
    private let part: URL
    private let progress: @Sendable (Int64) -> Void
    // Touched only on the session's serial delegate queue, then once from `run` after it finishes.
    private var continuation: CheckedContinuation<Void, Error>?
    private var problem: Error?
    private var reported: Int64 = 0

    init(part: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.part = part
        self.progress = progress
    }

    func run(_ source: URL) async throws {
        // Ephemeral: no cookies, cache or credentials kept.
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil) // privacy-guard: allow-network ADR-0030
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(
        _: URLSession, // privacy-guard: allow-network ADR-0030
        downloadTask _: URLSessionDownloadTask, // privacy-guard: allow-network ADR-0030
        didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        if totalBytesWritten - reported >= 8 << 20 {
            reported = totalBytesWritten
            progress(totalBytesWritten)
        }
    }

    func urlSession(
        _: URLSession, // privacy-guard: allow-network ADR-0030
        downloadTask: URLSessionDownloadTask, // privacy-guard: allow-network ADR-0030
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns, so the file moves now.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            problem = URLError(.badServerResponse)
            return
        }
        do {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            problem = error
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) { // privacy-guard: allow-network ADR-0030
        if let failure = error ?? problem {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
