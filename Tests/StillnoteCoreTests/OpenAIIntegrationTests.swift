import Foundation
import Testing

@testable import StillnoteCore

/// One real Responses API request with synthetic content. Opt in explicitly, since it uses the
/// account's API credit:
/// `set -a; . ./.env; set +a; STILLNOTE_OPENAI_INTEGRATION=1 swift test --filter OpenAIIntegrationTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_OPENAI_INTEGRATION"] == "1"))
struct OpenAIIntegrationTests {
    @Test func picksTheTagThatFits() async throws {
        let key = try #require(
            OpenAICredentials.resolve(useKeychain: false, useShell: false)?.key,
            "Export OPENAI_API_KEY to run this test"
        )
        var meeting = Meeting(
            id: "synthetic-tags", title: "Backend interview loop debrief", audioName: "synthetic.wav",
            language: "en", speakerCount: 2, duration: 30
        )
        meeting.speakers = ["speaker_1": "Alex", "speaker_2": "Blair"]
        meeting.segments = [
            Segment(id: "s1", start: 0, end: 5, speaker: "speaker_1",
                    text: "Let's go over the three backend engineer candidates we interviewed this week."),
            Segment(id: "s2", start: 5, end: 10, speaker: "speaker_2",
                    text: "I'd extend an offer to Sam; the system design round was the strongest."),
            Segment(id: "s3", start: 10, end: 15, speaker: "speaker_1",
                    text: "Agreed. I'll ask the recruiter to prepare the offer letter today."),
        ]
        let tags = [
            MeetingTag(id: "t-hiring", name: "Hiring", color: .blue, position: 0),
            MeetingTag(id: "t-finance", name: "Quarterly finance", color: .green, position: 1),
            MeetingTag(id: "t-marketing", name: "Marketing campaigns", color: .orange, position: 2),
        ]
        let chosen = try await MeetingTagger.suggestTags(
            meeting: meeting, tags: tags, settings: TaggingSettings(), allowRemote: true, apiKey: key
        )
        print("OpenAI chose \(chosen) with \(TaggingSettings.defaultModel)")
        #expect(chosen.contains("t-hiring"))
        #expect(!chosen.contains("t-marketing"))
    }
}
