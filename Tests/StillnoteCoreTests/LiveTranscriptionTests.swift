import Foundation
import Testing
@testable import StillnoteCore

struct LiveAudioBufferTests {
    @Test func drainsWhatWasAppended() {
        let buffer = LiveAudioBuffer()
        buffer.append([1, 2, 3])
        buffer.append([4])
        #expect(buffer.drain() == [1, 2, 3, 4])
        // A drained, open buffer yields an empty block rather than closing the writer.
        #expect(buffer.drain() == [])
        #expect(buffer.droppedSamples == 0)
    }

    @Test func closingSignalsTheWriterOnlyOnceDrained() {
        let buffer = LiveAudioBuffer()
        buffer.append([1, 2])
        buffer.close()
        // The tail is still delivered; the next drain is the end-of-input signal.
        #expect(buffer.drain() == [1, 2])
        #expect(buffer.drain() == nil)
    }

    @Test func appendingAfterCloseIsIgnored() {
        let buffer = LiveAudioBuffer()
        buffer.close()
        buffer.append([1, 2, 3])
        #expect(buffer.drain() == nil)
    }

    /// A worker falling behind must never be able to stall the capture queue, so the buffer
    /// is capped and the oldest audio is dropped.
    @Test func dropsTheOldestAudioWhenTheWorkerFallsBehind() {
        let buffer = LiveAudioBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        #expect(buffer.drain() == [3, 4, 5, 6])
        #expect(buffer.droppedSamples == 2)
    }
}

struct LiveTranscriptAccumulatorTests {
    private func partial(
        _ words: [(String, Double, Double)], _ activity: [(Int, Double, Double)],
        final: Bool = false
    ) -> NemotronWorkerPartial {
        NemotronWorkerPartial(
            language: "en-US",
            words: words.map { TranscribedWord(text: $0.0, start: $0.1, end: $0.2) },
            activity: activity.map { SpeakerActivity(speaker: $0.0, start: $0.1, end: $0.2) },
            final: final
        )
    }

    @Test func appendsWordsAndReplacesTheTimeline() throws {
        var accumulator = LiveTranscriptAccumulator()
        accumulator.apply(partial([("Good", 0, 0.4)], [(0, 0, 1)]))
        accumulator.apply(partial([("morning.", 0.5, 1.0)], [(0, 0, 2)]))
        #expect(accumulator.words.map(\.text) == ["Good", "morning."])
        // The timeline arrives whole each time, so the newer one replaces the older.
        #expect(accumulator.activity == [SpeakerActivity(speaker: 0, start: 0, end: 2)])
        #expect(!accumulator.isFinal)
    }

    @Test func tracksTheFinalPartial() {
        var accumulator = LiveTranscriptAccumulator()
        accumulator.apply(partial([("done", 0, 1)], [(0, 0, 1)], final: true))
        #expect(accumulator.isFinal)
    }

    @Test func buildsAPreviewFromWhatHasArrived() throws {
        var accumulator = LiveTranscriptAccumulator()
        accumulator.apply(partial([("Hello", 0, 0.5)], [(0, 0, 1)]))
        accumulator.apply(partial([("Hi", 2.0, 2.4)], [(0, 0, 1), (1, 1.9, 3.0)]))
        let preview = try accumulator.preview(duration: 3)
        #expect(preview.segments.count == 2)
        #expect(preview.speakers.count == 2)
        #expect(preview.segments.map(\.text) == ["Hello", "Hi"])
    }

    /// While recording, the known duration is whatever has been captured so far. A word must
    /// never be clamped away because the preview's idea of the duration lags the audio.
    @Test func aPreviewNeverClampsAwayAWordThatHasArrived() throws {
        var accumulator = LiveTranscriptAccumulator()
        accumulator.apply(partial([("late", 9.0, 9.6)], [(0, 8.5, 10)]))
        let preview = try accumulator.preview(duration: 0)
        #expect(preview.segments.first?.end == 9.6)
    }

    @Test func anEmptyAccumulatorPreviewsNothing() throws {
        let preview = try LiveTranscriptAccumulator().preview(duration: 5)
        #expect(preview.segments.isEmpty)
        #expect(preview.speakers.isEmpty)
    }
}
