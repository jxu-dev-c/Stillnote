import Foundation
import Testing

@testable import StillnoteCore

/// End-to-end transcription against the real installed MOSS checkpoint and the real
/// MOSS worker process. Opt in with STILLNOTE_INTEGRATION=1; it needs the downloaded
/// model and .venv-moss, and it occupies the GPU for a minute or two.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_INTEGRATION"] == "1"),
    .serialized,
    .timeLimit(.minutes(10))
)
struct TranscriptionIntegrationTests {
    private func installedPaths() throws -> Paths {
        let paths = try Paths.standard()
        try #require(
            SpeechStatus.current(modelDirectory: paths.modelDirectory).ready,
            "Download MOSS and run ./scripts/setup.sh before the integration tests."
        )
        return paths
    }

    @Test func transcribesARealRecordingThroughTheWorker() async throws {
        let paths = try installedPaths()
        let store = try Store(paths: paths)
        let meetings = try await store.list()
        let meeting = try #require(
            meetings.first { FileManager.default.fileExists(atPath: paths.audioURL($0.id).path) },
            "No stored recording to transcribe."
        )
        let service = TranscriptionService(modelDirectory: paths.modelDirectory)
        let stages = Mutex<[String]>([])
        let result = try await service.transcribe(
            audioURL: MediaFile.audioURL(for: meeting, paths: paths),
            model: SpeechCatalog.defaultModel, language: "auto", speakerCount: nil
        ) { _, stage in stages.withLock { $0.append(stage) } }

        #expect(!result.segments.isEmpty)
        #expect(result.duration > 0)
        #expect(result.segments.allSatisfy { $0.end >= $0.start && $0.end <= result.duration })
        #expect(result.segments.allSatisfy { result.speakers[$0.speaker] != nil })
        #expect(stages.withLock { $0.contains { $0.contains("Apple GPU") } })
    }

    /// Stopping must terminate the worker process, not just abandon it.
    @Test func cancellationStopsTheWorkerProcess() async throws {
        let paths = try installedPaths()
        let store = try Store(paths: paths)
        let meetings = try await store.list()
        let meeting = try #require(
            meetings.first { FileManager.default.fileExists(atPath: paths.audioURL($0.id).path) }
        )
        let service = TranscriptionService(modelDirectory: paths.modelDirectory)
        let task = Task {
            try await service.transcribe(
                audioURL: MediaFile.audioURL(for: meeting, paths: paths),
                model: SpeechCatalog.defaultModel, language: "auto", speakerCount: nil
            ) { _, _ in }
        }
        // Cancel while MOSS is still loading or encoding, before it can finish.
        try await Task.sleep(for: .seconds(3))
        task.cancel()
        await #expect(throws: Error.self) { try await task.value }

        try await Task.sleep(for: .seconds(4))
        #expect(runningWorkerCount() == 0, "A MOSS worker survived cancellation.")
    }

    private func runningWorkerCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").filter { $0.contains("moss_worker") }.count
    }
}

/// Minimal lock so the progress callback can collect stages from its own thread.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
