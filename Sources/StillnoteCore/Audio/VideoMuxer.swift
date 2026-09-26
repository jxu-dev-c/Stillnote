import AVFoundation
import Foundation

/// Copies the captured H.264 screen frames and interleaves the mixed meeting audio as
/// AAC, without re-encoding video and without buffering the movie in memory.
/// One-shot gate: `close` returns true exactly once, for the caller that closed it.
private final class Latch: @unchecked Sendable {
    private var closed = false
    private let lock = NSLock()

    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}

public enum VideoMuxer {
    /// `timeRange` limits both tracks to one span of the source timeline. Video stays a
    /// compressed passthrough, so the range must start on a sync sample; callers that cannot
    /// guarantee that pass a range starting at zero.
    public static func mux(
        screen: URL, audio: URL, to destination: URL, timeRange: CMTimeRange? = nil
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let screenAsset = AVURLAsset(url: screen)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw AudioMixError.message("The screen recording has no video stream.")
        }
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw AudioMixError.message("The mixed meeting audio could not be read.")
        }

        let reader = try AVAssetReader(asset: screenAsset)
        if let timeRange { reader.timeRange = timeRange }
        // A nil output setting hands back the original compressed samples.
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioReader = try AVAssetReader(asset: audioAsset)
        if let timeRange { audioReader.timeRange = timeRange }
        let audioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        audioReader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let formats = try await videoTrack.load(.formatDescriptions)
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first
        )
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(captureRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
        )
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? AudioMixError.message("Could not start saving the screen recording.")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)
        reader.startReading()
        audioReader.startReading()

        async let videoDone: Void = pump(videoInput, from: videoOutput, label: "stillnote.mux.video")
        async let audioDone: Void = pump(audioInput, from: audioOutput, label: "stillnote.mux.audio")
        _ = try await (videoDone, audioDone)

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? AudioMixError.message("The screen recording could not be finalized.")
        }
        if reader.status == .failed { throw reader.error ?? AudioMixError.message("Screen video read failed.") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func pump(
        _ input: AVAssetWriterInput, from output: AVAssetReaderTrackOutput, label: String
    ) async throws {
        let queue = DispatchQueue(label: label)
        // The ready-for-data block can be re-entered before markAsFinished takes effect,
        // and AVFoundation keeps it alive past this call, so finishing is latched by an
        // object the block owns: resuming a continuation twice would trap.
        let latch = Latch()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        if latch.close() {
                            input.markAsFinished()
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }
    }
}
