import AVFoundation
import Foundation

/// Feeds the live recognizer while a recording is being made.
///
/// Capture already converts every source to 48 kHz mono float32 and resolves its position on
/// the pause-adjusted clock, so this takes that and does the two remaining things: mixes the
/// sources with `LiveAudioMixer`, and resamples to the 16 kHz the models read.
///
/// It is called from the serial capture queue and must never block it. The resampler is the
/// only work here, it is bounded, and the hand-off to the worker is a bounded buffer that
/// drops rather than waits.
public final class LiveAudioTap: @unchecked Sendable {
    /// 320 ms, matching the ASR bundle's fixed chunk geometry, measured at the capture rate.
    public static let blockSamples = captureRate / 1000 * 320

    private let lock = NSLock()
    private var mixer: LiveAudioMixer
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let sink: @Sendable ([Float]) -> Void

    /// Capture samples that arrived too late to be mixed into their block. Nonzero means the
    /// preview is missing audio the saved recording still has.
    public var lateSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return mixer.lateSamples
    }

    public init(sources: Int, sink: @escaping @Sendable ([Float]) -> Void) throws {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1,
            interleaved: false
        ),
        let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioDecoder.sampleRate),
            channels: 1, interleaved: false
        ),
        let converter = AVAudioConverter(from: input, to: output)
        else {
            throw CaptureError.message("The live transcript could not start.")
        }
        self.mixer = LiveAudioMixer(sources: sources, blockSamples: Self.blockSamples)
        self.converter = converter
        self.output = output
        self.sink = sink
    }

    /// 48 kHz mono float32 from one source, at its absolute position on the capture timeline.
    /// Sources are summed by position, so the tap does not need to know which one this is;
    /// only how many there are, which sets the gain.
    public func append(_ samples: [Float], at position: Int) {
        let blocks: [[Float]] = lock.withLock {
            mixer.append(samples, at: position)
            return mixer.drain()
        }
        deliver(blocks)
    }

    /// Emits whatever is left, including a final short block, when capture stops.
    public func flush() {
        let blocks: [[Float]] = lock.withLock { mixer.flush() }
        deliver(blocks)
    }

    private func deliver(_ blocks: [[Float]]) {
        for block in blocks {
            guard let resampled = resample(block), !resampled.isEmpty else { continue }
            sink(resampled)
        }
    }

    /// 48 kHz to 16 kHz. The converter keeps its filter state across blocks, so this must stay
    /// one converter driven in order — decimating by three without it would alias.
    private func resample(_ block: [Float]) -> [Float]? {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1,
            interleaved: false
        ),
        let source = AVAudioPCMBuffer(
            pcmFormat: input, frameCapacity: AVAudioFrameCount(block.count)
        ),
        let channel = source.floatChannelData?[0]
        else { return nil }
        block.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: block.count) }
        source.frameLength = AVAudioFrameCount(block.count)

        let capacity = AVAudioFrameCount(
            ceil(Double(block.count) * output.sampleRate / Double(captureRate)) + 64
        )
        guard let destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: destination, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard result != .error, let samples = destination.floatChannelData?[0] else { return nil }
        return (0..<Int(destination.frameLength)).map {
            samples[$0].isFinite ? samples[$0] : 0
        }
    }
}

extension NSLock {
    fileprivate func withLock<Result>(_ body: () -> Result) -> Result {
        lock(); defer { unlock() }
        return body()
    }
}
