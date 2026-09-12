import Foundation

/// Input bounds that used to live in the API's pydantic schemas. In-process they are
/// the single source of truth for form validation and for guarding stored documents.
public enum Validation {
    public static let maxTitleLength = 240
    public static let maxRecordingTitleLength = 200
    public static let maxNotesLength = 100_000
    public static let maxContextLinks = 100
    public static let maxLinkURLLength = 4096
    public static let maxLinkTitleLength = 240
    public static let maxSpeakers = 100
    public static let maxSpeakerNameLength = 100
    public static let maxSegments = 100_000
    public static let maxSegmentTextLength = 50_000
    public static let maxSummaryModelLength = 200
    public static let maxAudioBytes = 2 * 1024 * 1024 * 1024
    public static let speakerCountRange = 1...20
    public static let maxRecordingSeconds: Double = 90 * 60

    public static func title(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTitleLength else {
            throw ValidationError("Use a title between 1 and \(maxTitleLength) characters.")
        }
        return trimmed
    }

    public static func language(_ value: String) throws -> String {
        guard value.count >= 2, value.count <= 20,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") })
        else {
            throw ValidationError("Use an ISO language code or auto.")
        }
        return value
    }

    public static func speakerCount(_ value: Int?) throws -> Int? {
        guard let value else { return nil }
        guard speakerCountRange.contains(value) else {
            throw ValidationError("Choose between 1 and 20 speakers, or automatic detection.")
        }
        return value
    }

    public static func speakerName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxSpeakerNameLength else {
            throw ValidationError("Use a nonempty speaker name of at most 100 characters.")
        }
        return trimmed
    }

    /// Accepts http(s) links without embedded credentials, adding a scheme when omitted.
    public static func contextLinkURL(_ value: String, existing: [ContextLink] = []) throws -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://"),
           !text.contains("://") {
            text = "https://" + text
        }
        guard text.count <= maxLinkURLLength, let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else {
            throw ValidationError("Enter a valid http or https website link without a username or password.")
        }
        let normalized = components.string ?? text
        guard !existing.contains(where: { $0.url == normalized }) else {
            throw ValidationError("This link is already in your context.")
        }
        return normalized
    }

    public static func segments(_ segments: [Segment], duration: Double) throws -> [Segment] {
        guard segments.count <= maxSegments else {
            throw ValidationError("This transcript has too many segments to save.")
        }
        var identifiers = Set<String>()
        for segment in segments {
            guard !segment.id.isEmpty, identifiers.insert(segment.id).inserted else {
                throw ValidationError("Transcript segment IDs must be unique.")
            }
            guard segment.start >= 0, segment.end >= segment.start else {
                throw ValidationError("Segment end must follow its start.")
            }
            guard segment.end <= duration + 2 else {
                throw ValidationError("Transcript timestamps must fit within the recording.")
            }
            guard segment.text.count <= maxSegmentTextLength else {
                throw ValidationError("A transcript segment is too long to save.")
            }
        }
        return segments.sorted { $0.start < $1.start }
    }
}

public struct ValidationError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
