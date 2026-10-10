import Foundation
import Testing
@testable import StillnoteCore

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscribedWord {
    TranscribedWord(text: text, start: start, end: end)
}

private func active(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerActivity {
    SpeakerActivity(speaker: speaker, start: start, end: end)
}

/// No emission lag, so a test states the timeline it means.
private let exact = SpeakerAttribution.Options(emissionLag: 0)

struct SpeakerAttributionTests {
    @Test func attributesWordsToTheOverlappingChannel() {
        let words = [word("Hello", 0.0, 0.5), word("there", 0.5, 1.0), word("Hi", 2.0, 2.4)]
        let activity = [active(0, 0, 1.2), active(1, 1.9, 2.6)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [0, 0, 1])
    }

    @Test func picksTheChannelWithMoreOverlapWhenSpeechOverlaps() {
        // Both channels are active across the word; channel 1 covers more of it.
        let words = [word("overlap", 1.0, 2.0)]
        let activity = [active(0, 0.0, 1.2), active(1, 1.1, 3.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [1])
    }

    @Test func aTiedWordStaysWithWhoeverWasAlreadySpeaking() {
        // "yeah" straddles a handover with equal overlap on both sides.
        let words = [word("so", 0.0, 1.0), word("yeah", 1.0, 2.0), word("right", 2.0, 3.0)]
        let activity = [active(0, 0.0, 1.5), active(1, 1.5, 3.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [0, 0, 1])
    }

    @Test func compensatesForEmissionLag() {
        // The word is emitted 80 ms after it was spoken, landing inside the next speaker's
        // turn. Without correction it would be attributed to channel 1.
        let words = [word("done", 1.46, 1.58)]
        let activity = [active(0, 0.0, 1.5), active(1, 1.5, 3.0)]
        let lagged = SpeakerAttribution.Options(emissionLag: 0.08)
        #expect(SpeakerAttribution.attribute(words: words, activity: activity, options: lagged)
            .map(\.speaker) == [0])
        #expect(SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
            .map(\.speaker) == [1])
    }

    @Test func widensADegenerateSpanSoItStillOverlaps() {
        // A one-frame word can decode with start == end; a zero-width span overlaps nothing.
        let words = [word("mm", 0.5, 0.5)]
        let activity = [active(3, 0.0, 1.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [3])
    }

    @Test func wordsOverSilenceInheritTheirNeighbours() {
        let words = [word("a", 0.0, 0.4), word("b", 5.0, 5.4), word("c", 9.0, 9.4)]
        let activity = [active(0, 0.0, 1.0), active(0, 8.5, 10.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [0, 0, 0])
    }

    @Test func wordsBeforeAnyActivityTakeTheFirstAttributedSpeaker() {
        let words = [word("early", 0.0, 0.3), word("later", 4.0, 4.5)]
        let activity = [active(2, 3.5, 5.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: exact)
        #expect(result.map(\.speaker) == [2, 2])
    }

    @Test func withoutAnyActivityEveryWordIsUnattributed() {
        let words = [word("alone", 0.0, 1.0)]
        let result = SpeakerAttribution.attribute(words: words, activity: [], options: exact)
        #expect(result.map(\.speaker) == [nil])
    }

    @Test func aSpeakerLimitKeepsTheMostActiveChannels() {
        let activity = [
            active(0, 0, 10),   // 10 s
            active(1, 10, 15),  // 5 s
            active(2, 15, 16),  // 1 s
        ]
        #expect(SpeakerAttribution.keptChannels(activity: activity, limit: 2) == Set([0, 1]))
        #expect(SpeakerAttribution.keptChannels(activity: activity, limit: nil) == Set([0, 1, 2]))
        #expect(SpeakerAttribution.keptChannels(activity: activity, limit: 9) == Set([0, 1, 2]))
    }

    @Test func wordsFromADroppedChannelFallThroughToAKeptOne() {
        // Channel 2 barely speaks and is dropped by a limit of 2; its word must still be
        // attributed rather than disappearing or becoming an unknown speaker.
        let words = [word("main", 0.0, 1.0), word("aside", 15.1, 15.4), word("back", 11.0, 11.5)]
        let activity = [active(0, 0, 10), active(1, 10, 16), active(2, 15.0, 15.5)]
        let limited = SpeakerAttribution.Options(emissionLag: 0, speakerLimit: 2)
        let result = SpeakerAttribution.attribute(words: words, activity: activity, options: limited)
        #expect(result.map(\.speaker) == [0, 1, 1])
    }

    @Test func activeDurationsSumPerChannel() {
        let activity = [active(0, 0, 1), active(0, 2, 4), active(1, 1, 1.5)]
        #expect(SpeakerAttribution.activeDurations(activity) == [0: 3, 1: 0.5])
    }
}
