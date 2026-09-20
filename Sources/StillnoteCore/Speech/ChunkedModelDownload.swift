import Foundation

/// Bounded parallel transfers with durable chunks. The installer still verifies the
/// complete file's pinned SHA-256 before trusting it or marking the model ready.
struct ChunkedModelDownload {
    var chunkSize = 8 * 1024 * 1024
    var concurrency = 4
    var configuration: URLSessionConfiguration = .ephemeral

    enum Failure: LocalizedError {
        case unsupportedRanges, invalidResponse
        var errorDescription: String? {
            "The model host returned an unexpected response. Retry setup; completed download chunks are saved."
        }
    }

    func download(url: URL, size: Int, directory: URL, output: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = configuration
        config.httpMaximumConnectionsPerHost = concurrency
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: SecureModelRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let count = (size + chunkSize - 1) / chunkSize
        let tracker = ChunkProgress(total: size, report: progress)
        // Each worker holds at most one chunk in memory. Atomically saved chunks
        // survive failures/relaunches; incomplete chunks are requested again.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<min(concurrency, count) {
                group.addTask {
                    for index in stride(from: worker, to: count, by: concurrency) {
                        try Task.checkCancellation()
                        let start = index * chunkSize
                        let end = min(size, start + chunkSize) - 1
                        let length = end - start + 1
                        let file = directory.appendingPathComponent("\(index)")
                        if !ModelInstaller.hasExactSize(file, length) {
                            var request = URLRequest(url: url)
                            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                            request.setValue("Stillnote-local-model-setup/2", forHTTPHeaderField: "User-Agent")
                            for attempt in 0..<3 {
                                do {
                                    let validator = RangeResponseValidator(start: start, end: end, size: size)
                                    let data: Data
                                    let response: URLResponse
                                    do {
                                        (data, response) = try await session.data(for: request, delegate: validator)
                                    } catch {
                                        throw validator.failure ?? error
                                    }
                                    guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                                    if response.statusCode == 200 { throw Failure.unsupportedRanges }
                                    guard response.statusCode == 206,
                                          response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(size)",
                                          data.count == length else { throw Failure.invalidResponse }
                                    try data.write(to: file, options: .atomic)
                                    break
                                } catch {
                                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                                    if case Failure.unsupportedRanges = error { throw error }
                                    if attempt == 2 { throw error }
                                    try await Task.sleep(for: .seconds(attempt + 1))
                                }
                            }
                        }
                        await tracker.add(length)
                    }
                }
            }
            for try await _ in group {}
        }
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        for index in 0..<count {
            try Task.checkCancellation()
            try handle.write(contentsOf: Data(contentsOf: directory.appendingPathComponent("\(index)")))
        }
    }
}

private actor ChunkProgress {
    let total: Int
    let report: @Sendable (Double) -> Void
    var completed = 0
    init(total: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }
    func add(_ bytes: Int) {
        completed += bytes
        report(Double(completed) / Double(total))
    }
}

private final class SecureModelRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

/// Reject ignored or malformed ranges at headers, before buffering a full model.
private final class RangeResponseValidator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expected: String
    private let lock = NSLock()
    private var storedFailure: Error?
    var failure: Error? { lock.withLock { storedFailure } }
    init(start: Int, end: Int, size: Int) { expected = "bytes \(start)-\(end)/\(size)" }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        if http?.statusCode == 206, http?.value(forHTTPHeaderField: "Content-Range") == expected {
            completionHandler(.allow)
        } else {
            lock.withLock {
                storedFailure = http?.statusCode == 200
                    ? ChunkedModelDownload.Failure.unsupportedRanges
                    : ChunkedModelDownload.Failure.invalidResponse
            }
            completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
