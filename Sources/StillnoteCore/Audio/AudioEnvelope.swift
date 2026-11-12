import AVFoundation
import Foundation

/// A recording's loudness over time, for drawing its waveform.
public enum AudioEnvelope {
    /// The lowest rate AVFoundation will resample to: plenty for loudness, and quick for 90 minutes.
    static let sampleRate = 8_000

    /// The recording split into `buckets` equal stretches of time, each its loudness from 0
    /// (silence) to 1. Levels are scaled to the recording's loud speech, not its single loudest
    /// moment, so one cough cannot flatten the rest; the loudest 5% read as full height.
    public static func read(_ url: URL, buckets: Int) async throws -> [Float] {
        guard buckets > 0 else { return [] }
        let unreadable = SpeechError.message("This recording's audio could not be read.")
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let reader = try? AVAssetReader(asset: asset)
        else { throw unreadable }
        var mono = AudioChannelLayout()
        mono.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(bytes: &mono, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw unreadable }
        reader.add(output)
        guard reader.startReading() else { throw unreadable }

        let expected = max(1, Int(duration * Double(sampleRate)))
        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var frame = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
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
                    let bucket = min(buckets - 1, (frame + index) * buckets / expected)
                    if value.isFinite { sums[bucket] += Double(value * value) }
                    counts[bucket] += 1
                }
            }
            frame += count
        }
        if reader.status == .failed { throw unreadable }
        return normalize(zip(sums, counts).map { $1 > 0 ? Float(($0 / Double($1)).squareRoot()) : 0 })
    }

    /// Scales loudness so the loud end of the recording's speech fills the height.
    static func normalize(_ levels: [Float]) -> [Float] {
        let sorted = levels.sorted()
        guard let reference = sorted.last.map({ _ in sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }),
              reference > 0.0005
        else { return levels.map { _ in 0 } }
        return levels.map { min(1, $0 / reference) }
    }
}
