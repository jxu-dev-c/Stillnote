import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CaptureOptions: Codable, Hashable, Sendable {
    public var title: String
    public var language: String
    public var speakerCount: Int?
    public var microphoneID: String
    public var displayID: UInt32?
    public var systemAudio: Bool
    public var screenVideo: Bool

    enum CodingKeys: String, CodingKey {
        case title, language
        case speakerCount = "speaker_count"
        case microphoneID = "microphone_id"
        case displayID = "display_id"
        case systemAudio = "system_audio"
        case screenVideo = "screen_video"
    }

    public init(
        title: String, language: String = "auto", speakerCount: Int? = nil, microphoneID: String = "",
        displayID: UInt32? = nil, systemAudio: Bool = true, screenVideo: Bool = false
    ) {
        self.title = title
        self.language = language
        self.speakerCount = speakerCount
        self.microphoneID = microphoneID
        self.displayID = displayID
        self.systemAudio = systemAudio
        self.screenVideo = screenVideo
    }
}

public enum CaptureState: String, Codable, Sendable {
    case starting, recording, paused, stopping, stopped

    public var isActive: Bool { self != .stopped }
}

public struct CaptureLevel: Codable, Hashable, Sendable {
    public var rms: Double
    public var peak: Double
    public static let silent = CaptureLevel(rms: 0, peak: 0)
}

public enum CaptureEvent: Sendable {
    case state(CaptureState, elapsed: Double, error: String?)
    case levels(microphone: CaptureLevel?, system: CaptureLevel?, elapsed: Double)
}

func captureHostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// In-process ScreenCaptureKit capture of the selected microphone, optional system
/// audio, and optional screen video. Callbacks, the level timer, and pause/resume
/// commands are all serialized on `queue`; events reach the UI through `events`.
@available(macOS 15.0, *)
public final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let options: CaptureOptions
    public let directory: URL
    public let events: AsyncStream<CaptureEvent>

    private let queue = DispatchQueue(label: "stillnote.capture")
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var stream: SCStream?
    private var timeline = CaptureTimeline(start: 0)
    private var microphone: PCMWriter?
    private var system: PCMWriter?
    private var video: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var timer: DispatchSourceTimer?
    private var stopping = false
    private var failure: String?
    private var lastMic = 0.0
    private var lastSystem = 0.0
    private var microphoneLevel: CaptureLevel?
    private var systemLevel: CaptureLevel?
    private var lastVideoPTS = CMTime.invalid
    private var finished: CheckedContinuation<Void, Never>?

    public init(options: CaptureOptions, directory: URL) {
        self.options = options
        self.directory = directory
        var sink: AsyncStream<CaptureEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { sink = $0 }
        continuation = sink
        super.init()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message(
                "Allow microphone access for Stillnote in System Settings → Privacy & Security → Microphone, then retry."
            )
        }
        let devices = CaptureDeviceCatalog.microphones()
        let mic: String
        if options.microphoneID.isEmpty {
            guard let fallback = AVCaptureDevice.default(for: .audio)?.uniqueID else {
                throw CaptureError.message("No microphone is available. Connect an input and retry.")
            }
            mic = fallback
        } else {
            guard let selected = devices.first(where: { $0.id == options.microphoneID })?.id else {
                throw CaptureError.message(
                    "The selected microphone is disconnected. Choose an available input and retry."
                )
            }
            mic = selected
        }
        // Enumeration and start deliberately happen only after the user starts a recording.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = options.displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("The selected display is disconnected. Refresh the device list and retry.")
        }
        let screen = options.screenVideo
        let config = SCStreamConfiguration()
        config.captureMicrophone = true
        config.microphoneCaptureDeviceID = mic
        config.capturesAudio = options.systemAudio
        config.sampleRate = captureRate
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // Audio-only mode never installs a screen output or writes screen frames.
        let scale = min(1, 1920.0 / Double(display.width))
        config.width = screen ? max(2, Int(Double(display.width) * scale) / 2 * 2) : 2
        config.height = screen ? max(2, Int(Double(display.height) * scale) / 2 * 2) : 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: screen ? 15 : 1)
        config.showsCursor = screen
        config.queueDepth = 5

        microphone = try PCMWriter(url: directory.appendingPathComponent("microphone.wav"))
        if options.systemAudio { system = try PCMWriter(url: directory.appendingPathComponent("system.wav")) }
        if screen { try startVideoWriter(width: config.width, height: config.height) }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        if options.systemAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if screen { try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        stream = capture
        timeline = CaptureTimeline(start: captureHostTime())
        lastMic = timeline.start
        lastSystem = timeline.start
        try await capture.startCapture()
        queue.async {
            guard !self.stopping else { return }
            self.emitState(.recording)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func startVideoWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(
            outputURL: directory.appendingPathComponent("screen.mp4"), fileType: .mp4
        )
        // Fragmented output permits recovery of completed fragments after an interruption.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        // Keep decode and presentation order aligned across removed pauses. Reordered
        // H.264 frames can prevent fragmented MP4 finalization.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.message("Could not start saving screen video.")
        }
        writer.startSession(atSourceTime: .zero)
        video = writer
        videoInput = input
    }

    public func pause() {
        queue.async {
            guard !self.stopping, self.timeline.pausedAt == nil else { return }
            self.timeline.pause(at: captureHostTime())
            self.emitState(.paused)
        }
    }

    public func resume() {
        queue.async {
            guard !self.stopping, self.timeline.pausedAt != nil else { return }
            let now = captureHostTime()
            self.timeline.resume(at: now)
            self.lastMic = now
            self.lastSystem = now
            self.emitState(.recording)
        }
    }

    /// Stops capture, flushes both WAVs, finalizes any screen video, and returns once
    /// every file on disk is complete.
    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.stopping {
                    continuation.resume()
                    return
                }
                self.finished = continuation
                self.finish()
            }
        }
    }

    public var elapsed: Double { timeline.seconds(at: captureHostTime()) }

    // MARK: - Events

    private func emitState(_ state: CaptureState) {
        continuation.yield(.state(state, elapsed: timeline.seconds(at: captureHostTime()), error: failure))
    }

    private func tick() {
        guard !stopping else { return }
        let now = captureHostTime()
        if timeline.pausedAt != nil || now - lastMic > 0.6 { microphoneLevel = .silent }
        if timeline.pausedAt != nil || now - lastSystem > 0.6 { systemLevel = .silent }
        continuation.yield(
            .levels(microphone: microphoneLevel, system: systemLevel, elapsed: timeline.seconds(at: now))
        )
        if timeline.pausedAt == nil, now - lastMic > 8 {
            failure = "Microphone input stopped. The captured audio is available to save. "
                + "Reconnect your microphone before recording again."
            finish()
        } else if timeline.seconds(at: now) >= Validation.maxRecordingSeconds {
            failure = "The 90-minute recording limit was reached. Save this recording and start another."
            finish()
        }
    }

    // MARK: - SCStream

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopping else { return }
            self.failure = "Native capture stopped: \(error.localizedDescription)"
            self.finish()
        }
    }

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard !stopping, timeline.pausedAt == nil, sample.isValid, CMSampleBufferDataIsReady(sample) else {
            return
        }
        // Reject buffers queued before resume, so paused audio cannot overwrite earlier samples.
        guard timeline.accepts(sample.presentationTimeStamp.seconds) else { return }
        let seconds = timeline.seconds(at: sample.presentationTimeStamp.seconds)
        guard seconds < Validation.maxRecordingSeconds + 2 else {
            failure = "Capture timestamps became invalid. Save the captured audio and retry."
            finish()
            return
        }
        do {
            if type == .screen {
                try appendVideo(sample, at: seconds)
            } else {
                guard let buffer = try audioPCMBuffer(from: sample) else { return }
                let isMic = type == .microphone
                let meter = try (isMic ? microphone : system)?.append(buffer, at: seconds) ?? (0, 0)
                let level = CaptureLevel(rms: meter.0, peak: meter.1)
                if isMic {
                    microphoneLevel = level
                    lastMic = captureHostTime()
                } else {
                    systemLevel = level
                    lastSystem = captureHostTime()
                }
            }
        } catch {
            failure = error.localizedDescription
            finish()
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer, at seconds: Double) throws {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
            let input = videoInput, input.isReadyForMoreMediaData
        else { return }
        let pts = CMTime(seconds: seconds, preferredTimescale: 60000)
        guard !lastVideoPTS.isValid || pts > lastVideoPTS else { return }
        var timing = CMSampleTimingInfo(
            duration: sample.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &shifted
        ) == noErr, let shifted, input.append(shifted) else {
            throw video?.error
                ?? CaptureError.message("Screen video could not be written. The audio captured so far can be saved.")
        }
        lastVideoPTS = pts
    }

    // MARK: - Finalization

    private func finish() {
        guard !stopping else { return }
        stopping = true
        timer?.cancel()
        timeline.pause(at: captureHostTime())
        emitState(.stopping)
        let capture = stream
        Task {
            try? await capture?.stopCapture()
            self.queue.async { self.finalizeFiles() }
        }
    }

    private func finalizeFiles() {
        do {
            try microphone?.close()
            try system?.close()
        } catch {
            failure = "Could not flush the recording to disk: \(error.localizedDescription)"
        }
        let complete = { [self] in
            if let video, video.status == .failed, failure == nil {
                failure = "Screen video could not be finalized: "
                    + "\(video.error?.localizedDescription ?? "Unknown error"). Your audio can still be saved."
            }
            emitState(.stopped)
            continuation.finish()
            finished?.resume()
            finished = nil
            stream = nil
        }
        if let writer = video, writer.status == .writing {
            writer.endSession(
                atSourceTime: CMTime(
                    seconds: timeline.seconds(at: captureHostTime()), preferredTimescale: 60000
                )
            )
            videoInput?.markAsFinished()
            writer.finishWriting { self.queue.async(execute: complete) }
        } else {
            complete()
        }
    }
}
