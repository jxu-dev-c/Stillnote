import Foundation
import Testing
@testable import StillnoteCore

struct LiveAudioMixerTests {
    @Test func emitsCompleteBlocksOnceTheyAreBehindTheWatermark() {
        var mixer = LiveAudioMixer(sources: 1, blockSamples: 4, lagBlocks: 1)
        mixer.append([1, 1, 1, 1], at: 0)
        // Only one block exists and the lag holds it back.
        #expect(mixer.drain().isEmpty)
        mixer.append([2, 2, 2, 2], at: 4)
        #expect(mixer.drain() == [[1, 1, 1, 1]])
    }

    @Test func mixesTwoSourcesAtEqualGain() {
        var mixer = LiveAudioMixer(sources: 2, blockSamples: 4, lagBlocks: 0)
        mixer.append([1, 1, 1, 1], at: 0)
        mixer.append([1, 1, 1, 1], at: 0)
        #expect(mixer.drain() == [[1, 1, 1, 1]])
    }

    /// A gap one source never wrote reads as silence from that source, which is what the
    /// offline mixer does too — not as a louder single source.
    @Test func aSourceThatStaysSilentHalvesTheMixRatherThanBoostingTheOther() {
        var mixer = LiveAudioMixer(sources: 2, blockSamples: 4, lagBlocks: 0)
        mixer.append([1, 1, 1, 1], at: 0)
        #expect(mixer.drain() == [[0.5, 0.5, 0.5, 0.5]])
    }

    @Test func clampsTheMixToTheSampleRange() {
        var mixer = LiveAudioMixer(sources: 2, blockSamples: 2, lagBlocks: 0)
        mixer.append([3, -3], at: 0)
        mixer.append([3, -3], at: 0)
        #expect(mixer.drain() == [[1, -1]])
    }

    @Test func alignsSourcesByPositionRatherThanArrivalOrder() {
        var mixer = LiveAudioMixer(sources: 2, blockSamples: 4, lagBlocks: 0)
        // The second source's block arrives first, for the later position.
        mixer.append([1, 1, 1, 1], at: 4)
        mixer.append([1, 1, 1, 1], at: 0)
        #expect(mixer.drain() == [[0.5, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]])
    }

    @Test func aSparseGapReadsAsSilence() {
        var mixer = LiveAudioMixer(sources: 1, blockSamples: 2, lagBlocks: 0)
        mixer.append([1, 1], at: 0)
        mixer.append([1, 1], at: 6)
        let blocks = mixer.drain()
        #expect(blocks == [[1, 1], [0, 0], [0, 0], [1, 1]])
    }

    /// Audio later than the lag allows is dropped, not merged into the wrong place, and it is
    /// counted so a preview missing audio can say so.
    @Test func countsAudioThatArrivesAfterItsBlockWasEmitted() {
        var mixer = LiveAudioMixer(sources: 1, blockSamples: 2, lagBlocks: 0)
        mixer.append([1, 1], at: 0)
        #expect(mixer.drain() == [[1, 1]])
        mixer.append([9, 9], at: 0)
        #expect(mixer.lateSamples == 2)
        #expect(mixer.drain().isEmpty)
    }

    @Test func keepsThePartOfALateBufferThatIsStillAhead() {
        var mixer = LiveAudioMixer(sources: 1, blockSamples: 2, lagBlocks: 0)
        mixer.append([1, 1], at: 0)
        _ = mixer.drain()
        // Half of this straddles the emitted block; the rest must still land.
        mixer.append([0.9, 0.9, 0.5, 0.5], at: 0)
        #expect(mixer.lateSamples == 2)
        #expect(mixer.drain() == [[0.5, 0.5]])
    }

    @Test func flushPadsTheFinalShortBlockWithSilence() {
        var mixer = LiveAudioMixer(sources: 1, blockSamples: 4, lagBlocks: 1)
        mixer.append([1, 1, 1, 1, 0.5, 0.5], at: 0)
        #expect(mixer.drain().isEmpty)
        #expect(mixer.flush() == [[1, 1, 1, 1], [0.5, 0.5, 0, 0]])
        #expect(mixer.flush().isEmpty)
    }

    @Test func emptyAppendsChangeNothing() {
        var mixer = LiveAudioMixer(sources: 2, blockSamples: 4)
        mixer.append([], at: 0)
        #expect(mixer.drain().isEmpty)
        #expect(mixer.flush().isEmpty)
    }

    /// The real geometry: 320 ms blocks at the capture rate, which is what the tap resamples.
    @Test func handlesTheRealBlockSize() {
        let blockSamples = captureRate / 1000 * 320
        var mixer = LiveAudioMixer(sources: 2, blockSamples: blockSamples)
        mixer.append([Float](repeating: 0.5, count: blockSamples * 3), at: 0)
        mixer.append([Float](repeating: 0.5, count: blockSamples * 3), at: 0)
        let blocks = mixer.drain()
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.count == blockSamples })
        #expect(blocks.allSatisfy { $0.allSatisfy { abs($0 - 0.5) < 0.0001 } })
    }
}
