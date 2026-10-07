import AVFoundation
import Foundation
import Testing
@testable import StillnoteCore

@Suite @MainActor struct RecordingRecoveryTests {
    @Test(arguments: [true, false])
    func savingARecordingPreservesTitleOwnership(automatic: Bool) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let title = CaptureOptions.defaultTitle()
        try writeSession(
            id: "title", paths: paths, options: CaptureOptions(title: title, automaticTitle: automatic)
        )
        let recorder = RecordingCoordinator(store: store, paths: paths)
        await recorder.recover()
        let meeting = try await recorder.finish()
        #expect(meeting.automaticTitle == automatic)
        let saved = try await Store(paths: paths).get(meeting.id)
        #expect(saved.title == title)
        #expect(saved.automaticTitle == automatic)
    }

    @Test func aSavedRecordingIsPlacedWhenCaptureStartedNotWhenItWasSaved() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        // Recovered the next day: the save time is far from when the meeting happened.
        let started = "2026-09-30T09:00:00.000+00:00"
        try writeSession(id: "dated", paths: paths, startedAt: started)
        try writeSession(id: "legacy", paths: paths)
        let recorder = RecordingCoordinator(store: store, paths: paths)

        await recorder.recover()
        let first = try await recorder.finish()
        await recorder.recover()
        let second = try await recorder.finish()
        let dated = try #require([first, second].first { $0.id == "dated" })
        let legacy = try #require([first, second].first { $0.id == "legacy" })

        #expect(dated.recordedAt == started)
        #expect(try await Store(paths: paths).get("dated").startDate == Meeting.parseTimestamp(started))
        // A session written before the start was recorded falls back to its save time.
        #expect(legacy.recordedAt == nil)
        #expect(abs(legacy.startDate.timeIntervalSince(legacy.createdDate) + legacy.duration) < 0.01)
    }

    @Test func trimmedSilenceMovesTheStartToTheKeptAudio() {
        #expect(RecordingCoordinator.keptAudioStart(startedAt: "2026-09-30T09:00:00.000+00:00", head: 90)
            == "2026-09-30T09:01:30.000+00:00")
        #expect(RecordingCoordinator.keptAudioStart(startedAt: nil, head: 90) == nil)
    }

    @Test func savedAudioSurvivesInterruptedTranscription() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try writeSession(id: "saved", paths: paths)
        let recorder = RecordingCoordinator(store: store, paths: paths)
        await recorder.recover()
        let meeting = try await recorder.finish()
        let audio = MediaFile.audioURL(for: meeting, paths: paths)
        #expect(try AVAudioFile(forReading: audio).length == Int64(captureRate))

        try await store.update(meeting.id) { $0.status = .transcribing }
        await recorder.shutdown()
        let reopened = try Store(paths: paths)
        try await reopened.markInterruptedJobs()
        let recovered = RecordingCoordinator(store: reopened, paths: paths)
        await recovered.recover()
        #expect(recovered.session == nil)
        #expect(try await reopened.get(meeting.id).status == .error)
        let decoded = try await AudioDecoder.decode(audio, to: paths.dataDirectory.appendingPathComponent("test.f32"))
        #expect(abs(decoded.duration - 1) < 0.01)
        #expect(decoded.peak > 0.2)
    }

    @Test func overlappingSavesKeepOneMeetingAndItsAudio() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try writeSession(id: "overlap", paths: paths)
        let recorder = RecordingCoordinator(store: store, paths: paths)
        await recorder.recover()

        let first = Task { try await recorder.finish() }
        let second = Task { try await recorder.finish() }
        let results = await [first.result, second.result]
        for result in results {
            #expect((try? result.get().id) == "overlap")
        }
        #expect(try await store.list().count == 1)
        #expect(FileManager.default.fileExists(atPath: paths.audioURL("overlap").path))
        let meeting = try await store.get("overlap")
        #expect(try AVAudioFile(forReading: MediaFile.audioURL(for: meeting, paths: paths)).length == Int64(captureRate))
        #expect(!recorder.isSaving)
    }

    @Test func discardDuringSavePreservesAudioAndTheNextRecoveredSession() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try writeSession(id: "first", paths: paths)
        try writeSession(id: "next", paths: paths)
        let recorder = RecordingCoordinator(store: store, paths: paths)
        await recorder.recover()

        let saving = Task { try await recorder.finish() }
        let discarding = Task { await recorder.discard() }
        let meeting = try await saving.value
        await discarding.value
        #expect(meeting.id == "first")
        #expect(try AVAudioFile(forReading: MediaFile.audioURL(for: meeting, paths: paths)).length == Int64(captureRate))
        #expect(recorder.session?.id == "next")
        #expect(FileManager.default.fileExists(atPath: paths.recordingsDirectory.appendingPathComponent("next/session.json").path))
    }

    @Test func failedSaveKeepsTheSourcesAndCanBeRetried() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let writable = try Store(paths: paths)
        let readOnly = try Store(paths: paths, readOnly: true)
        try writeSession(id: "retry", paths: paths)
        let recorder = RecordingCoordinator(store: readOnly, paths: paths)
        await recorder.recover()
        // Refuse the database commit after the audio has been written.
        await #expect(throws: StoreError.self) { try await recorder.finish() }
        #expect(!recorder.isSaving)
        #expect(recorder.session?.id == "retry")
        #expect(try await writable.list().isEmpty)
        let source = paths.recordingsDirectory.appendingPathComponent("retry/microphone.wav")
        #expect(try AVAudioFile(forReading: source).length == Int64(captureRate))

        let reopened = RecordingCoordinator(store: writable, paths: paths)
        await reopened.recover()
        let meeting = try await reopened.finish()
        #expect(try AVAudioFile(forReading: MediaFile.audioURL(for: meeting, paths: paths)).length == Int64(captureRate))
    }

    @Test func recoversInterruptedSessionAndPreservesItOnRepeatedLoad() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let directory = paths.recordingsDirectory.appendingPathComponent("interrupted")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = RecordingSessionState(
            id: "interrupted", status: .recording, elapsed: 42, error: nil,
            options: CaptureOptions(title: "Recovered meeting")
        )
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("session.json"))
        let recorder = RecordingCoordinator(store: store, paths: paths)
        await recorder.recover()
        #expect(recorder.isRecoveredSession)
        #expect(recorder.session?.id == state.id)
        #expect(recorder.session?.elapsed == 42)
        #expect(recorder.session?.error != nil)
        let recovered = recorder.session
        await recorder.recover()
        #expect(recorder.session == recovered)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    private func writeSession(
        id: String, paths: Paths, options: CaptureOptions = CaptureOptions(title: "Synthetic meeting"),
        startedAt: String? = nil
    ) throws {
        let directory = paths.recordingsDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = RecordingSessionState(
            id: id, status: .stopped, elapsed: 1, error: nil,
            options: options, startedAt: startedAt
        )
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("session.json"))
        let writer = try PCMWriter(url: directory.appendingPathComponent("microphone.wav"))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: writer.target, frameCapacity: UInt32(captureRate)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0.25, count: Int(buffer.frameLength))
        _ = try writer.append(buffer, at: 0)
        try writer.close()
    }
}
