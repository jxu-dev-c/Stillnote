import Foundation
import Testing
@testable import StillnoteCore

@Suite @MainActor struct RecordingRecoveryTests {
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
}
