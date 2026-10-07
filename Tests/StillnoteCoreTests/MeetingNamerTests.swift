import Foundation
import Testing

@testable import StillnoteCore

/// What a title request sends. The request itself is exercised in `AgentRunnerTests`, which
/// owns the provider environment variables.
@Suite struct MeetingNamerTests {
    private func meeting(_ text: String = "We should ship the Q4 launch.") -> Meeting {
        var meeting = Meeting(id: "m1", title: "Meeting", audioName: "recording.wav", language: "en",
                              speakerCount: nil, duration: 60)
        meeting.speakers = ["speaker_1": "Dana"]
        meeting.segments = [Segment(id: "1", start: 0, end: 1, speaker: "speaker_1", text: text)]
        return meeting
    }

    @Test func prefersTheSummaryOverTheTranscript() throws {
        var summarized = meeting("TRANSCRIPT ONLY")
        summarized.summary = MeetingSummary(
            overview: "Launch readiness review.", keyPoints: ["Docs are late"], decisions: ["Ship Monday"],
            actionItems: [ActionItem(text: "Email legal")], provider: "codex", model: "m", generatedAt: Meeting.now()
        )
        let prompt = try MeetingNamer.prompt(summarized)
        #expect(prompt.contains("Launch readiness review."))
        #expect(prompt.contains("Ship Monday"))
        #expect(!prompt.contains("TRANSCRIPT ONLY"))
        // Action items add little to a topic and would only lengthen the request.
        #expect(!prompt.contains("Email legal"))
    }

    @Test func sendsTheOpeningOfALongTranscript() throws {
        var long = meeting()
        long.segments = (0..<2_000).map {
            Segment(id: "\($0)", start: Double($0), end: Double($0) + 1, speaker: "speaker_1",
                    text: "Line \($0) about the launch.")
        }
        let prompt = try MeetingNamer.prompt(long)
        #expect(prompt.contains("Dana: Line 0 about the launch."))
        #expect(!prompt.contains("Line 1999 "))
        // JSON escaping adds a byte per line break on top of the transcript budget.
        #expect(prompt.utf8.count < MeetingNamer.maxTranscriptBytes * 11 / 10)

        // One utterance longer than the budget is cut rather than dropped.
        let single = try MeetingNamer.prompt(meeting(String(repeating: "é", count: MeetingNamer.maxTranscriptBytes)))
        #expect(single.contains("Dana: éé"))
        #expect(single.utf8.count < MeetingNamer.maxTranscriptBytes + 1_000)
    }

    @Test func requiresConsentAndATranscript() {
        #expect(throws: SummaryError.self) {
            try MeetingNamer.suggestTitle(meeting: meeting(), settings: SummarySettings(), allowRemote: false)
        }
        var empty = meeting()
        empty.segments = []
        #expect(throws: SummaryError.self) { try MeetingNamer.prompt(empty) }
    }

    @Test func cleansSuggestedTitles() {
        #expect(MeetingNamer.title(" \"Hiring  plan\" ") == "Hiring plan")
        #expect(MeetingNamer.title("**Budget**") == "Budget")
        #expect(MeetingNamer.title("  ") == nil)
        #expect(MeetingNamer.title(nil) == nil)
        let long = MeetingNamer.title(String(repeating: "word ", count: 60))
        #expect((long?.count ?? 0) <= MeetingNamer.maxTitleLength + 1)
    }

    @Test func schemaAsksOnlyForATitle() {
        #expect(MeetingNamer.schema["required"] as? [String] == ["title"])
        #expect(MeetingNamer.instructions.contains(#"{"title":"#))
    }
}
