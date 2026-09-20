import Foundation
import Testing
@testable import StillnoteCore

@Suite(.serialized)
struct ChunkedModelDownloadTests {
    private func run(mode: String = "ok", seed: Bool = false) async throws -> (Data, [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunks = directory.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        if seed { try Data([0, 1, 2, 3]).write(to: chunks.appendingPathComponent("0")) }
        RangeProtocol.reset(mode: mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let downloader = ChunkedModelDownload(chunkSize: 4, concurrency: 2, configuration: configuration)
        let output = directory.appendingPathComponent("output")
        if mode == "failLast" {
            await #expect(throws: ChunkedModelDownload.Failure.self) {
                try await downloader.download(url: URL(string: "https://test.invalid/model")!, size: 10,
                                              directory: chunks, output: output, progress: { _ in })
            }
            #expect(ModelInstaller.hasExactSize(chunks.appendingPathComponent("0"), 4))
            #expect(ModelInstaller.hasExactSize(chunks.appendingPathComponent("1"), 4))
            RangeProtocol.reset(mode: "ok")
        }
        try await downloader.download(url: URL(string: "https://test.invalid/model")!, size: 10,
                                      directory: chunks, output: output, progress: { _ in })
        return (try Data(contentsOf: output), RangeProtocol.requests)
    }

    @Test func assemblesExactRangesIncludingShortFinalChunk() async throws {
        let (data, requests) = try await run()
        #expect(data == Data(0..<10))
        #expect(Set(requests) == Set(["bytes=0-3", "bytes=4-7", "bytes=8-9"]))
    }

    @Test func resumesCompletedChunks() async throws {
        let (data, requests) = try await run(seed: true)
        #expect(data == Data(0..<10))
        #expect(!requests.contains("bytes=0-3"))
    }

    @Test func retriesFailedInstallWithoutDownloadingCompletedChunksAgain() async throws {
        let (data, requests) = try await run(mode: "failLast")
        #expect(data == Data(0..<10))
        #expect(requests == ["bytes=8-9"])
    }

    @Test func retriesTransientFailure() async throws {
        let (data, requests) = try await run(mode: "retry")
        #expect(data == Data(0..<10))
        #expect(requests.filter { $0 == "bytes=0-3" }.count == 2)
    }

    @Test func rejectsIgnoredRanges() async {
        await #expect(throws: ChunkedModelDownload.Failure.self) { try await run(mode: "ignored") }
    }

    @Test func rejectsWrongContentRange() async {
        await #expect(throws: ChunkedModelDownload.Failure.self) { try await run(mode: "wrong") }
    }

    @Test func rejectsTruncatedBody() async {
        await #expect(throws: ChunkedModelDownload.Failure.self) { try await run(mode: "short") }
    }

    @Test func liveModelInstall() async throws {
        guard ProcessInfo.processInfo.environment["STILLNOTE_DOWNLOAD_TEST"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stillnote-download-validation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date()
        try await ModelInstaller(modelDirectory: directory).install(model: SpeechCatalog.defaultModel) { p in
            print("Model download: \(Int(p.fraction * 100))% \(p.detail)")
        }
        #expect(ModelInstaller.isInstalled(modelDirectory: directory, model: SpeechCatalog.defaultModel))
        print("Verified full model install in \(Date().timeIntervalSince(start)) seconds")
    }
}

private final class RangeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var mode = "ok"
    private static var seen: [String] = []
    static var requests: [String] { lock.withLock { seen } }
    static func reset(mode: String) { lock.withLock { self.mode = mode; seen = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")!
        let (mode, attempt) = Self.lock.withLock {
            Self.seen.append(range)
            return (Self.mode, Self.seen.filter { $0 == range }.count)
        }
        if mode == "retry", range == "bytes=0-3", attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let values = range.dropFirst(6).split(separator: "-").map { Int($0)! }
        let headers = ["Content-Range": mode == "wrong" ? "bytes 0-1/10" : "bytes \(values[0])-\(values[1])/10"]
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "ignored" ? 200 : 206,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = (mode == "short" || (mode == "failLast" && range == "bytes=8-9")) ? Data() : Data((values[0]...values[1]).map(UInt8.init))
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
