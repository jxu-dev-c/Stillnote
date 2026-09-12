import AVFoundation
import Foundation

@main
struct CaptureTests {
    static func main() throws {
        var clock = CaptureTimeline(start: 100)
        assert(clock.seconds(at: 102) == 2)
        clock.pause(at: 102); clock.pause(at: 103)
        assert(clock.seconds(at: 106) == 2)
        assert(!clock.accepts(106))
        clock.resume(at: 107); clock.resume(at: 108)
        assert(!clock.accepts(106.99) && clock.accepts(107))
        assert(!clock.accepts(.nan) && !clock.accepts(.infinity))
        assert(clock.seconds(at: 109) == 4)
        clock.pause(at: 110); clock.resume(at: 112)
        assert(clock.seconds(at: 115) == 8)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.wav")
        let writer = try PCMWriter(url: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for channel in 0..<2 {
            for index in 0..<4410 { buffer.floatChannelData![channel][index] = 0.5 }
        }
        let levels = try writer.append(buffer, at: 0.2)
        assert(levels.0 > 0.45 && levels.0 < 0.55)
        assert(levels.1 >= 0.5)
        // Reopen before close: header and silent alignment gap are already durable.
        let input = try AVAudioFile(forReading: url)
        assert(input.fileFormat.sampleRate == 48000 && input.fileFormat.channelCount == 1)
        assert(input.length > 14000 && input.length <= 14464)
        let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length))!
        try input.read(into: read)
        assert(read.floatChannelData![0][9000] == 0)
        assert(read.floatChannelData![0][11000] > 0.45)
        try writer.close()
        print("Native timeline, stereo resampling, levels, sparse silence, and live WAV recovery passed.")
    }
}
