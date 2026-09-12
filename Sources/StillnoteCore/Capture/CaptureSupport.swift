import AVFoundation
import Foundation

public let captureRate = 48_000

public struct CaptureTimeline {
    public var start: Double
    public var pausedAt: Double?
    public var resumedAt: Double?
    public var pausedDuration: Double = 0
    public init(start: Double) { self.start = start }
    public mutating func pause(at time: Double) { if pausedAt == nil { pausedAt = time } }
    public mutating func resume(at time: Double) {
        if let pausedAt { pausedDuration += time - pausedAt; self.pausedAt = nil; resumedAt = time }
    }
    public func seconds(at time: Double) -> Double { max(0, (pausedAt ?? time) - start - pausedDuration) }
    public func accepts(_ time: Double) -> Bool { pausedAt == nil && time.isFinite && time >= (resumedAt ?? start) }
}

/// ScreenCaptureKit may send transitional buffers without a usable audio format.
/// Build from the PCM stream description: the CM-format initializer can return nil
/// despite its nonoptional Swift signature, crashing AVAudioPCMBuffer's initializer.
public func audioPCMBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
    guard sample.isValid, CMSampleBufferDataIsReady(sample),
          sample.numSamples > 0, sample.numSamples <= Int32.max,
          let description = sample.formatDescription,
          CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
          let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
          stream.pointee.mFormatID == kAudioFormatLinearPCM,
          stream.pointee.mSampleRate.isFinite, stream.pointee.mSampleRate > 0,
          stream.pointee.mChannelsPerFrame > 0 else { return nil }
    // Mono/stereo layouts are implicit. Preserve multichannel input without relying
    // on missing or inconsistent channel-layout metadata in the sample description.
    let channels = stream.pointee.mChannelsPerFrame
    let layout = channels > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) : nil
    guard let format = AVAudioFormat(streamDescription: stream, channelLayout: layout),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
    buffer.frameLength = buffer.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else {
        throw CaptureError.message("The input audio buffer could not be read.")
    }
    return buffer
}

/// Seekable PCM keeps microphone and system samples on the same host-clock timeline.
/// Sparse gaps read as silence. A fresh header is written after every buffer so audio
/// remains recoverable if the helper or server exits unexpectedly.
public final class PCMWriter {
    let file: FileHandle
    public private(set) var frames: Int64 = 0
    var converter: AVAudioConverter?
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1, interleaved: false)!
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.message("Could not create the recording on disk.")
        }
        file = try FileHandle(forUpdating: url)
        try header()
    }
    func header() throws {
        let size = UInt32(frames * 2)
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        number(size + 36); data.append(Data("WAVEfmt ".utf8)); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(captureRate)); number(UInt32(captureRate * 2))
        number(UInt16(2)); number(UInt16(16)); data.append(Data("data".utf8)); number(size)
        try file.seek(toOffset: 0); try file.write(contentsOf: data)
    }
    public func append(_ buffer: AVAudioPCMBuffer, at seconds: Double) throws -> (Double, Double) {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { throw CaptureError.message("The microphone audio format is unsupported.") }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard result != .error else { throw error ?? CaptureError.message("Audio conversion failed.") as NSError }
        let count = Int(output.frameLength)
        guard count > 0, let samples = output.floatChannelData?[0] else { return (0, 0) }
        var energy: Double = 0; var peak: Double = 0
        var pcm = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = samples[index].isFinite ? Double(samples[index]) : 0
            energy += value * value; peak = max(peak, abs(value))
            pcm[index] = Int16(max(-1, min(1, value)) * 32767).littleEndian
        }
        // Remove sub-buffer callback jitter without allowing cumulative clock drift.
        let desired = max(0, Int64((seconds * Double(captureRate)).rounded()))
        let position = abs(desired - frames) < 480 ? frames : desired
        try file.seek(toOffset: UInt64(44 + position * 2))
        try pcm.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
        frames = max(frames, position + Int64(count)); try header()
        return (min(1, sqrt(energy / Double(count))), min(1, peak))
    }
    public func close() throws { try header(); try file.synchronize(); try file.close() }
}

public enum CaptureError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
