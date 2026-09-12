import AVFoundation
import Foundation

public struct DecodedAudio: Sendable {
    /// 16 kHz mono float32 samples on disk, ready for the speech worker to memory-map.
    public let pcmURL: URL
    public let duration: Double
    public let frames: Int
    public let peak: Float
}

/// Decodes a local recording to the 16 kHz mono float32 stream MOSS expects.
/// External media references are forbidden, so a container cannot pull in another file.
public enum AudioDecoder {
    public static let sampleRate = 16_000

    public static func probeDuration(_ url: URL) async throws -> Double {
        let asset = makeAsset(url)
        let unreadable = SpeechError.message(
            "This file could not be read as audio. Try WAV, MP3, M4A, AAC, FLAC, or MP4."
        )
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw unreadable
        }
        guard let duration = try? await asset.load(.duration).seconds else { throw unreadable }
        return duration.isFinite && duration > 0 ? duration : 0
    }

    public static func decode(_ url: URL, to pcmURL: URL) async throws -> DecodedAudio {
        let undecodable = SpeechError.message(
            "Could not decode this audio. Try WAV, MP3, M4A, AAC, FLAC, or MP4."
        )
        let asset = makeAsset(url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first
        else { throw undecodable }
        guard let reader = try? AVAssetReader(asset: asset) else { throw undecodable }
        // Downmixing to mono requires an explicit target layout; without it the reader
        // refuses any source whose channel count differs from the output's.
        var mono = AudioChannelLayout()
        mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVChannelLayoutKey: Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else { throw undecodable }
        reader.add(output)

        FileManager.default.createFile(
            atPath: pcmURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
        )
        guard let handle = try? FileHandle(forWritingTo: pcmURL) else {
            throw SpeechError.message("Could not prepare the decoded audio for transcription.")
        }
        defer { try? handle.close() }

        guard reader.startReading() else { throw undecodable }
        var frames = 0
        var peak: Float = 0
        var finite = true
        let frameLimit = Int(Validation.maxRecordingSeconds + 1) * sampleRate
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for index in 0..<count {
                    let value = samples[index]
                    if !value.isFinite { finite = false }
                    peak = max(peak, abs(value))
                }
            }
            handle.write(Data(bytes: pointer, count: count * MemoryLayout<Float>.size))
            frames += count
            if frames > frameLimit { break }
        }
        if reader.status == .failed { throw undecodable }
        let duration = Double(frames) / Double(sampleRate)
        guard frames > 0, finite else { throw SpeechError.message("This recording contains no valid audio.") }
        guard duration <= Validation.maxRecordingSeconds else {
            throw SpeechError.message("MOSS supports recordings up to 90 minutes. Import a shorter recording.")
        }
        return DecodedAudio(pcmURL: pcmURL, duration: duration, frames: frames, peak: peak)
    }

    private static func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(
            url: url,
            options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
            ]
        )
    }
}
