import AVFoundation
import Foundation
import Testing
@testable import StillnoteCore

@Suite struct RecordingSplitTests {
    private func meeting(_ minutes: Double = 50) -> Meeting {
        Meeting(id: "original", title: "Design review", audioName: "recording.wav", language: "en",
                speakerCount: 2, duration: minutes * 60, recordedAt: "2026-10-24T12:00:00Z", source: .recording)
    }

    @Test func thresholdAndOldSettings() throws {
        #expect(!RecordingSplit.eligible(meeting(49.999), thresholdMinutes: 50))
        #expect(RecordingSplit.eligible(meeting(), thresholdMinutes: 50))
        var video = meeting(); video.videoURL = "/video"
        #expect(!RecordingSplit.eligible(video, thresholdMinutes: 50))
        var settings = AppSettings(); settings.splitThresholdMinutes = 65
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).splitThresholdMinutes == 65)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(AppSettings.migrating(from: object).settings.splitThresholdMinutes == 65)
        object.removeValue(forKey: "split_threshold_minutes")
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object)).splitThresholdMinutes == 50)
        object["split_threshold_minutes"] = 0
        #expect(AppSettings.migrating(from: object).settings.splitThresholdMinutes == 50)
    }

    @Test(arguments: [50.0, 60, 90, 120]) func durations(_ minutes: Double) throws {
        let parts = try RecordingSplit.parts(meeting(minutes))
        #expect(parts.count == Int(ceil(minutes / 20)))
        #expect(parts.reduce(0) { $0 + $1.duration } == minutes * 60)
        #expect(parts.allSatisfy { $0.duration > 0 && $0.duration <= 1200 })
        #expect(parts.enumerated().allSatisfy { $0.element.title == "Design review part\($0.offset + 1)" })
        #expect(Set(parts.map(\.id)).count == parts.count)
    }

    @Test func importedAudioBeyondSpeechLimitCanBeSplit() throws {
        var original = meeting(120)
        original.source = .import
        original.recordedAt = nil
        original.audioName = "long-interview.m4a"
        #expect(RecordingSplit.eligible(original, thresholdMinutes: 50))
        let parts = try RecordingSplit.parts(original)
        #expect(parts.count == 6)
        #expect(parts.allSatisfy { $0.duration == 1200 && $0.source == .import && $0.recordedAt == nil })
        #expect(parts.last?.title == "Design review part6")
    }

    @Test func transcriptAndMetadata() throws {
        var original = meeting()
        original.title = String(repeating: "名", count: 240)
        original.notes = "Shared notes"; original.contextLinks = [.init(url: "https://example.com")]
        original.speakers = ["speaker_1": "Alex"]; original.speakerProfiles = ["speaker_1": "profile"]
        original.summary = MeetingSummary(overview: "Old", keyPoints: [], decisions: [], actionItems: [], provider: "codex", model: "test", generatedAt: Meeting.now())
        original.status = .complete
        original.segments = [
            .init(id: "a", start: 1195, end: 1201, speaker: "speaker_1", text: "Before boundary"),
            .init(id: "b", start: 1199, end: 1201, speaker: "speaker_1", text: "Exact midpoint"),
            .init(id: "c", start: 2405, end: 2410, speaker: "speaker_1", text: "Last part")
        ]
        let parts = try RecordingSplit.parts(original)
        #expect(parts.map { $0.segments.map(\.id) } == [["a"], ["b"], ["c"]])
        #expect(parts[0].segments[0].end == 1200)
        #expect(parts[1].segments[0].start == 0 && parts[1].segments[0].end == 1)
        #expect(parts[2].segments[0].start == 5)
        #expect(parts[1].recordedAt == "2026-10-24T12:20:00Z")
        for part in parts {
            #expect(part.summary == nil && part.status == .transcribed)
            #expect(part.notes == original.notes && part.contextLinks == original.contextLinks)
            #expect(part.speakerProfiles == original.speakerProfiles && part.speakers == original.speakers)
            #expect(part.title.count == 240 && !part.automaticTitle)
            #expect(part.cleanup == nil)
        }
    }

    @Test func olderImportsKeepTheirCalendarDate() throws {
        var original = meeting()
        original.source = nil
        original.recordedAt = nil
        original.audioName = "interview.mp3"
        let parts = try RecordingSplit.parts(original)
        #expect(parts.allSatisfy { $0.recordedAt == nil && $0.startDate == original.startDate })
    }

    @Test func replacementRollbackAndRecovery() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let original = meeting()
        try await store.insert(original)
        let parts = try RecordingSplit.parts(original)
        try Data([1]).write(to: paths.audioURL(original.id))
        let journal = RecordingSplitJournal(originalID: original.id, partIDs: parts.map(\.id))
        _ = try journal.prepare(paths: paths)
        try Data([2]).write(to: paths.audioURL(parts[0].id))
        await #expect(throws: StoreError.self) {
            try await store.replaceWithSplit(original: original, parts: [parts[0], parts[0]])
        }
        #expect(try await store.list().count == 1)
        try await RecordingSplitJournal.recover(paths: paths, store: store)
        #expect(FileManager.default.fileExists(atPath: paths.audioURL(original.id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.audioURL(parts[0].id).path))
        try await store.update(original.id) { $0.notes = "New edit" }
        await #expect(throws: ValidationError.self) { try await store.replaceWithSplit(original: original, parts: parts) }
        let latest = try await store.get(original.id)
        _ = try journal.prepare(paths: paths)
        for part in parts { try Data([2]).write(to: paths.audioURL(part.id)) }
        try await store.replaceWithSplit(original: latest, parts: parts)
        try await RecordingSplitJournal.recover(paths: paths, store: store)
        #expect(!FileManager.default.fileExists(atPath: paths.audioURL(original.id).path))
        #expect(try await Store(paths: paths, readOnly: true).list().count == 3)
        #expect(parts.allSatisfy { FileManager.default.fileExists(atPath: paths.audioURL($0.id).path) })
    }

    @Test(arguments: [false, true]) func audioContinuity(compressed: Bool) async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let source = paths.dataDirectory.appendingPathComponent(compressed ? "source.m4a" : "source.wav")
        let rate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        // 20 minutes + one second exercises the real boundary with a small, bounded fixture.
        do {
            let settings: [String: Any] = compressed
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 16000]
                : format.settings
            let output = try AVAudioFile(forWriting: source, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer.frameLength = 8000
            for frame in 0..<8000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.03) * 0.3) }
            for _ in 0..<1201 { try output.write(from: buffer) }
        }
        let input = try AVAudioFile(forReading: source)
        var original = meeting()
        original.duration = Double(input.length) / rate
        let parts = try RecordingSplit.parts(original)
        try RecordingSplit.writeAudio(source: source, parts: parts, directory: paths.dataDirectory)
        var frames: Int64 = 0
        for (index, part) in parts.enumerated() {
            let output = try AVAudioFile(forReading: paths.dataDirectory.appendingPathComponent(part.id + ".wav"))
            #expect(abs(Double(output.length) / rate - part.duration) < 0.001)
            input.framePosition = Int64(index * 1200 * 8000)
            let expected = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 100)!
            let actual = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 100)!
            try input.read(into: expected); try output.read(into: actual)
            for i in 0..<100 { #expect(abs(expected.floatChannelData![0][i] - actual.floatChannelData![0][i]) < 0.00001) }
            frames += output.length
        }
        #expect(frames == input.length)
        #expect(throws: (any Error).self) {
            try RecordingSplit.writeAudio(source: source.appendingPathExtension("missing"), parts: parts, directory: paths.dataDirectory)
        }
    }
}
