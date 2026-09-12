import AVFoundation
import Foundation
import Testing

@testable import StillnoteCore

private func makeSampleBuffer(
    _ buffer: AVAudioPCMBuffer, layout: UnsafePointer<AudioChannelLayout>? = nil, ready: Bool = true
) throws -> CMSampleBuffer {
    var description: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
        layoutSize: layout == nil ? 0 : MemoryLayout<AudioChannelLayout>.size, layout: layout,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
    ) == noErr)
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid
    )
    #expect(CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: description, sampleCount: Int(buffer.frameLength),
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample
    ) == noErr)
    guard ready else { return sample! }
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
        sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: buffer.audioBufferList
    ) == noErr)
    #expect(CMSampleBufferSetDataReady(sample!) == noErr)
    return sample!
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct CaptureTimelineTests {
    /// Paused time is removed from the recorded clock, and buffers queued before a
    /// resume are rejected so they cannot overwrite earlier samples.
    @Test func removesPausedTimeAndRejectsStaleBuffers() {
        var clock = CaptureTimeline(start: 100)
        #expect(clock.seconds(at: 102) == 2)
        clock.pause(at: 102)
        clock.pause(at: 103)
        #expect(clock.seconds(at: 106) == 2)
        #expect(!clock.accepts(106))
        clock.resume(at: 107)
        clock.resume(at: 108)
        #expect(!clock.accepts(106.99))
        #expect(clock.accepts(107))
        #expect(!clock.accepts(.nan))
        #expect(!clock.accepts(.infinity))
        #expect(clock.seconds(at: 109) == 4)
        clock.pause(at: 110)
        clock.resume(at: 112)
        #expect(clock.seconds(at: 115) == 8)
    }
}

@Suite struct AudioBufferTests {
    @Test func copiesEveryChannelLayoutWithoutLoss() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(AVAudioCommonFormat, UInt32, Bool, Double)] = [
            (.pcmFormatFloat32, 1, false, 48000), (.pcmFormatInt16, 2, true, 44100),
            (.pcmFormatFloat32, 4, false, 48000),
        ]
        for (kind, channels, interleaved, rate) in cases {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
            )!
            let format = AVAudioFormat(
                commonFormat: kind, sampleRate: rate, interleaved: interleaved, channelLayout: layout
            )
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            input.frameLength = 512
            for (index, buffer) in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList).enumerated() {
                memset(buffer.mData!, Int32(index + 1), Int(buffer.mDataByteSize))
            }
            let sample = try makeSampleBuffer(input)
            let output = try #require(try audioPCMBuffer(from: sample))
            #expect(output.frameLength == input.frameLength)
            #expect(output.format.sampleRate == rate)
            #expect(output.format.channelCount == channels)
            #expect(output.format.isInterleaved == interleaved)
            for (left, right) in zip(
                UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList),
                UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            ) {
                #expect(left.mDataByteSize == right.mDataByteSize)
                #expect(memcmp(left.mData!, right.mData!, Int(left.mDataByteSize)) == 0)
            }
            let writer = try PCMWriter(url: directory.appendingPathComponent("\(channels).wav"))
            _ = try writer.append(output, at: 0)
            #expect(writer.frames > 0)
            try writer.close()

            CMSampleBufferInvalidate(sample)
            #expect(try audioPCMBuffer(from: sample) == nil)
        }
    }

    /// Inconsistent layout metadata must not produce a null format and crash the
    /// allocator: the PCM description's channel count wins.
    @Test func prefersThePCMChannelCountOverLayoutMetadata() throws {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 512)!
        input.frameLength = 512
        for index in 0..<512 { input.floatChannelData![0][index] = 0.25 }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let output = try #require(try audioPCMBuffer(from: makeSampleBuffer(input, layout: &layout)))
        #expect(output.format.channelCount == 1)
        #expect(output.floatChannelData![0][511] == 0.25)
    }

    @Test func rejectsUnreadyAndEmptyBuffers() throws {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 128)!
        input.frameLength = 128
        #expect(try audioPCMBuffer(from: makeSampleBuffer(input, ready: false)) == nil)

        var empty: CMSampleBuffer?
        #expect(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &empty
        ) == noErr)
        #expect(try audioPCMBuffer(from: empty!) == nil)
    }
}

@Suite struct PCMWriterTests {
    /// Stereo input is resampled to mono 48 kHz, the gap before the first sample is
    /// silence, and the WAV is readable before the writer is closed.
    @Test func writesRecoverableMonoAudioWithAlignedSilence() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.wav")
        let writer = try PCMWriter(url: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for channel in 0..<2 {
            for index in 0..<4410 { buffer.floatChannelData![channel][index] = 0.5 }
        }
        let levels = try writer.append(buffer, at: 0.2)
        #expect(levels.0 > 0.45 && levels.0 < 0.55)
        #expect(levels.1 >= 0.5)

        let input = try AVAudioFile(forReading: url)
        #expect(input.fileFormat.sampleRate == 48000)
        #expect(input.fileFormat.channelCount == 1)
        #expect(input.length > 14000 && input.length <= 14464)
        let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length))!
        try input.read(into: read)
        #expect(read.floatChannelData![0][9000] == 0)
        #expect(read.floatChannelData![0][11000] > 0.45)
        try writer.close()
    }
}

@Suite struct AudioMixerTests {
    /// Two sources mix at equal gain with headroom, and the result keeps the longer
    /// source's full length.
    @Test func mixesBothSourcesAtEqualGain() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(tone: 1.0, frames: 48_000, to: directory.appendingPathComponent("microphone.wav"))
        try write(tone: 1.0, frames: 24_000, to: directory.appendingPathComponent("system.wav"))

        let destination = directory.appendingPathComponent("mixed.wav")
        let duration = try AudioMixer.mix(sessionDirectory: directory, to: destination)
        #expect(abs(duration - 1.0) < 0.001)

        let file = try AVAudioFile(forReading: destination)
        #expect(file.length == 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        // Overlapping region: both sources at full scale still leave headroom.
        #expect(abs(samples[100] - 1.0) < 0.01)
        // Past the shorter source only the microphone contributes, at half gain.
        #expect(abs(samples[40_000] - 0.5) < 0.01)
    }

    @Test func refusesASessionWithNoAudio() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: AudioMixError.self) {
            try AudioMixer.mix(
                sessionDirectory: directory, to: directory.appendingPathComponent("mixed.wav")
            )
        }
    }

    private func write(tone: Float, frames: AVAudioFrameCount, to url: URL) throws {
        let writer = try PCMWriter(url: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = tone }
        _ = try writer.append(buffer, at: 0)
        try writer.close()
    }
}

@Suite struct AudioDecoderTests {
    /// Import decodes to the 16 kHz mono float32 stream MOSS expects, whatever the
    /// source rate and channel count were.
    @Test func decodesToSixteenKilohertzMono() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        // Scoped so the writer is released and the file finalized before it is read.
        do {
            let file = try AVAudioFile(
                forWriting: source,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
            )
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100)!
            buffer.frameLength = 44100
            for channel in 0..<2 {
                for index in 0..<44100 {
                    buffer.floatChannelData![channel][index] = sin(Float(index) * 0.05) * 0.5
                }
            }
            try file.write(from: buffer)
        }

        let decoded = try await AudioDecoder.decode(source, to: directory.appendingPathComponent("out.f32"))
        #expect(abs(decoded.duration - 1.0) < 0.05)
        #expect(abs(decoded.frames - AudioDecoder.sampleRate) < 800)
        #expect(decoded.peak > 0.4 && decoded.peak <= 1.0)
        let bytes = try Data(contentsOf: decoded.pcmURL)
        #expect(bytes.count == decoded.frames * MemoryLayout<Float>.size)
    }

    @Test func rejectsAFileWithoutAudio() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: source)
        await #expect(throws: SpeechError.self) {
            try await AudioDecoder.decode(source, to: directory.appendingPathComponent("out.f32"))
        }
    }
}

@Suite struct VideoMuxerTests {
    /// Finishing a recording copies the captured H.264 frames and interleaves the mixed
    /// meeting audio, so the saved movie plays with sound.
    @Test func combinesCapturedVideoWithTheMixedAudio() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mp4")
        try await writeSilentVideo(to: screen, seconds: 2)
        let audio = directory.appendingPathComponent("mixed.wav")
        try writeTone(to: audio, seconds: 2)

        let destination = directory.appendingPathComponent("meeting.mp4")
        try await VideoMuxer.mux(screen: screen, audio: audio, to: destination)

        let asset = AVURLAsset(url: destination)
        let video = try await asset.loadTracks(withMediaType: .video)
        let sound = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(sound.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 1.5 && duration < 3.0)
        // The video is copied, not re-encoded, so it keeps its original dimensions.
        let size = try await video[0].load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 240))
    }

    @Test func refusesAScreenFileWithoutVideo() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("mixed.wav")
        try writeTone(to: audio, seconds: 1)
        await #expect(throws: Error.self) {
            try await VideoMuxer.mux(
                screen: audio, audio: audio, to: directory.appendingPathComponent("out.mp4")
            )
        }
    }

    private func writeSilentVideo(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 15) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 15))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func writeTone(to url: URL, seconds: Int) throws {
        let writer = try PCMWriter(url: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1, interleaved: false
        )!
        let frames = AVAudioFrameCount(captureRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.4
        }
        _ = try writer.append(buffer, at: 0)
        try writer.close()
    }
}
