import Foundation

/// Mixes the capture sources into fixed blocks while the recording is still running.
///
/// `AudioMixer` already mixes microphone and system audio, but only after the fact, in
/// one-second blocks over finished WAVs. The live preview needs the same equal-gain mix
/// delivered continuously, because feeding recognition from the microphone alone would miss
/// every remote participant in a call — the people the meeting is mostly with.
///
/// Positions are the pause-adjusted sample indices capture already computes, so removed
/// pauses line up exactly as they do in the saved file and a sparse gap reads as silence.
///
/// This is deliberately pure: no AVFoundation, no clock, no I/O. `LiveAudioTap` wraps it with
/// the resampler.
public struct LiveAudioMixer {
    /// How many sources are mixed, which sets the equal gain. `AudioMixer` uses the same 1/n.
    public let sources: Int
    public let blockSamples: Int
    /// How far behind the newest sample emission stays, in blocks. A source whose buffer
    /// arrives slightly after another's still lands in its own block; audio later than this
    /// is dropped rather than held, because a stalled preview is worse than a gap in one.
    public let lagBlocks: Int

    /// Mixed sums from `base` onwards, divided by `sources` on the way out.
    private var accumulator: [Float] = []
    /// Absolute sample index of `accumulator[0]`.
    private var base = 0
    /// One past the highest absolute index any source has written.
    private var filled = 0
    private var droppedLateSamples = 0

    public init(sources: Int, blockSamples: Int, lagBlocks: Int = 1) {
        self.sources = max(1, sources)
        self.blockSamples = max(1, blockSamples)
        self.lagBlocks = max(0, lagBlocks)
    }

    /// Samples that arrived after their block had already been emitted. Nonzero means the
    /// preview is missing audio the saved recording still has.
    public var lateSamples: Int { droppedLateSamples }

    public mutating func append(_ samples: [Float], at position: Int) {
        guard !samples.isEmpty else { return }
        var samples = samples
        var position = position
        if position < base {
            // This region has already been emitted; keep only whatever is still ahead of it.
            let skip = base - position
            droppedLateSamples += min(skip, samples.count)
            guard skip < samples.count else { return }
            samples.removeFirst(skip)
            position = base
        }
        let offset = position - base
        let required = offset + samples.count
        if accumulator.count < required {
            accumulator.append(contentsOf: repeatElement(0, count: required - accumulator.count))
        }
        for index in samples.indices {
            accumulator[offset + index] += samples[index]
        }
        filled = max(filled, position + samples.count)
    }

    /// Complete blocks that are far enough behind the newest sample to be safe to emit.
    public mutating func drain() -> [[Float]] {
        emit(upTo: max(0, filled - lagBlocks * blockSamples))
    }

    /// Every remaining block, including a final short one padded with silence. Called when
    /// capture stops, so the last partial second of speech is not thrown away.
    public mutating func flush() -> [[Float]] {
        var blocks = emit(upTo: filled)
        let remainder = filled - base
        if remainder > 0 {
            var tail = Array(accumulator[0..<remainder])
            tail.append(contentsOf: repeatElement(0, count: blockSamples - remainder))
            blocks.append(scaled(tail))
            accumulator.removeAll(keepingCapacity: false)
            base = filled
        }
        return blocks
    }

    private mutating func emit(upTo watermark: Int) -> [[Float]] {
        var blocks: [[Float]] = []
        while base + blockSamples <= watermark, accumulator.count >= blockSamples {
            blocks.append(scaled(Array(accumulator[0..<blockSamples])))
            accumulator.removeFirst(blockSamples)
            base += blockSamples
        }
        return blocks
    }

    private func scaled(_ block: [Float]) -> [Float] {
        guard sources > 1 else { return block.map { max(-1, min(1, $0)) } }
        let gain = 1 / Float(sources)
        return block.map { max(-1, min(1, $0 * gain)) }
    }
}
