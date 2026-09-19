import Foundation
import Testing

@testable import StillnoteCore

private func meeting(segments: [Segment], speakers: [String: String] = [:]) -> Meeting {
    var meeting = Meeting(
        id: "m1", title: "Design review", audioName: "a.wav", language: "en", speakerCount: 2, duration: 60
    )
    meeting.segments = segments
    meeting.speakers = speakers
    return meeting
}

@Suite struct SummarizerTests {
    @Test func labelsUtterancesWithDisplayNames() throws {
        let source = meeting(
            segments: [Segment(id: "1", start: 0, end: 1, speaker: "speaker_1", text: "  hello   world ")],
            speakers: ["speaker_1": "Ada"]
        )
        let utterances = try Summarizer.utterances(source)
        #expect(utterances.count == 1)
        #expect(utterances[0].speaker == "Ada")
        #expect(utterances[0].text == "hello world")
    }

    @Test func refusesAnEmptyTranscript() {
        #expect(throws: SummaryError.self) { try Summarizer.utterances(meeting(segments: [])) }
    }

    /// Sections stay inside the byte budget, and one oversized utterance is split with
    /// its speaker label repeated so attribution survives the boundary.
    @Test func splitsLongTranscriptsOnByteBudgets() throws {
        let long = String(repeating: "word ", count: 6000)
        let chunks = try Summarizer.chunks([("Ada", long), ("Grace", "short reply")])
        #expect(chunks.count > 1)
        for chunk in chunks { #expect(chunk.utf8.count <= Summarizer.chunkBytes) }
        #expect(chunks.allSatisfy { $0.contains("Ada: ") || $0.contains("Grace: ") })
        #expect(chunks.last!.contains("Grace: short reply"))
    }

    @Test func rejectsTranscriptsBeyondTheSizeLimit() {
        let huge = (0..<80).map {
            Segment(id: "\($0)", start: 0, end: 1, speaker: "s", text: String(repeating: "x", count: 10_000))
        }
        #expect(throws: SummaryError.self) { try Summarizer.utterances(meeting(segments: huge)) }
    }

    @Test func parsesAndNormalizesAProviderResponse() throws {
        let json = """
            ```json
            {"overview":"  We agreed.  ","key_points":["A","a"],"decisions":["Ship"],
             "action_items":[{"text":" Write docs ","owner":"  ","due":null},
                             {"text":"Write docs","owner":null,"due":null}]}
            ```
            """
        let parsed = try Summarizer.parse(json)
        #expect(parsed.overview == "We agreed.")
        #expect(parsed.keyPoints == ["A"])
        #expect(parsed.actionItems.count == 1)
        #expect(parsed.actionItems[0].text == "Write docs")
        #expect(parsed.actionItems[0].owner == nil)
    }

    @Test func rejectsMalformedResponses() {
        #expect(throws: SummaryError.self) { try Summarizer.parse("not json") }
        #expect(throws: SummaryError.self) {
            try Summarizer.parse(#"{"overview":"","key_points":[],"decisions":[],"action_items":[]}"#)
        }
        #expect(throws: SummaryError.self) {
            try Summarizer.parse(#"{"overview":"x","key_points":[],"decisions":[],"action_items":[{}]}"#)
        }
    }

    /// Merging is local: every section's decisions and actions survive, and near
    /// duplicates among key points are collapsed.
    @Test func mergesSectionsWithoutLosingCommitments() {
        let first = Summarizer.PartialSummary(
            overview: "First half.", keyPoints: ["Latency budget is the blocker"],
            decisions: ["Adopt the new pipeline"],
            actionItems: [ActionItem(text: "File the ticket", owner: "Ada", due: nil)]
        )
        let second = Summarizer.PartialSummary(
            overview: "Second half.", keyPoints: ["Latency budget is the blocker"],
            decisions: ["Freeze the schema"],
            actionItems: [ActionItem(text: "File the ticket", owner: "Ada", due: nil),
                          ActionItem(text: "Draft the RFC", owner: nil, due: "Friday")]
        )
        let merged = Summarizer.merge([first, second])
        #expect(merged.overview == "First half.\n\nSecond half.")
        #expect(merged.decisions == ["Adopt the new pipeline", "Freeze the schema"])
        #expect(merged.actionItems.count == 2)
        #expect(merged.keyPoints.count == 1)
    }

    @Test func requiresExplicitRemoteConsent() {
        let source = meeting(segments: [Segment(id: "1", start: 0, end: 1, speaker: "s", text: "hello")])
        #expect(throws: SummaryError.self) {
            try Summarizer.summarize(
                meeting: source, settings: SummarySettings(), allowRemote: false, videoPath: nil
            )
        }
    }
}

@Suite struct ExporterTests {
    private func complete() -> Meeting {
        var source = meeting(
            segments: [
                Segment(id: "1", start: 0, end: 2, speaker: "speaker_1", text: "Kick off"),
                Segment(id: "2", start: 2, end: 4, speaker: "speaker_2", text: "Agreed"),
            ],
            speakers: ["speaker_1": "Ada", "speaker_2": "Grace"]
        )
        source.notes = "Room 4"
        source.contextLinks = [ContextLink(url: "https://example.com/a(b)", title: "Spec [v2]")]
        source.summary = MeetingSummary(
            overview: "Short overview.", keyPoints: ["One"], decisions: ["Ship it"],
            actionItems: [ActionItem(text: "Follow up", owner: "Ada", due: "Friday")],
            provider: "codex", model: "gpt-5.6-luna", generatedAt: "2026-01-01T00:00:00+00:00"
        )
        return source
    }

    @Test func writesMarkdownWithEscapedLinks() {
        let text = Exporter.text(complete(), format: .markdown)
        #expect(text.contains("# Design review"))
        #expect(text.contains("- Follow up — Owner: Ada — Due: Friday"))
        #expect(text.contains("Spec \\[v2\\]"))
        #expect(text.contains("(<https://example.com/a(b)>)"))
        #expect(text.contains("[00:00:02] Grace: Agreed"))
    }

    @Test func writesPlainTextAndSubtitles() {
        let source = complete()
        #expect(!Exporter.text(source, format: .text).contains("# "))
        let srt = Exporter.text(source, format: .subtitles)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nAda: Kick off"))
        #expect(srt.hasSuffix("\n"))
    }

    @Test func writesRoundTrippableJSON() throws {
        let json = Exporter.text(complete(), format: .json)
        let decoded = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        #expect(decoded.title == "Design review")
        #expect(decoded.segments.count == 2)
        #expect(decoded.summary?.actionItems.first?.due == "Friday")
    }

    @Test func suggestsASafeFilename() {
        var source = complete()
        source.title = "Q3 / planning: review"
        #expect(Exporter.suggestedFilename(source, format: .markdown) == "Q3   planning  review.md")
    }
}
