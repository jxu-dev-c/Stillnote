import AVFoundation
import Foundation

/// One stretch of detected speech, in seconds from the start of the audio it was found in.
public struct SpeechRange: Codable, Hashable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// How much of a recording's head and tail carry no speech and may be removed. A plan that
/// trims nothing is the safe default: it is what every rejected case returns.
public struct CleanupPlan: Codable, Hashable, Sendable {
    public let originalDuration: Double
    public let head: Double
    public let tail: Double

    public init(originalDuration: Double, head: Double = 0, tail: Double = 0) {
        self.originalDuration = max(0, originalDuration)
        self.head = max(0, head)
        self.tail = max(0, tail)
    }

    public static func noTrim(duration: Double) -> CleanupPlan {
        CleanupPlan(originalDuration: duration)
    }

    public var keptDuration: Double { max(0, originalDuration - head - tail) }
    public var removedDuration: Double { head + tail }
    public var trimsAnything: Bool { head > 0 || tail > 0 }

    /// The surviving span of the original timeline.
    public var keptTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: head, preferredTimescale: 600),
            duration: CMTime(seconds: keptDuration, preferredTimescale: 600)
        )
    }
}

/// Decides what to remove from a recording and applies it. Speech is never filtered — only
/// regions the detector found no speech in are silenced or dropped — so a transcript can
/// never be degraded by an enhancement artifact.
public enum AudioCleanup {
    /// A trimmed recording must still be long enough to be a meeting.
    public static let minimumKeptSeconds: Double = 10
    /// Sub-second head and tail cuts are not worth rewriting a file for.
    private static let minimumEdgeCut: Double = 1
    /// Fade length at each gate boundary. A hard step would be an audible click, which is
    /// exactly the kind of artifact this pass exists to avoid introducing.
    private static let rampSeconds: Double = 0.01

    // MARK: - Policy

    /// Locates the speech and decides whether trimming is warranted. Every rejection path
    /// returns a plan that removes nothing, so a detector that misunderstands a recording
    /// leaves it intact rather than truncating it.
    public static func plan(
        ranges: [SpeechRange], duration: Double, settings: AudioCleanupSettings, allowHeadCut: Bool
    ) -> CleanupPlan {
        let intact = CleanupPlan.noTrim(duration: duration)
        guard duration > 0 else { return intact }

        // A stray keystroke or chair scrape must not define where the meeting ended, so only
        // sustained speech moves the boundaries.
        let sustained = ranges.filter { $0.duration >= settings.minimumSpeechRunSeconds }
        guard let first = sustained.map(\.start).min(),
              let last = sustained.map(\.end).max()
        else { return intact }

        var head = allowHeadCut ? max(0, min(first, duration) - settings.leadPadding) : 0
        var tail = max(0, duration - min(duration, last + settings.trailPadding))
        if head < minimumEdgeCut { head = 0 }
        if tail < minimumEdgeCut { tail = 0 }

        let candidate = CleanupPlan(originalDuration: duration, head: head, tail: tail)
        guard candidate.trimsAnything,
              candidate.keptDuration >= minimumKeptSeconds,
              candidate.removedDuration >= settings.minimumTrimSeconds
        else { return intact }
        return candidate
    }

    // MARK: - Trimming a stored recording

    /// Copies the kept span of a captured WAV, one second at a time, so a meeting is never
    /// held in memory. Mirrors the format `AudioMixer` writes.
    @discardableResult
    public static func trim(wav source: URL, to destination: URL, plan: CleanupPlan) throws -> Double {
        guard plan.trimsAnything else {
            throw AudioMixError.message("There is nothing to trim in this recording.")
        }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw AudioMixError.message(
                "The recording could not be read for trimming. The original file is unchanged."
            )
        }
        let format = input.fileFormat
        guard format.channelCount == 1, Int(format.sampleRate) == captureRate,
              format.streamDescription.pointee.mBitsPerChannel == 16
        else {
            throw AudioMixError.message(
                "This recording is not in the captured audio format. The original file is unchanged."
            )
        }

        let rate = Double(captureRate)
        let start = min(Int64((plan.head * rate).rounded()), input.length)
        let end = min(Int64(((plan.head + plan.keptDuration) * rate).rounded()), input.length)
        guard end > start else {
            throw AudioMixError.message("Trimming would remove the whole recording, so it was kept.")
        }

        let working = input.processingFormat
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: working.commonFormat,
            interleaved: working.isInterleaved
        )
        let blockFrames = AVAudioFrameCount(captureRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: working, frameCapacity: blockFrames) else {
            throw AudioMixError.message("Could not allocate the audio trimming buffer.")
        }
        input.framePosition = start
        var remaining = end - start
        while remaining > 0 {
            let length = AVAudioFrameCount(min(Int64(blockFrames), remaining))
            buffer.frameLength = 0
            try input.read(into: buffer, frameCount: length)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
        return Double(end - start) / rate
    }

    // MARK: - Preparing the speech model's copy

    /// Writes the kept span of a 16 kHz mono float32 stream, optionally silencing every
    /// region the detector found no speech in. Speech samples pass through unchanged, so
    /// recognition sees the original signal and not a reconstruction of it.
    @discardableResult
    public static func preparePCM(
        source: URL, destination: URL, ranges: [SpeechRange], plan: CleanupPlan,
        suppressNonSpeech: Bool
    ) throws -> Int {
        let rate = AudioDecoder.sampleRate
        let unreadable = SpeechError.message("The decoded audio could not be prepared for transcription.")
        guard let reader = try? FileHandle(forReadingFrom: source) else { throw unreadable }
        defer { try? reader.close() }
        let total = Int((try? reader.seekToEnd()).map { Int($0) / 4 } ?? 0)
        guard total > 0 else { throw unreadable }

        let first = min(Int((plan.head * Double(rate)).rounded()), total)
        let last = min(Int(((plan.head + plan.keptDuration) * Double(rate)).rounded()), total)
        guard last > first else { throw unreadable }

        FileManager.default.createFile(
            atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]
        )
        guard let writer = try? FileHandle(forWritingTo: destination) else { throw unreadable }
        defer { try? writer.close() }

        var envelope = suppressNonSpeech ? GainEnvelope(ranges: ranges, rate: rate) : nil
        let blockSamples = rate
        try reader.seek(toOffset: UInt64(first * 4))
        var position = first
        while position < last {
            let count = min(blockSamples, last - position)
            guard let data = try reader.read(upToCount: count * 4), data.count == count * 4 else {
                throw unreadable
            }
            if envelope == nil {
                writer.write(data)
            } else {
                var samples = [Float](repeating: 0, count: count)
                _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                for index in 0..<count {
                    let gain = envelope!.gain(at: position + index)
                    if gain < 1 { samples[index] *= gain }
                }
                writer.write(samples.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            position += count
        }
        return last - first
    }

    /// Per-sample gain: 1 inside a speech range, 0 well outside it, and a raised-cosine
    /// fade across the boundary. Ranges are expanded by the ramp so no speech sample is
    /// attenuated.
    ///
    /// Samples are always visited in order, so the cursor only ever moves forward. Without
    /// it, gating a 90-minute meeting would rescan every earlier range for all 86 million
    /// samples.
    struct GainEnvelope {
        private let bounds: [(start: Int, end: Int)]
        private let ramp: Int
        private var cursor = 0

        init(ranges: [SpeechRange], rate: Int) {
            ramp = max(1, Int(AudioCleanup.rampSeconds * Double(rate)))
            bounds = ranges
                .filter { $0.duration > 0 }
                .map {
                    (start: Int(($0.start * Double(rate)).rounded()),
                     end: Int(($0.end * Double(rate)).rounded()))
                }
                .sorted { $0.start < $1.start }
        }

        mutating func gain(at index: Int) -> Float {
            while cursor < bounds.count, index > bounds[cursor].end + ramp { cursor += 1 }
            var gain: Float = 0
            var probe = cursor
            while probe < bounds.count, index >= bounds[probe].start - ramp {
                let bound = bounds[probe]
                if index >= bound.start, index <= bound.end { return 1 }
                if index < bound.start {
                    let progress = Double(index - (bound.start - ramp)) / Double(ramp)
                    gain = max(gain, Float(0.5 - 0.5 * cos(.pi * progress)))
                } else if index <= bound.end + ramp {
                    let progress = Double(index - bound.end) / Double(ramp)
                    gain = max(gain, Float(0.5 + 0.5 * cos(.pi * progress)))
                }
                probe += 1
            }
            return gain
        }
    }
}
