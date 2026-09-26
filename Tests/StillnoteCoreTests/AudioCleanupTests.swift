import AVFoundation
import Foundation
import Testing

@testable import StillnoteCore

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func range(_ start: Double, _ end: Double) -> SpeechRange {
    SpeechRange(start: start, end: end)
}

/// Writes a captured-format WAV — mono, 48 kHz, 16-bit — whose samples are a ramp, so a
/// trim can be checked sample by sample against the source position it came from.
private func writeRamp(seconds: Double, to url: URL) throws {
    let frames = AVAudioFrameCount(seconds * Double(captureRate))
    let working = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1, interleaved: false
    )!
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(captureRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ],
        commonFormat: working.commonFormat, interleaved: working.isInterleaved
    )
    let block = AVAudioFrameCount(captureRate)
    var written: AVAudioFrameCount = 0
    let buffer = AVAudioPCMBuffer(pcmFormat: working, frameCapacity: block)!
    while written < frames {
        let length = min(block, frames - written)
        buffer.frameLength = length
        for index in 0..<Int(length) {
            // A slow triangle keeps every value well inside 16-bit precision.
            let position = Double(written) + Double(index)
            buffer.floatChannelData![0][index] = Float(sin(position / 8000) * 0.5)
        }
        try file.write(from: buffer)
        written += length
    }
}

private func writePCM(_ samples: [Float], to url: URL) throws {
    try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
}

private func readPCM(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    var samples = [Float](repeating: 0, count: data.count / 4)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return samples
}

@Suite struct CleanupPolicyTests {
    private let settings = AudioCleanupSettings()

    /// The case the feature exists for: a recording that kept running long after the
    /// meeting ended keeps its speech plus padding and loses the rest.
    @Test func keepsSpeechWithPaddingAndDropsTheRest() {
        let plan = AudioCleanup.plan(
            ranges: [range(18, 25)], duration: 120, settings: settings, allowHeadCut: true
        )
        #expect(plan.head == 16)
        #expect(plan.tail == 92)
        #expect(plan.keptDuration == 12)
        #expect(plan.trimsAnything)
    }

    /// A single keystroke or chair scrape near the end must not define where the meeting
    /// ended. Without the sustained-run floor this returns a plan that trims nothing,
    /// silently disabling the feature for anyone who touches their keyboard.
    @Test func shortNoiseBurstsDoNotMoveTheBoundaries() {
        let plan = AudioCleanup.plan(
            ranges: [range(18, 25), range(110, 110.1)], duration: 120, settings: settings,
            allowHeadCut: true
        )
        #expect(plan.tail == 92)
        #expect(plan.keptDuration == 12)
    }

    /// No speech at all means the detector did not understand the recording. Truncating on
    /// that basis could destroy a whole meeting, so nothing is removed.
    @Test func noDetectedSpeechTrimsNothing() {
        let plan = AudioCleanup.plan(ranges: [], duration: 600, settings: settings, allowHeadCut: true)
        #expect(!plan.trimsAnything)
        #expect(plan.keptDuration == 600)

        let onlyNoise = AudioCleanup.plan(
            ranges: [range(5, 5.2), range(300, 300.3)], duration: 600, settings: settings,
            allowHeadCut: true
        )
        #expect(!onlyNoise.trimsAnything)
    }

    @Test func speechThroughoutTrimsNothing() {
        let plan = AudioCleanup.plan(
            ranges: [range(0.5, 599)], duration: 600, settings: settings, allowHeadCut: true
        )
        #expect(!plan.trimsAnything)
    }

    /// Rewriting a recording to save a few seconds is not worth it.
    @Test func savingsBelowTheThresholdAreIgnored() {
        let plan = AudioCleanup.plan(
            ranges: [range(2, 27)], duration: 30, settings: settings, allowHeadCut: true
        )
        #expect(!plan.trimsAnything)
    }

    /// What is left has to still be a meeting.
    @Test func aTrimThatLeavesAlmostNothingIsRejected() {
        let plan = AudioCleanup.plan(
            ranges: [range(100, 104)], duration: 300, settings: settings, allowHeadCut: true
        )
        #expect(!plan.trimsAnything)
    }

    /// A compressed video passthrough cannot begin mid-GOP, so those sessions only ever
    /// lose their tail.
    @Test func headCutsAreSuppressedForVideoSessions() {
        let plan = AudioCleanup.plan(
            ranges: [range(200, 260)], duration: 600, settings: settings, allowHeadCut: false
        )
        #expect(plan.head == 0)
        #expect(plan.tail == 337)
        #expect(plan.keptDuration == 263)
    }

    @Test func trimmingCanBeTurnedOffEntirely() {
        var off = AudioCleanupSettings()
        off.minimumTrimSeconds = .greatestFiniteMagnitude
        let plan = AudioCleanup.plan(
            ranges: [range(18, 25)], duration: 1200, settings: off, allowHeadCut: true
        )
        #expect(!plan.trimsAnything)
    }
}

@Suite struct CleanupTrimTests {
    /// The kept span survives byte for byte, at the expected length, in a file the rest of
    /// the app can still open.
    @Test func trimKeepsExactlyTheKeptSpan() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("trimmed.wav")
        try writeRamp(seconds: 30, to: source)

        let plan = CleanupPlan(originalDuration: 30, head: 5, tail: 10)
        let duration = try AudioCleanup.trim(wav: source, to: destination, plan: plan)
        #expect(abs(duration - 15) < 0.001)

        let original = try AVAudioFile(forReading: source)
        let trimmed = try AVAudioFile(forReading: destination)
        #expect(trimmed.length == Int64(15 * captureRate))
        #expect(Int(trimmed.fileFormat.sampleRate) == captureRate)
        #expect(trimmed.fileFormat.channelCount == 1)
        #expect(trimmed.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)

        // The first kept sample must be the sample that was at five seconds.
        let format = trimmed.processingFormat
        let expected = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        original.framePosition = Int64(5 * captureRate)
        try original.read(into: expected, frameCount: 1024)
        let actual = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        try trimmed.read(into: actual, frameCount: 1024)
        #expect(actual.frameLength == expected.frameLength)
        for index in 0..<Int(actual.frameLength) {
            #expect(actual.floatChannelData![0][index] == expected.floatChannelData![0][index])
        }

        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func trimRefusesAnUnsupportedFormat() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let working = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false
        )!
        let file = try AVAudioFile(forWriting: source, settings: working.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: working, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        try file.write(from: buffer)

        #expect(throws: AudioMixError.self) {
            _ = try AudioCleanup.trim(
                wav: source, to: directory.appendingPathComponent("out.wav"),
                plan: CleanupPlan(originalDuration: 1, head: 0, tail: 0.5)
            )
        }
    }
}

@Suite struct CleanupGateTests {
    private let rate = AudioDecoder.sampleRate

    /// Speech passes through untouched while everything outside it is silenced. Speech that
    /// came out altered would mean recognition sees a reconstruction rather than the signal.
    @Test func speechSurvivesUnchangedAndSilenceIsZeroed() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.f32")
        let destination = directory.appendingPathComponent("out.f32")

        // Ten seconds of constant tone; speech is declared only over 4–6 s.
        let samples = [Float](repeating: 0.25, count: 10 * rate)
        try writePCM(samples, to: source)

        let plan = CleanupPlan.noTrim(duration: 10)
        let written = try AudioCleanup.preparePCM(
            source: source, destination: destination, ranges: [range(4, 6)], plan: plan,
            suppressNonSpeech: true
        )
        #expect(written == 10 * rate)
        let output = try readPCM(destination)
        #expect(output.count == 10 * rate)

        // Mid-speech is bit-exact.
        for index in (4 * rate + 200)..<(6 * rate - 200) {
            #expect(output[index] == 0.25)
        }
        // Well outside the speech and its ramp, everything is silent.
        #expect(output[0] == 0)
        #expect(output[2 * rate] == 0)
        #expect(output[9 * rate] == 0)
        // The boundary is a fade, not a step, so no click is introduced.
        let entering = output[(4 * rate - 80)]
        #expect(entering > 0)
        #expect(entering < 0.25)
    }

    /// Head trimming and gating compose: the output starts at the kept offset.
    @Test func trimmingAndGatingApplyTogether() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.f32")
        let destination = directory.appendingPathComponent("out.f32")
        var samples = [Float](repeating: 0, count: 120 * rate)
        for index in (20 * rate)..<(30 * rate) { samples[index] = 0.5 }
        try writePCM(samples, to: source)

        let plan = AudioCleanup.plan(
            ranges: [range(20, 30)], duration: 120, settings: AudioCleanupSettings(), allowHeadCut: true
        )
        #expect(plan.head == 18)
        #expect(plan.tail == 87)
        let written = try AudioCleanup.preparePCM(
            source: source, destination: destination, ranges: [range(20, 30)], plan: plan,
            suppressNonSpeech: true
        )
        #expect(written == 15 * rate)
        let output = try readPCM(destination)
        // Two seconds of lead padding come first, then the speech.
        #expect(output[0] == 0)
        #expect(output[2 * rate + 200] == 0.5)
    }

    /// With suppression off the kept span is copied through verbatim.
    @Test func suppressionOffCopiesTheSpanVerbatim() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("in.f32")
        let destination = directory.appendingPathComponent("out.f32")
        let samples = (0..<(5 * rate)).map { Float($0 % 100) / 200 }
        try writePCM(samples, to: source)

        _ = try AudioCleanup.preparePCM(
            source: source, destination: destination, ranges: [], plan: CleanupPlan.noTrim(duration: 5),
            suppressNonSpeech: false
        )
        #expect(try readPCM(destination) == samples)
    }
}

@Suite struct CleanupTranscriptTests {
    /// Timestamps from a trimmed copy are put back on the stored recording's timeline, and
    /// still satisfy the validation the store applies before saving.
    @Test func parserOffsetRestoresTheOriginalTimeline() throws {
        let text = "[0.00][S01]Hello there[2.00][2.50][S02]Hi[4.00]"
        let shifted = try MossParser.parse(text, duration: 600, language: "en", offset: 120)
        #expect(shifted.segments.first?.start == 120)
        #expect(shifted.segments.first?.end == 122)
        #expect(shifted.segments.last?.end == 124)
        #expect(throws: Never.self) {
            _ = try Validation.segments(shifted.segments, duration: 600)
        }
    }

    /// The offset never pushes a segment past the end of the recording.
    @Test func offsetStaysInsideTheRecording() throws {
        let result = try MossParser.parse(
            "[0.00][S01]Late[5.00]", duration: 10, language: "en", offset: 8
        )
        #expect(result.segments.first?.start == 8)
        #expect(result.segments.first?.end == 10)
    }

    @Test func withoutAnOffsetTimestampsAreUnchanged() throws {
        let result = try MossParser.parse("[1.00][S01]Plain[2.00]", duration: 60, language: "en")
        #expect(result.segments.first?.start == 1)
        #expect(result.segments.first?.end == 2)
    }
}

@Suite struct CleanupSettingsTests {
    /// Records written before cleanup existed must load with the defaults on, not with a
    /// zeroed struct that would silently disable the feature.
    @Test func settingsDefaultWhenTheKeyIsAbsent() {
        let (settings, changed) = AppSettings.migrating(from: [
            "transcription": ["model": SpeechCatalog.defaultModel, "language": "auto"],
            "summary": ["provider": "codex", "model": "gpt-5.6-luna", "agent_prompt": "x"],
        ])
        #expect(settings.cleanup.trimRecording)
        #expect(settings.cleanup.suppressNonSpeech)
        #expect(settings.cleanup.sensitivity == .balanced)
        #expect(settings.cleanup.minimumTrimSeconds == 60)
        #expect(changed)
    }

    @Test func storedCleanupValuesSurviveMigration() {
        let (settings, _) = AppSettings.migrating(from: [
            "transcription": ["model": SpeechCatalog.defaultModel, "language": "auto"],
            "summary": ["provider": "codex", "model": "gpt-5.6-luna", "agent_prompt": "x"],
            "cleanup": [
                "trim_recording": false, "suppress_non_speech": true,
                "sensitivity": "aggressive", "minimum_trim_seconds": 120,
            ],
        ])
        #expect(!settings.cleanup.trimRecording)
        #expect(settings.cleanup.suppressNonSpeech)
        #expect(settings.cleanup.sensitivity == .aggressive)
        #expect(settings.cleanup.minimumTrimSeconds == 120)
        // Unlisted keys keep their defaults rather than becoming zero.
        #expect(settings.cleanup.leadPadding == 2)
    }

    @Test func cleanupSettingsRoundTripThroughCoding() throws {
        var original = AppSettings()
        original.cleanup.sensitivity = .conservative
        original.cleanup.trailPadding = 7
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(original)
        )
        #expect(decoded.cleanup == original.cleanup)
    }

    /// The supporting model must never be offered as a transcription engine.
    @Test func theDetectorIsNotSelectableAsAnEngine() {
        #expect(SpeechCatalog.models[SpeechCatalog.vadModel]?.kind == .vad)
        #expect(SpeechCatalog.transcriptionModels[SpeechCatalog.vadModel] == nil)
        #expect(SpeechCatalog.transcriptionModels[SpeechCatalog.defaultModel] != nil)
        let (settings, changed) = AppSettings.migrating(from: [
            "transcription": ["model": SpeechCatalog.vadModel, "language": "auto"],
            "summary": ["provider": "codex", "model": "gpt-5.6-luna", "agent_prompt": "x"],
        ])
        #expect(settings.transcription.model == SpeechCatalog.defaultModel)
        #expect(changed)
    }

    /// MOSS predates the manifest's directory key, so its install path must not move.
    @Test func modelDirectoriesResolveFromTheManifest() {
        let root = URL(fileURLWithPath: "/models")
        #expect(
            SpeechCatalog.directory(modelDirectory: root, model: SpeechCatalog.defaultModel).path
                == "/models/speech/moss-0.9b-mlx-8bit"
        )
        #expect(
            SpeechCatalog.directory(modelDirectory: root, model: SpeechCatalog.vadModel).path
                == "/models/speech/silero-vad"
        )
    }
}

@Suite struct SpeechRangeParsingTests {
    /// The worker's ranges arrive over the same pipe native libraries print diagnostics on.
    /// A malformed pair must be dropped, never turned into a range that silences or
    /// truncates the wrong audio.
    @Test func onlyWellFormedRangesAreAccepted() async {
        let collector = WorkerOutput { _, _ in }
        await collector.read(from: try! pipe(containing: """
        STILLNOTE_EVENT {"type":"ranges","ranges":[[1.0,2.0],[3.0],[5.0,4.0],[6.0,7.5],["a","b"]]}
        """))
        let ranges = await collector.ranges
        #expect(ranges?.count == 2)
        #expect(ranges?.first == SpeechRange(start: 1, end: 2))
        #expect(ranges?.last == SpeechRange(start: 6, end: 7.5))
    }

    @Test func aRunWithNoRangesEventReportsNothing() async {
        let collector = WorkerOutput { _, _ in }
        await collector.read(from: try! pipe(containing: "noise on the pipe\n"))
        #expect(await collector.ranges == nil)
    }

    private func pipe(containing text: String) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((text + "\n").utf8).write(to: url)
        return try FileHandle(forReadingFrom: url)
    }
}
