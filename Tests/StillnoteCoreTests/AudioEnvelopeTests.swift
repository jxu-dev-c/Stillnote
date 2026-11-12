import AVFoundation
import Foundation
import Testing
@testable import StillnoteCore

@Suite struct AudioEnvelopeTests {
    /// Writes 16 kHz mono audio: each second is silence (0) or a tone at that amplitude.
    private func recording(_ seconds: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("envelope-\(UUID().uuidString).wav")
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = AVAudioFrameCount(rate)
        for amplitude in seconds {
            for i in 0..<Int(rate) {
                buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 2 * .pi * 220 / Float(rate))
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test func followsTheRecordingsLoudness() async throws {
        let url = try recording([0, 0.5, 0, 0.25])
        defer { try? FileManager.default.removeItem(at: url) }
        let levels = try await AudioEnvelope.read(url, buckets: 4)
        #expect(levels.count == 4)
        #expect(levels[0] < 0.01 && levels[2] < 0.01)
        #expect(levels[1] > 0.95)
        #expect(abs(levels[3] - 0.5) < 0.05)
    }

    @Test func oneLoudMomentDoesNotFlattenTheRest() {
        var levels = [Float](repeating: 0.2, count: 99)
        levels.append(5)
        let scaled = AudioEnvelope.normalize(levels)
        #expect(scaled[0] == 1)
        #expect(scaled[99] == 1)
        #expect(AudioEnvelope.normalize([0, 0, 0]) == [0, 0, 0])
    }

    @Test func unreadableFilesThrow() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        await #expect(throws: (any Error).self) { try await AudioEnvelope.read(url, buckets: 10) }
    }
}
