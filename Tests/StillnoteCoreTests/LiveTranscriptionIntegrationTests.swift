import Foundation
import Testing
@testable import StillnoteCore

/// The live preview against the real models and a real long-lived worker process.
/// Opt in with STILLNOTE_INTEGRATION=1 and point STILLNOTE_INTEGRATION_AUDIO at a recording.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_INTEGRATION"] == "1"),
    .serialized,
    .timeLimit(.minutes(10))
)
struct LiveTranscriptionIntegrationTests {
    private var workerURL: URL {
        if let path = ProcessInfo.processInfo.environment["STILLNOTE_TEST_WORKER"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/StillnoteSpeechWorker")
    }

    @Test func previewsSpeakersWhileTheRecordingIsStillRunning() async throws {
        let paths = try Paths.standard()
        let samples = try await liveSamples(paths: paths)

        let updates = Mutex<[NemotronWorkerPartial]>([])
        let session = try LiveTranscriptionSession.start(
            modelDirectory: paths.modelDirectory, worker: workerURL,
            model: SpeechCatalog.nemotronModel, language: "en-US", speakerCount: nil,
            hotWords: []
        ) { partial in updates.withLock { $0.append(partial) } }

        // Feed in 320 ms blocks, the size the capture tap emits.
        let block = 5_120
        var offset = 0
        while offset < samples.count {
            let end = min(offset + block, samples.count)
            session.append(Array(samples[offset..<end]))
            offset = end
        }
        await session.finish()

        var accumulator = LiveTranscriptAccumulator()
        for partial in updates.withLock({ $0 }) { accumulator.apply(partial) }
        #expect(accumulator.isFinal, "the worker never sent a final partial")
        #expect(!accumulator.words.isEmpty)
        #expect(session.droppedSamples == 0)

        let preview = try accumulator.preview(duration: Double(samples.count) / 16_000)
        #expect(!preview.segments.isEmpty)
        #expect(preview.segments.allSatisfy { preview.speakers[$0.speaker] != nil })
        #expect(preview.segments.allSatisfy { $0.end >= $0.start })
        // Partials must arrive during the feed, not all at once at the end.
        #expect(updates.withLock { $0.count } > 1)
    }

    /// The live worker must be gone before the final transcription job starts, so the two
    /// never hold their models at the same time.
    @Test func finishingLeavesNoWorkerBehind() async throws {
        let paths = try Paths.standard()
        let samples = try await liveSamples(paths: paths)
        let session = try LiveTranscriptionSession.start(
            modelDirectory: paths.modelDirectory, worker: workerURL,
            model: SpeechCatalog.nemotronModel, language: "auto", speakerCount: nil,
            hotWords: []
        ) { _ in }
        session.append(Array(samples.prefix(16_000)))
        await session.finish()
        try await Task.sleep(for: .seconds(1))
        #expect(runningWorkerCount() == 0, "A live worker survived finish().")
    }

    @Test func cancellingMidStreamLeavesNoWorkerBehind() async throws {
        let paths = try Paths.standard()
        let samples = try await liveSamples(paths: paths)
        let session = try LiveTranscriptionSession.start(
            modelDirectory: paths.modelDirectory, worker: workerURL,
            model: SpeechCatalog.nemotronModel, language: "auto", speakerCount: nil,
            hotWords: []
        ) { _ in }
        session.append(Array(samples.prefix(160_000)))
        try await Task.sleep(for: .seconds(2))
        session.cancel()
        try await Task.sleep(for: .seconds(4))
        #expect(runningWorkerCount() == 0, "A live worker survived cancel().")
    }

    private func liveSamples(paths: Paths) async throws -> [Float] {
        try #require(
            ModelInstaller.isInstalled(
                modelDirectory: paths.modelDirectory, model: SpeechCatalog.nemotronModel
            ) && ModelInstaller.isInstalled(
                modelDirectory: paths.modelDirectory, model: SpeechCatalog.diarizationModel
            ) && SpeechWorkerLocator.runtimeReady(worker: workerURL),
            "Download the speech models before the live integration test."
        )
        let audio = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["STILLNOTE_INTEGRATION_AUDIO"],
            "Set STILLNOTE_INTEGRATION_AUDIO to a recording."
        ))
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let decoded = try await AudioDecoder.decode(audio, to: scratch)
        let data = try Data(contentsOf: decoded.pcmURL)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func runningWorkerCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "ppid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        process.waitUntilExit()
        return output.split(separator: "\n").filter { line in
            let columns = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            return columns.count == 2 && Int32(columns[0]) == getpid()
                && columns[1].hasSuffix("/StillnoteSpeechWorker")
        }.count
    }
}
