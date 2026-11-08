import Foundation
import SQLite3
import Testing

@testable import StillnoteCore

@Suite struct VoiceStoreTests {
    private let revision = "test-revision"

    private func meeting(_ id: String) -> Meeting {
        var result = Meeting(id: id, title: id, audioName: "a.wav", language: "en", speakerCount: nil, duration: 60)
        result.speakers = ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"]
        result.segments = [
            Segment(id: "one", start: 0, end: 20, speaker: "speaker_1", text: "Hello"),
            Segment(id: "two", start: 20, end: 40, speaker: "speaker_2", text: "Hi"),
        ]
        result.status = .complete
        result.summary = MeetingSummary(overview: "Hello", keyPoints: [], decisions: [], actionItems: [],
                                       provider: "test", model: "test", generatedAt: Meeting.now())
        return result
    }

    private func prints(for meeting: Meeting) -> MeetingVoiceprints {
        MeetingVoiceprints(
            meetingID: meeting.id, fingerprint: VoiceRecognition.fingerprint(of: meeting, modelRevision: revision),
            modelRevision: revision,
            voiceprints: [Voiceprint(speaker: "speaker_1", vector: [1, 0], speechSeconds: 19.8, windows: 2)],
            tooShort: []
        )
    }

    private func match(_ speaker: String, _ profile: String, score: Double = 0.8) -> VoiceMatch {
        VoiceMatch(speaker: speaker, decision: .assigned, profileID: profile, score: score)
    }

    @Test func voiceprintsRoundTripAndLeaveWithTheirMeeting() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let a = try await store.insert(meeting("a"))
        try await store.insert(meeting("b"))
        try await store.saveVoiceprints(prints(for: a))
        #expect(try await store.voiceprints("a") == prints(for: a))
        #expect(try await store.voiceprints("b") == nil)
        #expect(try await store.allVoiceprints().count == 1)

        try await store.delete("a")
        #expect(try await store.voiceprints("a") == nil)
        #expect(try await store.allVoiceprints().isEmpty)
    }

    @Test func staleVoiceprintsAreRefused() async throws {
        let store = try Store(paths: temporaryPaths())
        let original = try await store.insert(meeting("a"))
        try await store.update("a") { $0.segments[0].end = 19 }
        await #expect(throws: ValidationError.self) { try await store.saveVoiceprints(prints(for: original)) }
        // A text-only edit does not change what the voices were computed from.
        let current = try await store.update("a") { $0.segments[0].text = "Edited" }
        try await store.saveVoiceprints(prints(for: current))
    }

    @Test func voiceMatchesApplyAtomicallyAndKeepManualLinks() async throws {
        let store = try Store(paths: temporaryPaths())
        let ada = try await store.saveProfile(SpeakerProfile(name: "Ada"))
        let bo = try await store.saveProfile(SpeakerProfile(name: "Bo"))
        var original = meeting("a")
        original.speakerProfiles = ["speaker_2": bo.id]
        original.speakers["speaker_2"] = "Bo"
        try await store.insert(original)
        let fingerprint = VoiceRecognition.fingerprint(of: original, modelRevision: revision)

        let (updated, applied) = try await store.applyVoiceMatches(
            [match("speaker_1", ada.id, score: 0.91), match("speaker_2", ada.id),
             VoiceMatch(speaker: "speaker_3", decision: .assigned, profileID: ada.id, score: 0.9),
             VoiceMatch(speaker: "speaker_1", decision: .uncertain, profileID: bo.id, score: 0.7)],
            meetingID: "a", fingerprint: fingerprint, modelRevision: revision
        )
        #expect(applied.map(\.speaker) == ["speaker_1"])
        #expect(updated.speakerProfiles == ["speaker_1": ada.id, "speaker_2": bo.id])
        #expect(updated.autoSpeakerProfiles == ["speaker_1": 0.91])
        #expect(updated.speakerName("speaker_1") == "Ada")
        // A changed name makes the summary stale, exactly as a manual assignment does.
        #expect(updated.summary == nil)
        #expect(updated.status == .transcribed)

        // Assigning by hand confirms the match and removes its marker.
        let confirmed = try await store.assignProfile(ada.id, meetingID: "a", speakerID: "speaker_1")
        #expect(confirmed.autoSpeakerProfiles.isEmpty)
        #expect(confirmed.speakerProfiles["speaker_1"] == ada.id)
    }

    @Test func voiceMatchesAreRefusedForChangedOrBusyMeetings() async throws {
        let store = try Store(paths: temporaryPaths())
        let ada = try await store.saveProfile(SpeakerProfile(name: "Ada"))
        let original = try await store.insert(meeting("a"))
        let fingerprint = VoiceRecognition.fingerprint(of: original, modelRevision: revision)
        try await store.update("a") { $0.segments[1].speaker = "speaker_1" }
        await #expect(throws: ValidationError.self) {
            try await store.applyVoiceMatches([match("speaker_1", ada.id)], meetingID: "a",
                                              fingerprint: fingerprint, modelRevision: revision)
        }
        let busy = try await store.update("a") { $0.status = .summarizing }
        await #expect(throws: ValidationError.self) {
            try await store.applyVoiceMatches(
                [match("speaker_1", ada.id)], meetingID: "a",
                fingerprint: VoiceRecognition.fingerprint(of: busy, modelRevision: revision), modelRevision: revision
            )
        }
        #expect(try await store.get("a").speakerProfiles.isEmpty)
    }

    @Test func deletingAProfileRemovesItsVoiceMarkers() async throws {
        let store = try Store(paths: temporaryPaths())
        let ada = try await store.saveProfile(SpeakerProfile(name: "Ada"))
        let original = try await store.insert(meeting("a"))
        _ = try await store.applyVoiceMatches(
            [match("speaker_1", ada.id)], meetingID: "a",
            fingerprint: VoiceRecognition.fingerprint(of: original, modelRevision: revision), modelRevision: revision
        )
        let changed = try await store.deleteProfile(ada.id)
        #expect(changed.first?.speakerProfiles.isEmpty == true)
        #expect(changed.first?.autoSpeakerProfiles.isEmpty == true)
    }

    @Test func theLearnedModelPersistsAndCanBeForgotten() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let a = try await store.insert(meeting("a"))
        #expect(try await store.voiceModel() == nil)
        let model = VoiceModel(
            modelRevision: revision, learnedAt: Meeting.now(), rule: .fallback, calibrated: false,
            metrics: VoiceMetrics(recognizable: 0, strangers: 1, correct: 0, wrong: 0, abstained: 1),
            profileCount: 1, sampleCount: 1, meetingCount: 1, skippedMeetings: 0
        )
        try await store.saveVoiceModel(model)
        try await store.saveVoiceprints(prints(for: a))
        #expect(try await Store(paths: paths, readOnly: true).voiceModel() == model)
        try await store.forgetVoices()
        #expect(try await store.voiceModel() == nil)
        #expect(try await store.allVoiceprints().isEmpty)
    }

    /// A library written before voice recognition opens read-only with no voices, and a
    /// writable open adds the tables without touching meetings.
    @Test func olderLibrariesHaveNoVoicesUntilMigrated() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        var database: OpaquePointer?
        #expect(sqlite3_open(paths.databaseURL.path, &database) == SQLITE_OK)
        let legacy = String(decoding: try JSONEncoder().encode(meeting("a")), as: UTF8.self)
        for sql in [
            "CREATE TABLE meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)",
            "CREATE TABLE settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL)",
            "INSERT INTO meetings VALUES ('a', '\(legacy.replacingOccurrences(of: "'", with: "''"))')",
        ] {
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(database)

        let readOnly = try Store(paths: paths, readOnly: true)
        #expect(try await readOnly.voiceModel() == nil)
        #expect(try await readOnly.voiceprints("a") == nil)
        #expect(try await readOnly.allVoiceprints().isEmpty)

        let writable = try Store(paths: paths)
        #expect(try await writable.get("a").autoSpeakerProfiles.isEmpty)
        #expect(try await writable.voiceModel() == nil)
    }

    @Test func settingsDefaultToManualTagging() throws {
        #expect(AppSettings().speakerRecognition.autoTagAfterTranscription == false)
        let (migrated, _) = AppSettings.migrating(from: [
            "speaker_recognition": ["auto_tag_after_transcription": true],
        ])
        #expect(migrated.speakerRecognition.autoTagAfterTranscription)
        var settings = AppSettings()
        settings.speakerRecognition.autoTagAfterTranscription = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.speakerRecognition.autoTagAfterTranscription)
    }
}
