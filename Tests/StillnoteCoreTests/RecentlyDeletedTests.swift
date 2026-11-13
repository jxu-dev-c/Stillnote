import Foundation
import Testing
@testable import StillnoteCore

@Suite struct RecentlyDeletedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func archiveSurvivesReopenAndRestoresContentAndMedia() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var meeting = Meeting(id: "deleted", title: "Synthetic planning", audioName: "a.wav", language: "en", speakerCount: nil, duration: 60)
        meeting.notes = "Keep these notes"
        meeting.starred = true
        meeting.segments = [Segment(id: "one", start: 0, end: 1, speaker: "s1", text: "Searchable synthetic discussion")]
        try await store.insert(meeting)
        try Data([1, 2, 3]).write(to: paths.audioURL(meeting.id))
        try Data([4, 5]).write(to: paths.videoURL(meeting.id))
        try await store.moveToRecentlyDeleted(meeting.id, now: now)
        #expect(try await store.list().isEmpty)
        #expect(try await store.libraryItems().isEmpty)
        #expect(try await store.searchLibrary("synthetic").isEmpty)
        let reopened = try Store(paths: paths)
        #expect(try await reopened.recentlyDeleted().first?.expiresAt == now.addingTimeInterval(5 * 86400))
        let restored = try await reopened.restoreDeleted(meeting.id, now: now.addingTimeInterval(4 * 86400))
        #expect(restored.notes == meeting.notes && restored.segments == meeting.segments && restored.starred)
        #expect(try Data(contentsOf: paths.audioURL(meeting.id)) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: paths.videoURL(meeting.id)) == Data([4, 5]))
        #expect(try await reopened.recentlyDeleted().isEmpty)
        #expect(try await reopened.libraryItems().count == 1)
    }

    @Test func fiveDayBoundaryPurgesOnlyExpiredRecordsAndMedia() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        for id in ["expired", "recent"] {
            try await store.insert(Meeting(id: id, title: id, audioName: "a.wav", language: "en", speakerCount: nil, duration: 1))
            try Data([1]).write(to: paths.audioURL(id))
            try Data([2]).write(to: paths.videoURL(id))
            try await store.moveToRecentlyDeleted(id, now: now.addingTimeInterval(id == "recent" ? 60 : 0))
        }
        let expiry = now.addingTimeInterval(DeletedMeeting.retention)
        #expect(try await store.purgeExpiredDeleted(now: expiry.addingTimeInterval(-1)).isEmpty)
        await #expect(throws: StoreError.self) { try await store.restoreDeleted("expired", now: expiry) }
        #expect(try await store.purgeExpiredDeleted(now: expiry) == ["expired"])
        #expect(!FileManager.default.fileExists(atPath: paths.audioURL("expired").path))
        #expect(!FileManager.default.fileExists(atPath: paths.videoURL("expired").path))
        #expect(FileManager.default.fileExists(atPath: paths.audioURL("recent").path))
        #expect(try await store.recentlyDeleted().map(\.id) == ["recent"])
        #expect(try await store.purgeExpiredDeleted(now: expiry).isEmpty)
    }

    @Test func voiceprintsRestoreUnlessExplicitlyForgotten() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var meeting = Meeting(id: "voice", title: "Voice", audioName: "a.wav", language: "en", speakerCount: nil, duration: 30)
        meeting.segments = [Segment(id: "one", start: 0, end: 25, speaker: "s1", text: "Synthetic speech")]
        try await store.insert(meeting)
        let prints = MeetingVoiceprints(meetingID: meeting.id,
            fingerprint: VoiceRecognition.fingerprint(of: meeting, modelRevision: "test"),
            modelRevision: "test", voiceprints: [Voiceprint(speaker: "s1", vector: [1, 0], speechSeconds: 25, windows: 2)], tooShort: [])
        try await store.saveVoiceprints(prints)
        try await store.moveToRecentlyDeleted(meeting.id, now: now)
        #expect(try await store.allVoiceprints().isEmpty)
        try await store.restoreDeleted(meeting.id, now: now)
        #expect(try await store.voiceprints(meeting.id) != nil)
        try await store.moveToRecentlyDeleted(meeting.id, now: now)
        try await store.forgetVoices()
        try await store.restoreDeleted(meeting.id, now: now)
        #expect(try await store.voiceprints(meeting.id) == nil)
    }

    @Test func processingAndReadOnlyDeletionAreRejected() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var meeting = Meeting(id: "busy", title: "Busy", audioName: "a.wav", language: "en", speakerCount: nil, duration: 1)
        meeting.status = .transcribing
        try await store.insert(meeting)
        await #expect(throws: ValidationError.self) { try await store.moveToRecentlyDeleted("busy", now: now) }
        #expect(try await store.get("busy").status == .transcribing)
        #expect(try await store.recentlyDeleted().isEmpty)
        let reader = try Store(paths: paths, readOnly: true)
        await #expect(throws: StoreError.self) { try await reader.moveToRecentlyDeleted("busy") }
        await #expect(throws: StoreError.self) { try await reader.restoreDeleted("busy") }
        await #expect(throws: StoreError.self) { try await reader.purgeExpiredDeleted() }
    }
}
