import Foundation
import Testing

@testable import StillnoteCore

/// Recordings and imports start with automatic titles that summaries may replace; a title the
/// user chose is never replaced.
@Suite struct MeetingTitleTests {
    private func summary(title: String?) -> MeetingSummary {
        MeetingSummary(
            overview: "We agreed.", keyPoints: [], decisions: [], actionItems: [], provider: "codex",
            model: "gpt-5-codex", generatedAt: Meeting.now(), title: title
        )
    }

    private func meeting(automatic: Bool) -> Meeting {
        Meeting(
            id: "m1", title: CaptureOptions.defaultTitle(), audioName: "recording.wav", language: "en",
            speakerCount: nil, duration: 60, automaticTitle: automatic
        )
    }

    @Test func summaryRetitlesAnUnnamedRecording() {
        var unnamed = meeting(automatic: true)
        unnamed.applySummary(summary(title: "  Q3 launch readiness  "))
        #expect(unnamed.title == "Q3 launch readiness")
        #expect(unnamed.summary?.overview == "We agreed.")
        // It stays automatic, so a later summary of a corrected transcript can improve it again.
        #expect(unnamed.automaticTitle)
    }

    @Test func summaryKeepsATitleTheUserChose() {
        var named = meeting(automatic: false)
        let original = named.title
        named.applySummary(summary(title: "Q3 launch readiness"))
        #expect(named.title == original)
        #expect(named.summary != nil)
    }

    @Test func summaryWithoutATitleKeepsThePlaceholder() {
        var unnamed = meeting(automatic: true)
        unnamed.applySummary(summary(title: nil))
        #expect(unnamed.title == CaptureOptions.defaultTitle())
        unnamed.applySummary(summary(title: "   "))
        #expect(unnamed.title == CaptureOptions.defaultTitle())
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
        #expect(summary.title == nil)
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
    func summaryRetitlesAnImportWithoutATypedTitle(title: String) async throws {
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
        try await store.update(imported.id) { $0.applySummary(summary(title: "Q3 launch readiness")) }
        let reopened = try Store(paths: paths)
        let saved = try await reopened.get(imported.id)
        #expect(saved.title == "Q3 launch readiness")
        #expect(saved.automaticTitle)
        #expect(saved.summary?.title == "Q3 launch readiness")
    }

    @Test(arguments: ["  Design review  ", "standup"])
    func summaryKeepsATitleTypedDuringImport(title: String) throws {
        let original = try Meeting.imported(
            id: "import", from: URL(fileURLWithPath: "/synthetic/standup.m4a"),
            title: title, language: "en", speakerCount: nil, duration: 60
        )
        var imported = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        imported.applySummary(summary(title: "Q3 launch readiness"))
        #expect(imported.title == title.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!imported.automaticTitle)
        #expect(imported.summary != nil)
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

    @Test func summaryRetitlesALegacyRecordingPlaceholder() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        var recorded = try legacyMeeting(title: CaptureOptions.defaultTitle(for: date), audioName: "recording.wav")
        #expect(recorded.automaticTitle)
        recorded.applySummary(summary(title: "Q3 launch readiness"))
        #expect(recorded.title == "Q3 launch readiness")
    }

    @Test func summaryRetitlesPreviouslyResavedRecordingPlaceholder() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        let recorded = try legacyMeeting(
            title: CaptureOptions.defaultTitle(for: date), audioName: "recording.wav", automatic: false
        )
        #expect(recorded.automaticTitle)
        try await store.insert(recorded)
        try await store.update(recorded.id) { $0.applySummary(summary(title: "Q3 launch readiness")) }
        #expect(try await Store(paths: paths).get(recorded.id).title == "Q3 launch readiness")
    }

    @Test(arguments: ["My design review", "recording"])
    func oldRecordingsWithExplicitCustomTitlesRemainProtected(title: String) throws {
        var recorded = try legacyMeeting(title: title, audioName: "recording.wav", automatic: false)
        recorded.applySummary(summary(title: "Q3 launch readiness"))
        #expect(recorded.title == title)
        #expect(!recorded.automaticTitle)
    }

    @Test(arguments: ["audio-2026-09-26", "audio-2026-09-26.m4a"])
    func summaryRetitlesALegacyImportFilename(title: String) throws {
        var imported = try legacyMeeting(title: title, audioName: "audio-2026-09-26.m4a")
        #expect(imported.automaticTitle)
        imported.applySummary(summary(title: "Q3 launch readiness"))
        #expect(imported.title == "Q3 launch readiness")
    }

    @Test(arguments: ["standup", "standup.m4a"])
    func summaryRetitlesImportsSavedWithTheOldFalseFlag(title: String) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let imported = try legacyMeeting(title: title, audioName: "standup.m4a", automatic: false)
        #expect(imported.automaticTitle)
        try await store.insert(imported)
        try await store.update(imported.id) { $0.applySummary(summary(title: "Q3 launch readiness")) }
        let saved = try await Store(paths: paths).get(imported.id)
        #expect(saved.title == "Q3 launch readiness")
        #expect(saved.automaticTitle)
    }

    @Test func migratedImportOwnershipStaysExplicitAfterATitleChoice() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(legacyMeeting(title: "standup", audioName: "standup.m4a", automatic: false))
        try await store.update("legacy") { $0.automaticTitle = false }
        let reopened = try Store(paths: paths)
        try await reopened.update("legacy") { $0.applySummary(summary(title: "Q3 launch readiness")) }
        let saved = try await reopened.get("legacy")
        #expect(saved.title == "standup")
        #expect(!saved.automaticTitle)
    }

    @Test(arguments: ["standup", "standup.m4a"])
    func correctedImportOwnershipProtectsEvenAFilenameTitle(title: String) throws {
        var imported = try legacyMeeting(
            title: title, audioName: "standup.m4a", automatic: false, ownershipVersion: 1
        )
        imported.applySummary(summary(title: "Q3 launch readiness"))
        #expect(imported.title == title)
        #expect(!imported.automaticTitle)
    }

    @Test func oldImportsWithCustomTitlesRemainProtected() throws {
        var imported = try legacyMeeting(title: "My design review", audioName: "standup.m4a", automatic: false)
        imported.applySummary(summary(title: "Q3 launch readiness"))
        #expect(imported.title == "My design review")
        #expect(!imported.automaticTitle)
    }

    @Test func explicitUserTitleOwnershipOverridesLegacyInference() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-26T12:00:00+00:00"))
        for (title, audioName) in [
            (CaptureOptions.defaultTitle(for: date), "recording.wav"),
            ("recording", "recording.wav"),
        ] {
            var named = try legacyMeeting(
                title: title, audioName: audioName, automatic: false, ownershipVersion: 1
            )
            named.applySummary(summary(title: "Q3 launch readiness"))
            #expect(named.title == title)
            #expect(!named.automaticTitle)
        }
    }

    @Test func parsesAndMergesSuggestedTitles() throws {
        let parsed = try Summarizer.parse(
            #"{"title":" \"Hiring  plan\" ","overview":"x","key_points":[],"decisions":[],"action_items":[]}"#
        )
        #expect(parsed.title == "Hiring plan")
        let untitled = try Summarizer.parse(#"{"overview":"x","key_points":[],"decisions":[],"action_items":[]}"#)
        #expect(untitled.title == nil)
        let long = Summarizer.title(String(repeating: "word ", count: 60))
        #expect((long?.count ?? 0) <= Summarizer.maxTitleLength + 1)

        let merged = Summarizer.merge([
            untitled, Summarizer.PartialSummary(overview: "y", keyPoints: [], decisions: [], actionItems: [], title: "Budget"),
        ])
        #expect(merged.title == "Budget")
    }

    @Test func schemaAndDefaultPromptAskForATitle() {
        #expect((Summarizer.schema["required"] as? [String])?.contains("title") == true)
        #expect(Summarizer.defaultAgentPrompt.contains(#""title""#))
    }

    /// Saving settings stores the default prompt verbatim, so the old default is upgraded;
    /// a prompt the user wrote is left alone.
    @Test func upgradesTheStoredLegacyDefaultPrompt() {
        let legacy = AppSettings.migrating(from: ["summary": ["provider": "codex", "agent_prompt": Summarizer.legacyAgentPrompt]])
        #expect(legacy.settings.summary.agentPrompt == Summarizer.defaultAgentPrompt)
        #expect(legacy.changed)
        let custom = AppSettings.migrating(from: ["summary": ["provider": "codex", "agent_prompt": "Be brief."]])
        #expect(custom.settings.summary.agentPrompt == "Be brief.")
    }
}
