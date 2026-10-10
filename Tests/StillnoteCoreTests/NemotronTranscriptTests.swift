import Foundation
import Testing
@testable import StillnoteCore

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscribedWord {
    TranscribedWord(text: text, start: start, end: end)
}

private func active(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerActivity {
    SpeakerActivity(speaker: speaker, start: start, end: end)
}

private let exact = SpeakerAttribution.Options(emissionLag: 0)

struct NemotronTranscriptTests {
    @Test func numbersSpeakersByFirstAppearanceNotByChannelIndex() throws {
        // The diarizer reports channels 5 and 2; the transcript must still read
        // Speaker 1 then Speaker 2, with no gap where channels 0-4 would be.
        let words = [word("First.", 0.0, 0.5), word("Second.", 2.0, 2.5)]
        let activity = [active(5, 0.0, 1.0), active(2, 1.9, 3.0)]
        let result = try NemotronTranscript.build(
            words: words, activity: activity, duration: 3, language: "en-US", options: exact
        )
        #expect(result.segments.map(\.speaker) == ["speaker_1", "speaker_2"])
        #expect(result.speakers == ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"])
    }

    @Test func aChannelThatWinsNoWordLeavesNoHole() throws {
        // Channel 0 is active during silence only, so it never wins a word.
        let words = [word("Only.", 5.0, 5.5)]
        let activity = [active(0, 0.0, 1.0), active(1, 4.9, 6.0)]
        let result = try NemotronTranscript.build(
            words: words, activity: activity, duration: 6, language: "en-US", options: exact
        )
        #expect(result.speakers == ["speaker_1": "Speaker 1"])
        #expect(result.segments.map(\.speaker) == ["speaker_1"])
    }

    @Test func assignsSegmentIdsInOrder() throws {
        let words = [word("a", 0, 0.2), word("b", 3, 3.2), word("c", 6, 6.2)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 7)], duration: 7, language: "en", options: exact
        )
        #expect(result.segments.map(\.id) == ["segment_1", "segment_2", "segment_3"])
    }

    @Test func shiftsByTheRemovedHeadAndClampsToTheRecording() throws {
        let words = [word("late", 1.0, 1.5)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 2)], duration: 4, language: "en",
            offset: 2.5, options: exact
        )
        #expect(result.segments.first?.start == 3.5)
        #expect(result.segments.first?.end == 4.0)  // clamped: 1.5 + 2.5 == 4.0
    }

    @Test func clampsAWordPastTheEndOfTheRecording() throws {
        let words = [word("over", 9.0, 12.0)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 12)], duration: 10, language: "en", options: exact
        )
        #expect(result.segments.first?.start == 9.0)
        #expect(result.segments.first?.end == 10.0)
    }

    @Test func roundsToMilliseconds() throws {
        let words = [word("x", 1.00049, 1.00051)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 2)], duration: 2.0004, language: "en",
            options: exact
        )
        #expect(result.segments.first?.start == 1.0)
        #expect(result.segments.first?.end == 1.001)
        #expect(result.duration == 2.0)
    }

    @Test(arguments: [
        [TranscribedWord(text: "bad", start: 2, end: 1)],
        [TranscribedWord(text: "nan", start: .nan, end: 1)],
        [TranscribedWord(text: "inf", start: 0, end: .infinity)],
        [TranscribedWord(text: "negative", start: -1, end: 1)],
    ])
    func refusesTimestampsItCannotPlace(words: [TranscribedWord]) {
        #expect(throws: SpeechError.self) {
            try NemotronTranscript.build(
                words: words, activity: [], duration: 10, language: "en", options: exact
            )
        }
    }

    @Test func emptyInputIsAnEmptyTranscriptNotAFailure() throws {
        let result = try NemotronTranscript.build(
            words: [], activity: [], duration: 12.5, language: "", options: exact
        )
        #expect(result.segments.isEmpty)
        #expect(result.speakers.isEmpty)
        #expect(result.language == "auto")
        #expect(result.duration == 12.5)
    }

    @Test func dropsBlankWords() throws {
        let words = [word("  ", 0, 0.1), word("real", 0.2, 0.4)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 1)], duration: 1, language: "en", options: exact
        )
        #expect(result.segments.map(\.text) == ["real"])
    }

    // MARK: - Segmentation

    @Test func splitsOnASpeakerChange() throws {
        let words = [word("Mine.", 0, 0.5), word("Yours.", 0.6, 1.0)]
        let activity = [active(0, 0, 0.55), active(1, 0.55, 2)]
        let result = try NemotronTranscript.build(
            words: words, activity: activity, duration: 2, language: "en", options: exact
        )
        #expect(result.segments.map(\.text) == ["Mine.", "Yours."])
    }

    @Test func splitsOnALongSilence() throws {
        let words = [word("before", 0, 0.5), word("after", 1.3, 1.8)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 3)], duration: 3, language: "en", options: exact
        )
        #expect(result.segments.count == 2)
    }

    @Test func keepsAShortPauseInsideOneSegment() throws {
        let words = [word("before", 0, 0.5), word("after", 0.8, 1.2)]
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, 3)], duration: 3, language: "en", options: exact
        )
        #expect(result.segments.map(\.text) == ["before after"])
    }

    @Test func breaksALongTurnAtASentenceBoundary() throws {
        // Twenty seconds of one speaker with no pause: it must not be one paragraph, and the
        // break must land after a sentence rather than mid-clause.
        var words: [TranscribedWord] = []
        var time = 0.0
        for index in 0..<40 {
            let text = index % 5 == 4 ? "end." : "word"
            words.append(word(text, time, time + 0.4))
            time += 0.5
        }
        let options = SpeakerAttribution.Options(emissionLag: 0, targetSegmentSeconds: 12)
        let result = try NemotronTranscript.build(
            words: words, activity: [active(0, 0, time)], duration: time,
            language: "en", options: options
        )
        #expect(result.segments.count > 1)
        for segment in result.segments.dropLast() {
            #expect(segment.text.hasSuffix("end."))
        }
    }

    // MARK: - Word joining

    @Test func joinsEnglishWordsWithSpaces() {
        #expect(NemotronTranscript.joined(["Hello", "there,", "world."]) == "Hello there, world.")
    }

    @Test func doesNotSpaceBeforeTrailingPunctuation() {
        #expect(NemotronTranscript.joined(["Wait", ",", "no", "."]) == "Wait, no.")
        #expect(NemotronTranscript.joined(["(", "aside", ")"]) == "(aside)")
        #expect(NemotronTranscript.joined(["say", "\u{201C}", "this", "\u{201D}"]) == "say \u{201C}this\u{201D}")
    }

    @Test func doesNotInsertSpacesIntoScriptsThatHaveNone() {
        #expect(NemotronTranscript.joined(["这是", "一个", "测试"]) == "这是一个测试")
        #expect(NemotronTranscript.joined(["これは", "テスト", "です。"]) == "これはテストです。")
    }

    @Test func keepsSpacesForKoreanWhichUsesThem() {
        #expect(NemotronTranscript.joined(["안녕하세요", "반갑습니다"]) == "안녕하세요 반갑습니다")
    }

    @Test func doesNotSpaceAcrossAScriptBoundaryIntoCJK() {
        #expect(NemotronTranscript.joined(["Hello", "世界"]) == "Hello世界")
    }
}
