import Foundation
import Testing

@testable import StillnoteCore

/// Uses only synthetic content. Opt in explicitly: each provider may consume CLI usage.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_AGENT_INTEGRATION"] == "1"),
    .serialized
)
struct AgentIntegrationTests {
    @Test func savesARealCodexSummary() async throws {
        try await savesARealSummary(provider: .codex)
    }

    @Test func savesARealClaudeSummary() async throws {
        try await savesARealSummary(provider: .claudeCode)
    }

    private func savesARealSummary(provider: SummaryProvider) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var meeting = Meeting(
            id: "synthetic-summary", title: "Synthetic QA planning", audioName: "synthetic.wav",
            language: "en", speakerCount: 2, duration: 12
        )
        meeting.speakers = ["speaker_1": "Alex", "speaker_2": "Blair"]
        meeting.segments = [
            Segment(id: "s1", start: 0, end: 4, speaker: "speaker_1",
                    text: "We agreed to release the blue version on Friday."),
            Segment(id: "s2", start: 4, end: 8, speaker: "speaker_2",
                    text: "I will update the checklist by Thursday."),
            Segment(id: "s3", start: 8, end: 12, speaker: "speaker_1",
                    text: "I will test the recording controls tomorrow."),
        ]
        try await store.insert(meeting)
        let settings = SummarySettings(provider: provider)
        let summary = try Summarizer.summarize(
            meeting: meeting, settings: settings, allowRemote: true, videoPath: nil
        )
        #expect(!summary.overview.isEmpty)
        #expect(!summary.decisions.isEmpty)
        #expect(!summary.actionItems.isEmpty)
        #expect(summary.provider == provider.rawValue)
        #expect(summary.model == settings.model)
        _ = try await store.update(meeting.id) { $0.summary = summary; $0.status = .complete }
        let reopened = try Store(paths: paths)
        let saved = try await reopened.get(meeting.id)
        #expect(saved.summary == summary)
        #expect(saved.segments == meeting.segments)
    }
}
