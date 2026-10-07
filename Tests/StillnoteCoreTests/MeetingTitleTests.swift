import Foundation
import Testing

@testable import StillnoteCore

/// Recordings and imports start with automatic titles. Only Name Meeting suggests a better
/// one, and `automaticTitle` records whether Stillnote or the user chose the current title.
@Suite struct MeetingTitleTests {
    private func meeting(automatic: Bool) -> Meeting {
        Meeting(
            id: "m1", title: CaptureOptions.defaultTitle(), audioName: "recording.wav", language: "en",
            speakerCount: nil, duration: 60, automaticTitle: automatic
        )
    }

    /// Name Meeting is an explicit request, so it replaces any title, and the result stays
    /// Stillnote's choice until the user types one.
    @Test(arguments: [true, false])
    func aSuggestedTitleReplacesTheCurrentOne(automatic: Bool) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(meeting(automatic: automatic))
        try await store.update("m1") { $0.applySuggestedTitle("Q3 launch readiness") }
        let saved = try await Store(paths: paths).get("m1")
        #expect(saved.title == "Q3 launch readiness")
        #expect(saved.automaticTitle)
    }

    @Test func defaultTitleNamesTheDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 26
        components.hour = 12
        let date = Calendar.current.date(from: components)!
        #expect(CaptureOptions.defaultTitle(for: date) == "Meeting · " + date.formatted(.dateTime.month(.abbreviated).day()))
        #expect(CaptureOptions.defaultTitle(for: date).hasPrefix("Meeting · "))
    }

    /// Legacy custom titles remain protected, as do custom interrupted-session titles.
    @Test func olderDocumentsDecodeAsUserNamed() throws {
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(#"""
            {"id":"m1","title":"Design review","created_at":"2026-09-01T10:00:00+00:00",
             "updated_at":"2026-09-01T10:00:00+00:00"}
            """#.utf8))
        #expect(meeting.automaticTitle == false)

        let options = try JSONDecoder().decode(CaptureOptions.self, from: Data(#"""
            {"title":"Standup","language":"auto","microphone_id":"","system_audio":true,"screen_video":false}
            """#.utf8))
        #expect(options.automaticTitle == false)

        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(#"""
            {"overview":"x","key_points":[],"decisions":[],"action_items":[],"provider":"codex",
             "model":"m","generated_at":"2026-09-01T10:00:00+00:00"}
            """#.utf8))
        #expect(summary.overview == "x")
    }

    @Test func automaticTitleSurvivesStorage() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(meeting(automatic: true))
        #expect(try await store.get("m1").automaticTitle)
        let options = try JSONDecoder().decode(
            CaptureOptions.self,
            from: try JSONEncoder().encode(CaptureOptions(title: "t", automaticTitle: true))
        )
        #expect(options.automaticTitle)
    }

    @Test(arguments: ["", " \n\t"])
    func anImportWithoutATypedTitleIsAutomatic(title: String) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let imported = try Meeting.imported(
            id: "import", from: URL(fileURLWithPath: "/synthetic/audio-2026-09-26.m4a"),
            title: title, language: "en", speakerCount: nil, duration: 60
        )
        #expect(imported.title == "audio-2026-09-26")
        #expect(imported.audioName == "audio-2026-09-26.m4a")
        try await store.insert(imported)
        let saved = try await Store(paths: paths).get(imported.id)
        #expect(saved.title == "audio-2026-09-26")
        #expect(saved.automaticTitle)
    }

    @Test(arguments: ["  Design review  ", "standup"])
    func aTitleTypedDuringImportIsTheUsers(title: String) throws {
        let original = try Meeting.imported(
            id: "import", from: URL(fileURLWithPath: "/synthetic/standup.m4a"),
            title: title, language: "en", speakerCount: nil, duration: 60
        )
        let imported = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        #expect(imported.title == title.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!imported.automaticTitle)
    }

    @Test func rejectsInvalidImportTitles() {
        #expect(throws: ValidationError.self) {
            try Meeting.imported(
                id: "import", from: URL(fileURLWithPath: "/synthetic/recording.wav"),
                title: String(repeating: "x", count: Validation.maxTitleLength + 1),
                language: "en", speakerCount: nil, duration: 60
            )
        }
    }

    private func legacyMeeting(
        title: String, audioName: String, automatic: Bool? = nil, ownershipVersion: Int? = nil
    ) throws -> Meeting {
        var document: [String: Any] = [
            "id": "legacy", "title": title, "audio_name": audioName,
            "created_at": "2026-09-26T12:00:00+00:00", "updated_at": "2026-09-26T12:00:00+00:00",
        ]
        if let automatic { document["automatic_title"] = automatic }
        if let ownershipVersion { document["title_ownership_version"] = ownershipVersion }
        return try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: document))
    }

    @Test func aLegacyRecordingPlaceholderIsAutomatic() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        let recorded = try legacyMeeting(title: CaptureOptions.defaultTitle(for: date), audioName: "recording.wav")
        #expect(recorded.automaticTitle)
    }

    @Test func aPreviouslyResavedRecordingPlaceholderStaysAutomatic() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        let recorded = try legacyMeeting(
            title: CaptureOptions.defaultTitle(for: date), audioName: "recording.wav", automatic: false
        )
        #expect(recorded.automaticTitle)
        try await store.insert(recorded)
        #expect(try await Store(paths: paths).get(recorded.id).automaticTitle)
    }

    @Test(arguments: ["My design review", "recording"])
    func oldRecordingsWithExplicitCustomTitlesRemainProtected(title: String) throws {
        let recorded = try legacyMeeting(title: title, audioName: "recording.wav", automatic: false)
        #expect(!recorded.automaticTitle)
    }

    @Test(arguments: ["audio-2026-09-26", "audio-2026-09-26.m4a"])
    func aLegacyImportFilenameIsAutomatic(title: String) throws {
        let imported = try legacyMeeting(title: title, audioName: "audio-2026-09-26.m4a")
        #expect(imported.automaticTitle)
    }

    @Test(arguments: ["standup", "standup.m4a"])
    func importsSavedWithTheOldFalseFlagAreAutomatic(title: String) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let imported = try legacyMeeting(title: title, audioName: "standup.m4a", automatic: false)
        #expect(imported.automaticTitle)
        try await store.insert(imported)
        let saved = try await Store(paths: paths).get(imported.id)
        #expect(saved.title == title)
        #expect(saved.automaticTitle)
    }

    @Test func migratedImportOwnershipStaysExplicitAfterATitleChoice() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(legacyMeeting(title: "standup", audioName: "standup.m4a", automatic: false))
        try await store.update("legacy") { $0.automaticTitle = false }
        let saved = try await Store(paths: paths).get("legacy")
        #expect(saved.title == "standup")
        #expect(!saved.automaticTitle)
    }

    @Test(arguments: ["standup", "standup.m4a"])
    func correctedImportOwnershipProtectsEvenAFilenameTitle(title: String) throws {
        let imported = try legacyMeeting(
            title: title, audioName: "standup.m4a", automatic: false, ownershipVersion: 1
        )
        #expect(!imported.automaticTitle)
    }

    @Test func oldImportsWithCustomTitlesRemainProtected() throws {
        let imported = try legacyMeeting(title: "My design review", audioName: "standup.m4a", automatic: false)
        #expect(!imported.automaticTitle)
    }

    @Test func explicitUserTitleOwnershipOverridesLegacyInference() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        for (title, audioName) in [
            (CaptureOptions.defaultTitle(for: date), "recording.wav"),
            ("recording", "recording.wav"),
        ] {
            let named = try legacyMeeting(
                title: title, audioName: audioName, automatic: false, ownershipVersion: 1
            )
            #expect(!named.automaticTitle)
        }
    }

    /// Naming is a separate request, so a summary response carries no title and a custom
    /// summary prompt can no longer leave meetings unnamed.
    @Test func summariesNoLongerAskForATitle() throws {
        #expect((Summarizer.schema["properties"] as? [String: Any])?["title"] == nil)
        #expect((Summarizer.schema["required"] as? [String])?.contains("title") == false)
        #expect(!Summarizer.defaultAgentPrompt.contains(#""title""#))
        // A provider that still sends one is ignored rather than rejected.
        let parsed = try Summarizer.parse(
            #"{"title":"Hiring plan","overview":"x","key_points":[],"decisions":[],"action_items":[]}"#
        )
        #expect(parsed.overview == "x")
    }

    /// Saving settings stores the default prompt verbatim, so the old default is upgraded;
    /// a prompt the user wrote is left alone.
    @Test func upgradesTheStoredLegacyDefaultPrompt() {
        let titled = AppSettings.migrating(from: ["summary": ["provider": "codex", "agent_prompt": Summarizer.titledAgentPrompt]])
        #expect(titled.settings.summary.agentPrompt == Summarizer.defaultAgentPrompt)
        #expect(titled.changed)
        let custom = AppSettings.migrating(from: ["summary": ["provider": "codex", "agent_prompt": "Be brief."]])
        #expect(custom.settings.summary.agentPrompt == "Be brief.")
    }
}
