import Foundation
import Testing

@testable import StillnoteCore

/// End-to-end transcription against the real installed MOSS checkpoint and the real
/// MOSS worker process. Opt in with STILLNOTE_INTEGRATION=1; it needs the downloaded
/// model and native worker, and it occupies the GPU for a minute or two.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_INTEGRATION"] == "1"),
    .serialized,
    .timeLimit(.minutes(10))
)
struct TranscriptionIntegrationTests {
    private var workerURL: URL {
        if let path = ProcessInfo.processInfo.environment["STILLNOTE_TEST_WORKER"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/StillnoteSpeechWorker")
    }

    private func installedPaths() throws -> Paths {
        let paths = try Paths.standard()
        try #require(
            ModelInstaller.isInstalled(modelDirectory: paths.modelDirectory, model: SpeechCatalog.defaultModel)
                && SpeechWorkerLocator.runtimeReady(worker: workerURL),
            "Download MOSS and run ./scripts/setup.sh before the integration tests."
        )
        return paths
    }

    @Test func transcribesARealRecordingThroughTheWorker() async throws {
        let paths = try installedPaths()
        let audio = try await fixtureAudio(paths: paths)
        let service = TranscriptionService(modelDirectory: paths.modelDirectory, workerURL: workerURL)
        let stages = Mutex<[String]>([])
        let result = try await service.transcribe(
            audioURL: audio,
            model: SpeechCatalog.defaultModel, language: "auto", speakerCount: nil
        ) { _, stage in stages.withLock { $0.append(stage) } }

        #expect(!result.segments.isEmpty)
        #expect(result.duration > 0)
        #expect(result.segments.allSatisfy { $0.end >= $0.start && $0.end <= result.duration })
        #expect(result.segments.allSatisfy { result.speakers[$0.speaker] != nil })
        #expect(stages.withLock { $0.contains { $0.contains("Apple GPU") } })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_HOT_WORDS_AUDIO"] != nil))
    func transcribesWithHotWords() async throws {
        let paths = try installedPaths()
        let audio = try #require(ProcessInfo.processInfo.environment["STILLNOTE_HOT_WORDS_AUDIO"])
        let result = try await TranscriptionService(modelDirectory: paths.modelDirectory, workerURL: workerURL).transcribe(
            audioURL: URL(fileURLWithPath: audio), model: SpeechCatalog.defaultModel,
            language: "en", speakerCount: 1, hotWords: ["Stillnote", "OpenMOSS"]
        ) { _, _ in }
        #expect(!result.segments.isEmpty)
        #expect(result.segments.allSatisfy { $0.end >= $0.start && $0.end <= result.duration })
        #expect(result.segments.allSatisfy { result.speakers[$0.speaker] != nil })
    }

    @Test func silenceReturnsNoSegmentsWithoutStartingWorker() async throws {
        let paths = try installedPaths()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        var wav = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        integer(UInt32(36 + 32000)); wav.append(Data("WAVEfmt ".utf8))
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16))
        wav.append(Data("data".utf8)); integer(UInt32(32000)); wav.append(Data(count: 32000))
        try wav.write(to: file)
        let stages = Mutex<[Double]>([])
        let result = try await TranscriptionService(modelDirectory: paths.modelDirectory, workerURL: workerURL)
            .transcribe(audioURL: file, model: SpeechCatalog.defaultModel, language: "auto", speakerCount: nil) {
                value, _ in stages.withLock { $0.append(value) }
            }
        #expect(result.segments.isEmpty)
        #expect(result.duration == 1)
        #expect(stages.withLock { $0 == [2] })
    }

    /// Stopping must terminate the worker process, not just abandon it.
    @Test func cancellationStopsTheWorkerProcess() async throws {
        let paths = try installedPaths()
        let audio = try await fixtureAudio(paths: paths)
        let service = TranscriptionService(modelDirectory: paths.modelDirectory, workerURL: workerURL)
        let task = Task {
            try await service.transcribe(
                audioURL: audio,
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

    private func fixtureAudio(paths: Paths) async throws -> URL {
        if let path = ProcessInfo.processInfo.environment["STILLNOTE_INTEGRATION_AUDIO"] {
            return URL(fileURLWithPath: path)
        }
        let store = try Store(paths: paths)
        let meeting = try #require(try await store.list().first {
            FileManager.default.fileExists(atPath: MediaFile.audioURL(for: $0, paths: paths).path)
        }, "Set STILLNOTE_INTEGRATION_AUDIO to a synthetic recording.")
        return MediaFile.audioURL(for: meeting, paths: paths)
    }

    private func runningWorkerCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "ppid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").filter { line in
            let columns = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            return columns.count == 2 && Int32(columns[0]) == getpid()
                && columns[1].hasSuffix("/StillnoteSpeechWorker")
        }.count
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
