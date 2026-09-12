import CryptoKit
import Foundation

public struct SpeechModelProgress: Sendable {
    public let fraction: Double
    public let detail: String
}

/// Downloads and verifies the pinned MOSS checkpoint. This is the only operation in
/// Stillnote that contacts a network host, and it transfers public model files only.
public actor ModelInstaller {
    public private(set) var isInstalling = false
    private let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public nonisolated static func isInstalled(modelDirectory: URL, model: String) -> Bool {
        guard let spec = try? SpeechCatalog.spec(model) else { return false }
        let directory = SpeechCatalog.directory(modelDirectory: modelDirectory, model: model)
        guard let verified = try? String(contentsOf: directory.appendingPathComponent(".verified"), encoding: .utf8),
              verified == spec.revision
        else { return false }
        return spec.files.allSatisfy { name, file in
            hasExactSize(directory.appendingPathComponent(name), file.size)
        }
    }

    nonisolated static func hasExactSize(_ url: URL, _ size: Int) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) == size
    }

    public func install(model: String, progress: @escaping @Sendable (SpeechModelProgress) -> Void) async throws {
        guard !isInstalling else { throw SpeechError.message("A model download is already in progress.") }
        isInstalling = true
        defer { isInstalling = false }

        let spec = try SpeechCatalog.spec(model)
        let directory = SpeechCatalog.directory(modelDirectory: modelDirectory, model: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".verified"))
        progress(.init(fraction: 0, detail: "Downloading speech models. No recordings or transcripts are sent."))

        let total = Double(spec.downloadBytes)
        var completed = 0.0
        for name in spec.files.keys.sorted() {
            let file = spec.files[name]!
            let destination = directory.appendingPathComponent(name)
            try await download(
                from: "https://huggingface.co/\(spec.repo)/resolve/\(spec.revision)/\(name)",
                to: destination, size: file.size, sha256: file.sha256
            ) { [completed] fraction in
                progress(.init(
                    fraction: (completed + fraction * Double(file.size)) / total * 0.99,
                    detail: "Downloading \(spec.name): \(name)"
                ))
            }
            if name.hasSuffix(".json") {
                let data = try Data(contentsOf: destination)
                guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw SpeechError.message("Model setup failed. Please retry setup.")
                }
            }
            completed += Double(file.size)
        }
        try Data(spec.revision.utf8).write(to: directory.appendingPathComponent(".verified"))
        progress(.init(
            fraction: 1, detail: "Speech model installed. Recording and transcription run locally."
        ))
    }

    private func download(
        from address: String, to destination: URL, size: Int, sha256: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if ModelInstaller.hasExactSize(destination, size),
           sha256 == nil || (try? digest(of: destination)) == sha256 {
            progress(1)
            return
        }
        guard let url = URL(string: address), url.scheme == "https" else {
            throw SpeechError.message("Model setup failed. Please retry setup.")
        }
        let partial = destination.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        let delegate = DownloadDelegate(expectedBytes: size, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Stillnote-local-model-setup/1", forHTTPHeaderField: "User-Agent")

        let temporary: URL
        do {
            temporary = try await delegate.run(session: session, request: request)
        } catch let error as SpeechError {
            throw error
        } catch {
            throw SpeechError.message(
                "Model setup failed. Check your internet connection and free disk space, then retry."
            )
        }
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: temporary, to: partial)
        guard ModelInstaller.hasExactSize(partial, size) else {
            throw SpeechError.message("Model download failed verification. Please retry setup.")
        }
        if let sha256, try digest(of: partial) != sha256 {
            throw SpeechError.message("Model download failed verification. Please retry setup.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
    }

    private func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports byte progress and refuses a redirect that would leave HTTPS.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var moved: URL?

    init(expectedBytes: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func run(session: URLSession, request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard expectedBytes > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temporary file is removed as soon as this callback returns, so claim it now.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-model-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: target)
        moved = target
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let status = (task.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            continuation.resume(throwing: SpeechError.message(
                "Model setup failed. Check your connection to the public model host, then retry."
            ))
        } else if let moved {
            continuation.resume(returning: moved)
        } else {
            continuation.resume(throwing: SpeechError.message("Model setup failed. Please retry setup."))
        }
    }
}
