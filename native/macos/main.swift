import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

func emit(_ event: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
func hostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
func microphones() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
}
func permissions() -> [String: Any] {
    let microphone: String
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: microphone = "authorized"
    case .denied: microphone = "denied"
    case .restricted: microphone = "restricted"
    case .notDetermined: microphone = "not_determined"
    @unknown default: microphone = "unknown"
    }
    return ["microphone": microphone, "screen_and_system_audio": CGPreflightScreenCaptureAccess()]
}

@available(macOS 15.0, *)
// Callback, timer, and command mutations are serialized on queue after setup.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "stillnote.capture")
    var stream: SCStream?
    var timeline = CaptureTimeline(start: 0)
    var microphone: PCMWriter?
    var system: PCMWriter?
    var video: AVAssetWriter?
    var videoInput: AVAssetWriterInput?
    var timer: DispatchSourceTimer?
    var stopping = false
    var failure: String?
    var lastMic = 0.0
    var lastSystem = 0.0
    var levels: [String: [String: Double]] = [:]
    var lastVideoPTS = CMTime.invalid
    let options: [String: Any]
    let directory: URL

    init(options: [String: Any], directory: URL) { self.options = options; self.directory = directory }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.message("Allow microphone access for Stillnote Capture in System Settings → Privacy & Security → Microphone, then retry.")
        }
        let devices = microphones()
        let requested = options["microphone_id"] as? String ?? ""
        let mic = requested.isEmpty ? AVCaptureDevice.default(for: .audio) : devices.first { $0.uniqueID == requested }
        guard let mic else { throw CaptureError.message("The selected microphone is disconnected. Choose an available input and retry.") }
        // Enumeration and start deliberately happen only after the user clicks Start.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = (options["display_id"] as? UInt32) ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("The selected display is disconnected. Refresh the device list and retry.")
        }
        let screen = options["screen_video"] as? Bool ?? false
        let systemAudio = options["system_audio"] as? Bool ?? true
        let config = SCStreamConfiguration()
        config.captureMicrophone = true; config.microphoneCaptureDeviceID = mic.uniqueID
        config.capturesAudio = systemAudio; config.sampleRate = captureRate; config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // Audio-only mode never installs a screen output or writes screen frames.
        let scale = min(1, 1920.0 / Double(display.width))
        config.width = screen ? max(2, Int(Double(display.width) * scale) / 2 * 2) : 2
        config.height = screen ? max(2, Int(Double(display.height) * scale) / 2 * 2) : 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: screen ? 15 : 1)
        config.showsCursor = screen; config.queueDepth = 5
        microphone = try PCMWriter(url: directory.appendingPathComponent("microphone.wav"))
        if systemAudio { system = try PCMWriter(url: directory.appendingPathComponent("system.wav")) }
        if screen {
            let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("screen.mp4"), fileType: .mp4)
            // Fragmented output permits recovery of completed fragments after an interruption.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 30]
            ])
            input.expectsMediaDataInRealTime = true; writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CaptureError.message("Could not start saving screen video.") }
            writer.startSession(atSourceTime: .zero); video = writer; videoInput = input
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        if systemAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if screen { try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        stream = capture
        timeline = CaptureTimeline(start: hostTime()); lastMic = timeline.start; lastSystem = timeline.start
        try await capture.startCapture()
        queue.async {
            guard !self.stopping else { return }
            self.emitState("recording")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { self.tick() }; self.timer = timer; timer.resume()
        }
    }
    func emitState(_ state: String) {
        emit(["event": "state", "status": state, "elapsed": timeline.seconds(at: hostTime())])
    }
    func command(_ command: String) {
        queue.async {
            guard !self.stopping else { return }
            if command == "pause" { self.timeline.pause(at: hostTime()); self.emitState("paused") }
            else if command == "resume" {
                self.timeline.resume(at: hostTime()); self.lastMic = hostTime(); self.lastSystem = hostTime()
                self.emitState("recording")
            } else if command == "stop" { self.finish() }
        }
    }
    func tick() {
        guard !stopping else { return }
        let now = hostTime()
        for (key, last) in [("microphone", lastMic), ("system", lastSystem)] {
            if timeline.pausedAt != nil || now - last > 0.6 { levels[key] = ["rms": 0, "peak": 0] }
        }
        emit(["event": "levels", "levels": levels, "elapsed": timeline.seconds(at: now)])
        if timeline.pausedAt == nil && now - lastMic > 8 {
            failure = "Microphone input stopped. The captured audio is available to save. Reconnect your microphone before recording again."
            finish()
        } else if timeline.seconds(at: now) >= 90 * 60 {
            failure = "The 90-minute recording limit was reached. Save this recording and start another."
            finish()
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.failure = "Native capture stopped: \(error.localizedDescription)"; self.finish() }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, timeline.pausedAt == nil, sample.isValid, CMSampleBufferDataIsReady(sample) else { return }
        // Reject buffers queued before resume, so paused audio cannot overwrite earlier samples.
        guard timeline.accepts(sample.presentationTimeStamp.seconds) else { return }
        let seconds = timeline.seconds(at: sample.presentationTimeStamp.seconds)
        guard seconds < 90 * 60 + 2 else { failure = "Capture timestamps became invalid. Save the captured audio and retry."; finish(); return }
        do {
            if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                      attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
                      let input = videoInput, input.isReadyForMoreMediaData else { return }
                let pts = CMTime(seconds: seconds, preferredTimescale: 60000)
                guard !lastVideoPTS.isValid || pts > lastVideoPTS else { return }
                var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                var shifted: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted) == noErr,
                      let shifted, input.append(shifted) else {
                    throw video?.error ?? CaptureError.message("Screen video could not be written. The audio captured so far can be saved.")
                }
                lastVideoPTS = pts
            } else {
                guard let description = sample.formatDescription else {
                    throw CaptureError.message("The input audio format could not be read.")
                }
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
                    throw CaptureError.message("The input audio format could not be read.")
                }
                buffer.frameLength = buffer.frameCapacity
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList) == noErr else {
                    throw CaptureError.message("The input audio buffer could not be read.")
                }
                let isMic = type == .microphone
                let meter = try (isMic ? microphone : system)?.append(buffer, at: seconds) ?? (0, 0)
                levels[isMic ? "microphone" : "system"] = ["rms": meter.0, "peak": meter.1]
                if isMic { lastMic = hostTime() } else { lastSystem = hostTime() }
            }
        } catch { failure = error.localizedDescription; finish() }
    }
    func finish() {
        guard !stopping else { return }; stopping = true; timer?.cancel()
        timeline.pause(at: hostTime())
        emitState("stopping")
        Task {
            try? await stream?.stopCapture()
            queue.async {
                do { try self.microphone?.close(); try self.system?.close() }
                catch { self.failure = "Could not flush the recording to disk: \(error.localizedDescription)" }
                let done = {
                    var event: [String: Any] = ["event": "state", "status": "stopped", "elapsed": self.timeline.seconds(at: hostTime())]
                    if let failure = self.failure { event["error"] = failure }
                    if let video = self.video, video.status == .failed { event["error"] = "Screen video could not be finalized. Your audio can still be saved." }
                    emit(event); exit(0)
                }
                if let writer = self.video, writer.status == .writing {
                    writer.endSession(atSourceTime: CMTime(seconds: self.timeline.seconds(at: hostTime()), preferredTimescale: 60000))
                    self.videoInput?.markAsFinished(); writer.finishWriting(completionHandler: done)
                } else { done() }
            }
        }
    }
}

if #available(macOS 15.0, *) {
    if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "permissions" {
        emit(permissions())
    } else if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "authorize" {
        // Explicit setup only: request permissions without opening a capture stream.
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = CGRequestScreenCaptureAccess()
            emit(permissions())
            exit(0)
        }
        dispatchMain()
    } else if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "devices" {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        emit(["microphones": microphones().map { ["id": $0.uniqueID, "name": $0.localizedName] },
              "displays": ids.prefix(Int(count)).map { ["id": $0, "name": "Display \($0)\($0 == CGMainDisplayID() ? " (main)" : "")"] },
              "default_display_id": CGMainDisplayID()])
    } else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "record" {
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("options.json"))
            let options = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let capture = Capture(options: options, directory: directory)
            Task {
                do {
                    try await capture.start()
                    DispatchQueue.global().async {
                        while let line = readLine() { capture.command(line) }
                        capture.command("stop") // Parent exits: finish the files and release all devices.
                    }
                } catch {
                    emit(["event": "state", "status": "stopped", "error": "Capture could not start. Allow Stillnote Capture in System Settings → Privacy & Security → Screen & System Audio Recording and Microphone, then retry. \(error.localizedDescription)"])
                    exit(1)
                }
            }
            dispatchMain()
        } catch { emit(["event": "state", "status": "stopped", "error": error.localizedDescription]); exit(1) }
    } else { emit(["error": "Expected devices, permissions, authorize, or record <session-directory>."]); exit(2) }
} else { emit(["error": "Native capture requires macOS 15 or newer."]); exit(2) }
