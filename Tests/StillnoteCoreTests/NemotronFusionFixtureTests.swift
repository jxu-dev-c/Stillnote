import Foundation
import Testing
@testable import StillnoteCore

/// Fusion checked against real model output.
///
/// This is one recorded run of the two Nemotron models over a scripted five-turn exchange
/// synthesized with the `Samantha` and `Daniel` voices — the same fixture
/// `scripts/verify-native.py` builds. Keeping the recognizer's words and the diarizer's
/// timeline as a literal means the fusion is covered against real emission-aligned timings and
/// real channel boundaries, with no CoreML and no 750 MB download in CI.
///
/// Regenerate with `scripts/verify-native.py --emit-fixture` after a model or geometry change,
/// and expect the recognized text to differ slightly: this is speech recognition, not a hash.
struct NemotronFusionFixtureTests {
    private static let recorded = #"""
{"language":"en-US","words":[{"text":"Good","start":0.4,"end":0.48},{"text":"morning.","start":0.56,"end":1.36},{"text":"Let's","start":1.28,"end":1.44},{"text":"start","start":1.52,"end":1.6},{"text":"the","start":1.76,"end":1.84},{"text":"design","start":1.92,"end":2.16},{"text":"review","start":2.32,"end":2.64},{"text":"for","start":2.8,"end":2.88},{"text":"the","start":2.88,"end":2.96},{"text":"audio","start":3.2,"end":3.6},{"text":"pipeline.","start":3.68,"end":5.2},{"text":"Thanks.","start":5.2,"end":5.84},{"text":"I","start":5.84,"end":5.92},{"text":"finished","start":6.08,"end":6.32},{"text":"the","start":6.4,"end":6.48},{"text":"encoder","start":6.8,"end":7.12},{"text":"worked","start":7.36,"end":7.6},{"text":"yesterday","start":7.6,"end":7.84},{"text":"in","start":8.32,"end":8.4},{"text":"the","start":8.4,"end":8.48},{"text":"latency","start":8.64,"end":8.96},{"text":"looks","start":9.12,"end":9.28},{"text":"good.","start":9.28,"end":10},{"text":"Excellent!","start":10,"end":10.64},{"text":"Did","start":10.8,"end":10.88},{"text":"you","start":10.96,"end":11.04},{"text":"measure","start":11.2,"end":11.44},{"text":"the","start":11.44,"end":11.52},{"text":"real","start":11.6,"end":11.76},{"text":"time","start":11.84,"end":11.92},{"text":"factor","start":12.24,"end":12.64},{"text":"on","start":12.72,"end":12.8},{"text":"the","start":12.88,"end":12.96},{"text":"neural","start":13.12,"end":13.52},{"text":"engine?","start":13.6,"end":14.16},{"text":"Yes,","start":14.32,"end":14.96},{"text":"it","start":15.04,"end":15.12},{"text":"runs","start":15.12,"end":15.36},{"text":"about","start":15.44,"end":15.52},{"text":"twenty","start":16,"end":16.08},{"text":"times","start":16.4,"end":16.56},{"text":"faster","start":16.88,"end":17.12},{"text":"than","start":17.2,"end":17.28},{"text":"real","start":17.6,"end":17.76},{"text":"time","start":17.92,"end":18},{"text":"on","start":18.16,"end":18.24},{"text":"this","start":18.32,"end":18.4},{"text":"machine.","start":18.56,"end":18.96},{"text":"That","start":19.28,"end":19.36},{"text":"is","start":19.44,"end":19.52},{"text":"a","start":19.84,"end":19.92},{"text":"solid","start":19.92,"end":20.08},{"text":"result.","start":20.32,"end":21.2},{"text":"Let's","start":21.28,"end":21.52},{"text":"ship","start":21.6,"end":21.76},{"text":"it","start":21.76,"end":21.84},{"text":"next","start":22,"end":22.24},{"text":"week","start":22.4,"end":22.48}],"activity":[{"speaker":0,"start":0,"end":4.21},{"speaker":1,"start":4.52,"end":9.33},{"speaker":0,"start":9.57,"end":13.62},{"speaker":1,"start":13.85,"end":19},{"speaker":0,"start":19.22,"end":22.58}]}
"""#

    private func fused(
        _ options: SpeakerAttribution.Options = .init()
    ) throws -> TranscriptionResult {
        let recorded = try JSONDecoder().decode(
            NemotronWorkerTranscript.self, from: Data(Self.recorded.utf8)
        )
        return try NemotronTranscript.build(
            words: recorded.words, activity: recorded.activity, duration: Self.duration,
            language: recorded.language, options: options
        )
    }

    private static let duration = 22.85

    @Test func separatesTheTwoSpeakersAcrossFiveTurns() throws {
        let result = try fused()
        // The script alternates Samantha, Daniel, Samantha, Daniel, Samantha.
        #expect(result.speakers == ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"])
        #expect(result.segments.map(\.speaker)
            == ["speaker_1", "speaker_2", "speaker_1", "speaker_2", "speaker_1"])
    }

    @Test func eachTurnKeepsTheWordsThatBelongToIt() throws {
        let result = try fused()
        let opening = try #require(result.segments.first)
        #expect(opening.text.hasPrefix("Good morning."))
        #expect(opening.text.contains("design review"))
        // The second turn is the other speaker and must not have absorbed the first's words.
        let second = try #require(result.segments.dropFirst().first)
        #expect(second.text.hasPrefix("Thanks."))
        #expect(!second.text.contains("Good morning"))
        #expect(try #require(result.segments.last).text.contains("next week"))
    }

    @Test func segmentsAreOrderedAndInsideTheRecording() throws {
        let result = try fused()
        var previousStart = -1.0
        for segment in result.segments {
            #expect(segment.start > previousStart)
            #expect(segment.end >= segment.start)
            #expect(segment.end <= Self.duration)
            previousStart = segment.start
        }
        try Validation.segments(result.segments, duration: Self.duration)
    }

    @Test func aSpeakerLimitOfOneCollapsesTheConversation() throws {
        let result = try fused(SpeakerAttribution.Options(speakerLimit: 1))
        #expect(result.speakers.count == 1)
        #expect(result.segments.allSatisfy { $0.speaker == "speaker_1" })
    }

    @Test func theRecordedRunHasTheShapeTheFusionExpects() throws {
        let recorded = try JSONDecoder().decode(
            NemotronWorkerTranscript.self, from: Data(Self.recorded.utf8)
        )
        #expect(recorded.words.count > 40)
        #expect(recorded.activity.count == 5)
        #expect(Set(recorded.activity.map(\.speaker)).count == 2)
        #expect(recorded.words.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
        // Emission-aligned timings trail the audio, so the last word must still fit.
        #expect(try #require(recorded.words.last).end <= Self.duration)
    }
}
