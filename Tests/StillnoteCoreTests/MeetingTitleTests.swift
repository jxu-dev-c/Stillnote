import Foundation
import Testing

@testable import StillnoteCore

/// A recording starts with a placeholder title, and its summary may replace it; a title the
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

    /// Meetings and interrupted sessions saved before the flag existed were named by the user.
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
