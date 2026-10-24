import AVFoundation
import Foundation

/// Pure planning and transcript mapping, shared by the confirmation sheet and writer.
public enum RecordingSplit {
    public static let partSeconds: Double = 1_200
    public static func eligible(_ meeting: Meeting, thresholdMinutes: Int) -> Bool {
        !meeting.hasVideo && meeting.duration.isFinite
            && meeting.duration >= Double(thresholdMinutes) * 60
            && meeting.duration > partSeconds
    }

    public static func parts(_ meeting: Meeting) throws -> [Meeting] {
        guard !meeting.hasVideo, meeting.duration.isFinite,
              meeting.duration > partSeconds,
              let count = Int(exactly: ceil(meeting.duration / partSeconds)) else {
            throw ValidationError("Choose a pure audio recording longer than 20 minutes with a valid duration.")
        }
        let hasRecordingTime = meeting.recordedAt != nil || meeting.source == .recording
            || (meeting.source == nil && meeting.audioName == "recording.wav")
        var parts = (0..<count).map { index -> Meeting in
            let offset = Double(index) * partSeconds
            let suffix = " part\(index + 1)"
            var part = Meeting(
                id: UUID().uuidString.lowercased(),
                title: String(meeting.title.prefix(Validation.maxTitleLength - suffix.count)) + suffix,
                audioName: "part\(index + 1).wav", language: meeting.language,
                speakerCount: meeting.speakerCount, duration: min(partSeconds, meeting.duration - offset),
                recordedAt: hasRecordingTime
                    ? ISO8601DateFormatter().string(from: meeting.startDate.addingTimeInterval(offset)) : nil,
                source: meeting.source
            )
            part.createdAt = meeting.createdAt
            part.notes = meeting.notes
            part.contextLinks = meeting.contextLinks
            part.speakers = meeting.speakers
            part.speakerProfiles = meeting.speakerProfiles
            part.status = meeting.segments.isEmpty ? .ready : .transcribed
            part.stage = meeting.segments.isEmpty ? "Ready to transcribe" : "Transcript split"
            return part
        }
        for var segment in meeting.segments {
            guard segment.start.isFinite, segment.end.isFinite else {
                throw ValidationError("The transcript contains invalid timestamps.")
            }
            let midpoint = max(0, min(meeting.duration, (segment.start + segment.end) / 2))
            let index = min(count - 1, Int(midpoint / partSeconds))
            let offset = Double(index) * partSeconds
            segment.start = max(0, min(parts[index].duration, segment.start - offset))
            segment.end = max(segment.start, min(parts[index].duration, segment.end - offset))
            parts[index].segments.append(segment)
        }
        return parts
    }

    /// Decode each source only once; preserve sample rate and channels, with bounded buffers.
    public static func writeAudio(source: URL, parts: [Meeting], directory: URL,
                                  progress: @Sendable (Int) -> Void = { _ in }) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)) else {
            throw ValidationError("This recording cannot be decoded for splitting.")
        }
        let expected = parts.reduce(0) { $0 + $1.duration }
        guard abs(Double(input.length) / rate - expected) < 0.1 else {
            throw ValidationError("The audio duration has changed. The original recording was kept.")
        }
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let start = min(input.length, Int64((Double(index) * partSeconds * rate).rounded()))
            let end = index == parts.count - 1 ? input.length
                : min(input.length, Int64((Double(index + 1) * partSeconds * rate).rounded()))
            guard end > start else { throw ValidationError("An audio segment would be empty.") }
            let url = directory.appendingPathComponent(part.id + ".wav")
            let output = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            input.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity))))
                guard buffer.frameLength > 0 else { throw ValidationError("The audio ended before the split was complete.") }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            progress(index + 1)
        }
        // Reopen finalized files before allowing the database replacement.
        for part in parts {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(part.id + ".wav"))
            guard abs(Double(file.length) / file.processingFormat.sampleRate - part.duration) < 0.1 else {
                throw ValidationError("A split file failed verification. The original recording was kept.")
            }
        }
    }
}

/// Durable intent lets launch clean either an interrupted export or the retired original.
public struct RecordingSplitJournal: Codable, Sendable {
    public let originalID: String
    public let partIDs: [String]
    public init(originalID: String, partIDs: [String]) {
        self.originalID = originalID
        self.partIDs = partIDs
    }
    public static func root(_ paths: Paths) -> URL { paths.dataDirectory.appendingPathComponent("splits") }
    public func prepare(paths: Paths) throws -> URL {
        let directory = Self.root(paths).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
        return directory
    }
    public static func recover(paths: Paths, store: Store) async throws {
        let root = root(paths)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for directory in directories {
            let file = directory.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: file.path) else {
                try FileManager.default.removeItem(at: directory)
                continue
            }
            let journal = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            let meetings = try await store.list()
            let originalExists = meetings.contains { $0.id == journal.originalID }
            for id in originalExists ? journal.partIDs : [journal.originalID] {
                let audio = paths.audioURL(id)
                if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                MediaFile.forget(id, paths: paths)
            }
            try FileManager.default.removeItem(at: directory)
        }
    }
}
