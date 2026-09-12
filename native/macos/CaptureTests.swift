import AVFoundation
import Foundation

@main
struct CaptureTests {
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, layout: UnsafePointer<AudioChannelLayout>? = nil) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        assert(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
            layoutSize: layout == nil ? 0 : MemoryLayout<AudioChannelLayout>.size, layout: layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        assert(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr)
        let notReady = try audioPCMBuffer(from: sample!)
        assert(notReady == nil)
        assert(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList) == noErr)
        assert(CMSampleBufferSetDataReady(sample!) == noErr)
        return sample!
    }

    static func checkAudioBuffers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (kind, channels, interleaved, rate) in [(AVAudioCommonFormat.pcmFormatFloat32, UInt32(1), false, 48000.0),
                                                   (.pcmFormatInt16, 2, true, 44100.0), (.pcmFormatFloat32, 4, false, 48000.0)] {
            let channelLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
            let format = AVAudioFormat(commonFormat: kind, sampleRate: rate, interleaved: interleaved, channelLayout: channelLayout)
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            input.frameLength = 512
            for (index, buffer) in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList).enumerated() {
                memset(buffer.mData!, Int32(index + 1), Int(buffer.mDataByteSize))
            }
            let sample = try sampleBuffer(input)
            let output = try audioPCMBuffer(from: sample)!
            assert(output.frameLength == input.frameLength && output.format.sampleRate == rate)
            assert(output.format.channelCount == channels && output.format.isInterleaved == interleaved)
            let expected = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let actual = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            assert(actual.count == expected.count)
            for (left, right) in zip(expected, actual) {
                assert(left.mDataByteSize == right.mDataByteSize)
                assert(memcmp(left.mData!, right.mData!, Int(left.mDataByteSize)) == 0)
            }
            let writer = try PCMWriter(url: directory.appendingPathComponent("\(channels).wav"))
            _ = try writer.append(output, at: 0)
            assert(writer.frames > 0)
            try writer.close()
            CMSampleBufferInvalidate(sample)
            let invalid = try audioPCMBuffer(from: sample)
            assert(invalid == nil)
        }

        // A PCM description with inconsistent layout metadata must not produce a
        // null AVAudioFormat and crash the allocator. PCM's channel count wins.
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 512)!
        input.frameLength = 512
        for index in 0..<512 { input.floatChannelData![0][index] = 0.25 }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let sample = try sampleBuffer(input, layout: &layout)
        let output = try audioPCMBuffer(from: sample)!
        assert(output.format.channelCount == 1 && output.floatChannelData![0][511] == 0.25)

        var empty: CMSampleBuffer?
        assert(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &empty) == noErr)
        let emptyPCM = try audioPCMBuffer(from: empty!)
        assert(emptyPCM == nil)
    }

    static func main() throws {
        try checkAudioBuffers()
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
        print("Native PCM buffer validation, channel layouts, timeline, stereo resampling, levels, sparse silence, and live WAV recovery passed.")
    }
}
