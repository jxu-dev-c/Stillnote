import Foundation

/// Transcript line produced by MOSS or edited by the user.
public struct Segment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String

    public init(id: String, start: Double, end: Double, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct ContextLink: Codable, Hashable, Identifiable, Sendable {
    public var url: String
    public var title: String

    public var id: String { url }

    public init(url: String, title: String = "") {
        self.url = url
        self.title = title
    }
}

public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?
    /// Checked off in the summary. Items without the field are open.
    public var completed: Bool?

    public var id: String { "\(text)|\(owner ?? "")|\(due ?? "")" }

    public init(text: String, owner: String? = nil, due: String? = nil, completed: Bool? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
        self.completed = completed
    }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var provider: String
    public var model: String
    public var generatedAt: String
    /// Identifies the notes and links the summary was drawn from; nil for summaries made before
    /// context was sent, or set by hand. See `Meeting.summaryContextChanged`.
    public var contextFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case overview
        case keyPoints = "key_points"
        case decisions
        case actionItems = "action_items"
        case provider
        case model
        case generatedAt = "generated_at"
        case contextFingerprint = "context_fingerprint"
    }

    public init(
        overview: String, keyPoints: [String], decisions: [String], actionItems: [ActionItem],
        provider: String, model: String, generatedAt: String, contextFingerprint: String? = nil
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.provider = provider
        self.model = model
        self.generatedAt = generatedAt
        self.contextFingerprint = contextFingerprint
    }
}

/// What a silence trim removed from a stored recording. The raw per-source captures are
/// deleted when a session is saved, so this is the only record of the original length.
public struct MeetingCleanup: Codable, Hashable, Sendable {
    public var originalDuration: Double
    public var head: Double
    public var tail: Double
    public var appliedAt: String

    enum CodingKeys: String, CodingKey {
        case head, tail
        case originalDuration = "original_duration"
        case appliedAt = "applied_at"
    }

    public init(originalDuration: Double, head: Double, tail: Double, appliedAt: String = Meeting.now()) {
        self.originalDuration = originalDuration
        self.head = head
        self.tail = tail
        self.appliedAt = appliedAt
    }

    public init(plan: CleanupPlan, appliedAt: String = Meeting.now()) {
        self.init(
            originalDuration: plan.originalDuration, head: plan.head, tail: plan.tail,
            appliedAt: appliedAt
        )
    }

    public var removedDuration: Double { head + tail }
}

/// Where a meeting's audio came from. Older documents have none.
public enum MeetingSource: String, Codable, Sendable {
    case recording
    case `import`
}

public enum MeetingStatus: String, Codable, Sendable {
    case ready, transcribing, transcribed, summarizing, complete, error

    /// Processing states that block edits and deletion, matching storage.BUSY.
    public var isBusy: Bool { self == .transcribing || self == .summarizing }
}

/// One meeting, stored as a single JSON document exactly as the Python app wrote it,
/// so an existing stillnote.sqlite3 opens without migration.
public struct Meeting: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var duration: Double
    public var status: MeetingStatus
    public var progress: Double
    public var stage: String
    public var error: String?
    public var audioName: String
    public var audioURL: String
    public var videoURL: String?
    public var language: String
    public var speakerCount: Int?
    public var speakerProfiles: [String: String]
    /// Labels whose profile Stillnote matched by voice, with the match score. A label leaves
    /// this map when the user assigns or unlinks it, which confirms or corrects the match.
    public var autoSpeakerProfiles: [String: Double]
    public var speakers: [String: String]
    public var segments: [Segment]
    public var summary: MeetingSummary?
    public var notes: String
    public var contextLinks: [ContextLink]
    public var cleanup: MeetingCleanup?
    /// When a recording's kept audio began. `createdAt` is when the meeting was saved, which
    /// is after the recording ends. Imports and older recordings have none.
    public var recordedAt: String?
    public var source: MeetingSource?
    /// True while the title is one Stillnote chose rather than one the user typed: a placeholder,
    /// an import's filename, or a title suggested by `MeetingNamer`.
    public var automaticTitle: Bool
    /// Shown in the sidebar's Starred list. Older documents have none.
    public var starred: Bool
    /// The `MeetingTag`s on this meeting, in the order they were applied. A deleted tag's id is
    /// removed from its meetings; an id with no tag left is ignored.
    public var tagIDs: [String] { didSet { legacyCategoryID = tagIDs.first } }
    /// The first tag, written as `category_id` so a build from before tags still shows one.
    /// Only read when a document has no `tag_ids`.
    private var legacyCategoryID: String?
    /// Earlier builds stored false even for untouched default titles. This marker
    /// distinguishes their records from explicit title choices saved by the corrected form.
    private var titleOwnershipVersion = 1

    enum CodingKeys: String, CodingKey {
        case id, title, duration, status, progress, stage, error, language, speakers, segments, summary, notes, cleanup
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case audioName = "audio_name"
        case audioURL = "audio_url"
        case videoURL = "video_url"
        case speakerProfiles = "speaker_profiles"
        case autoSpeakerProfiles = "auto_speaker_profiles"
        case speakerCount = "speaker_count"
        case contextLinks = "context_links"
        case recordedAt = "recorded_at"
        case source
        case automaticTitle = "automatic_title"
        case titleOwnershipVersion = "title_ownership_version"
        case starred
        case tagIDs = "tag_ids"
        case legacyCategoryID = "category_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = try values.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .ready
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        stage = try values.decodeIfPresent(String.self, forKey: .stage) ?? ""
        error = try values.decodeIfPresent(String.self, forKey: .error)
        audioName = try values.decodeIfPresent(String.self, forKey: .audioName) ?? "recording.wav"
        audioURL = try values.decodeIfPresent(String.self, forKey: .audioURL) ?? ""
        // Legacy rows predate these fields; storage.py applied the same defaults on read.
        videoURL = try values.decodeIfPresent(String.self, forKey: .videoURL)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        speakerCount = try values.decodeIfPresent(Int.self, forKey: .speakerCount)
        speakerProfiles = try values.decodeIfPresent([String: String].self, forKey: .speakerProfiles) ?? [:]
        autoSpeakerProfiles = (try? values.decodeIfPresent([String: Double].self, forKey: .autoSpeakerProfiles)) ?? [:]
        speakers = try values.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
        segments = try values.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        summary = try values.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        contextLinks = try values.decodeIfPresent([ContextLink].self, forKey: .contextLinks) ?? []
        cleanup = try values.decodeIfPresent(MeetingCleanup.self, forKey: .cleanup)
        recordedAt = try values.decodeIfPresent(String.self, forKey: .recordedAt)
        // A value from a newer build is treated as unknown rather than failing the document.
        source = (try? values.decodeIfPresent(MeetingSource.self, forKey: .source)) ?? nil
        starred = (try? values.decodeIfPresent(Bool.self, forKey: .starred)) ?? false
        let legacyCategory = (try? values.decodeIfPresent(String.self, forKey: .legacyCategoryID)) ?? nil
        let storedTags = (try? values.decodeIfPresent([String].self, forKey: .tagIDs)) ?? nil
        tagIDs = Meeting.normalizedTags(storedTags ?? [legacyCategory].compactMap { $0 })
        legacyCategoryID = tagIDs.first
        let storedAutomaticTitle = try values.decodeIfPresent(Bool.self, forKey: .automaticTitle)
        automaticTitle = storedAutomaticTitle ?? false
        let storedTitleOwnershipVersion = try values.decodeIfPresent(Int.self, forKey: .titleOwnershipVersion) ?? 0
        titleOwnershipVersion = max(1, storedTitleOwnershipVersion)
        // Older imports and re-saved recording placeholders could carry false despite never
        // being named. Records saved by this build have the marker and retain their ownership.
        if storedTitleOwnershipVersion < 1, !automaticTitle {
            let source = URL(fileURLWithPath: audioName)
            let matchesFilename = title == source.lastPathComponent
                || title == source.deletingPathExtension().lastPathComponent
            automaticTitle = (matchesFilename && (storedAutomaticTitle == nil || audioName != "recording.wav"))
                || (audioName == "recording.wav" && createdDate != .distantPast
                    && title == CaptureOptions.defaultTitle(for: createdDate))
        }
    }

    public init(
        id: String, title: String, audioName: String, language: String, speakerCount: Int?,
        duration: Double, videoName: String? = nil, error: String? = nil,
        cleanup: MeetingCleanup? = nil, automaticTitle: Bool = false, recordedAt: String? = nil,
        source: MeetingSource? = nil
    ) {
        let timestamp = Meeting.now()
        self.id = id
        self.title = title
        self.createdAt = timestamp
        self.updatedAt = timestamp
        self.duration = duration
        self.status = .ready
        self.progress = 0
        self.stage = "Ready to transcribe"
        self.error = error
        self.audioName = audioName
        self.audioURL = "/api/meetings/\(id)/audio"
        self.videoURL = videoName == nil ? nil : "/api/meetings/\(id)/video"
        self.language = language
        self.speakerCount = speakerCount
        self.speakerProfiles = [:]
        self.autoSpeakerProfiles = [:]
        self.speakers = [:]
        self.segments = []
        self.summary = nil
        self.notes = ""
        self.contextLinks = []
        self.cleanup = cleanup
        self.recordedAt = recordedAt
        self.source = source
        self.automaticTitle = automaticTitle
        self.starred = false
        self.tagIDs = []
        self.legacyCategoryID = nil
    }

    public var hasVideo: Bool { videoURL != nil }

    /// Adds tags not already on the meeting, after the ones it has. Returns the ids added.
    @discardableResult
    public mutating func addTags(_ ids: [String]) -> [String] {
        let added = Meeting.normalizedTags(ids).filter { !tagIDs.contains($0) }
        if !added.isEmpty { tagIDs += added }
        return added
    }

    public mutating func removeTag(_ id: String) {
        tagIDs.removeAll { $0 == id }
    }

    /// Drops empty and repeated ids, keeping the first occurrence of each.
    public static func normalizedTags(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A blank import title uses the filename until a summary supplies a descriptive title.
    /// Keeping the typed title separate from that fallback preserves explicit user choices.
    public static func imported(
        id: String, from url: URL, title: String, language: String, speakerCount: Int?, duration: Double
    ) throws -> Meeting {
        let typedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTitle = typedTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : typedTitle
        return Meeting(
            id: id, title: try Validation.title(initialTitle),
            audioName: String(url.lastPathComponent.prefix(240)), language: language,
            speakerCount: speakerCount, duration: duration, automaticTitle: typedTitle.isEmpty,
            source: .import
        )
    }

    public static func now() -> String { timestamp(Date()) }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        // Python emits +00:00; ISO8601DateFormatter emits Z. Both parse, and only
        // string ordering matters for sorting, which is unaffected by the suffix.
        return formatter.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    public static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    public var createdDate: Date {
        Meeting.parseTimestamp(createdAt) ?? .distantPast
    }

    /// When the meeting took place, for the calendar. An import has no known recording time,
    /// so it stays at the time it was imported. A recording saved before `recorded_at`
    /// existed is estimated from its save time: it ended just before it was saved, and
    /// trimmed silence was cut from its tail after the kept audio. Documents that old also
    /// predate `source`, so an import of a file named `recording.wav` from then is
    /// indistinguishable from a recording and is estimated the same way.
    public var startDate: Date {
        if let recordedAt, let date = Meeting.parseTimestamp(recordedAt) { return date }
        let created = createdDate
        guard source != .import, audioName == "recording.wav", created != .distantPast else { return created }
        return created.addingTimeInterval(-(duration + (cleanup?.tail ?? 0)))
    }

    /// Display name for a segment's speaker id, falling back to the raw id.
    public func speakerName(_ id: String) -> String { speakers[id] ?? id }

    public func orderedSpeakerIDs() -> [String] { speakers.keys.sorted() }

    /// Adopts a title Stillnote suggested. It counts as Stillnote's choice until the user types
    /// one. A split part keeps its ` partN` suffix, trimming the suggestion to fit the limit.
    public mutating func applySuggestedTitle(_ suggested: String, suffix: String = "") {
        title = String(suggested.prefix(max(0, Validation.maxTitleLength - suffix.count))) + suffix
        automaticTitle = true
    }
}

extension Meeting {
    /// The meeting's notes or links changed after its summary was made from them, including
    /// while that summary was running. Summaries without a fingerprint are never flagged.
    public var summaryContextChanged: Bool {
        guard let fingerprint = summary?.contextFingerprint else { return false }
        return fingerprint != Summarizer.contextFingerprint(self)
    }
}
