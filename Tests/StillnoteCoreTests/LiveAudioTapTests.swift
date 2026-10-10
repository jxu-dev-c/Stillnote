import Foundation
import Testing
@testable import StillnoteCore

struct LiveAudioTapTests {
    /// A second of 48 kHz audio must come out as a second of 16 kHz audio.
    @Test func resamplesCaptureRateDownToTheModelRate() throws {
        let received = Mutex<[Float]>([])
        let tap = try LiveAudioTap(sources: 1) { block in
            received.withLock { $0.append(contentsOf: block) }
        }
        // A 440 Hz tone, so the output can be checked for sane amplitude rather than silence.
        let samples = (0..<captureRate).map {
            Float(sin(2 * Double.pi * 440 * Double($0) / Double(captureRate))) * 0.5
        }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 4_800, samples.count)
            tap.append(Array(samples[offset..<end]), at: offset)
            offset = end
        }
        tap.flush()

        let output = received.withLock { $0 }
        // One second in, one second out, within a block of resampler priming.
        #expect(abs(output.count - AudioDecoder.sampleRate) < LiveAudioTap.blockSamples / 3 + 64)
        #expect(output.allSatisfy { $0.isFinite })
        let peak = output.map { abs($0) }.max() ?? 0
        #expect(peak > 0.3 && peak <= 1)
        #expect(tap.lateSamples == 0)
    }

    @Test func mixesTwoSourcesBeforeResampling() throws {
        let received = Mutex<[Float]>([])
        let tap = try LiveAudioTap(sources: 2) { block in
            received.withLock { $0.append(contentsOf: block) }
        }
        let block = [Float](repeating: 0.8, count: LiveAudioTap.blockSamples)
        for index in 0..<3 {
            let at = index * LiveAudioTap.blockSamples
            tap.append(block, at: at)
            tap.append(block, at: at)
        }
        tap.flush()
        let output = received.withLock { $0 }
        #expect(!output.isEmpty)
        // Two equal sources at 0.8 average back to 0.8, not 1.6 clipped to 1.
        let steady = output.dropFirst(200).dropLast(200)
        #expect(steady.allSatisfy { abs($0 - 0.8) < 0.05 }, "mixed level drifted")
    }

    @Test func emitsNothingUntilABlockIsComplete() throws {
        let blocks = Mutex<Int>(0)
        let tap = try LiveAudioTap(sources: 1) { _ in blocks.withLock { $0 += 1 } }
        tap.append([Float](repeating: 0.1, count: 480), at: 0)
        #expect(blocks.withLock { $0 } == 0)
        tap.flush()
        #expect(blocks.withLock { $0 } == 1)
    }
}
