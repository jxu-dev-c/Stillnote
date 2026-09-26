import Foundation

public enum SearchField: String, Codable, CaseIterable, Sendable {
    case title, transcript, summary, notes
}

public struct MeetingFilter: Hashable, Sendable {
    public var since: Date?
    public var until: Date?
    public var status: MeetingStatus?
    /// Substring of a speaker's display name or diarization id, matched case-insensitively.
    public var speaker: String?
    public var limit: Int?

    public init(
        since: Date? = nil, until: Date? = nil, status: MeetingStatus? = nil, speaker: String? = nil,
        limit: Int? = nil
    ) {
        self.since = since
        self.until = until
        self.status = status
        self.speaker = speaker
        self.limit = limit
    }
}

public struct SearchHit: Codable, Hashable, Sendable {
    public var field: SearchField
    public var snippet: String
    public var speaker: String?
    public var start: Double?

    enum CodingKeys: String, CodingKey { case field, snippet, speaker, start }

    public init(field: SearchField, snippet: String, speaker: String? = nil, start: Double? = nil) {
        self.field = field
        self.snippet = snippet
        self.speaker = speaker
        self.start = start
    }
}

public struct SearchResult: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var speakers: [String]
    public var matches: Int
    public var hits: [SearchHit]

    enum CodingKeys: String, CodingKey {
        case id, title, speakers, matches, hits
        case createdAt = "created_at"
    }
}

/// One row of `stillnote list`: enough to choose a meeting without shipping its transcript.
public struct MeetingDigest: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var duration: Double
    public var status: MeetingStatus
    public var speakers: [String]
    public var segments: Int
    public var hasSummary: Bool
    public var hasNotes: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, duration, status, speakers, segments
        case createdAt = "created_at"
        case hasSummary = "has_summary"
        case hasNotes = "has_notes"
    }

    public init(_ meeting: Meeting) {
        id = meeting.id
        title = meeting.title
        createdAt = meeting.createdAt
        duration = meeting.duration
        status = meeting.status
        speakers = meeting.orderedSpeakerIDs().map { meeting.speakerName($0) }
        segments = meeting.segments.count
        hasSummary = meeting.summary != nil
        hasNotes = !meeting.notes.isEmpty
    }
}

/// Reading and searching a library. Built on `Store.list()`, which decodes every row: at the
/// scale of one person's meetings that is cheaper than maintaining a second index, and it keeps
/// the CLI's answers identical to the app's.
public enum MeetingQuery {
    /// Accepts `YYYY-MM-DD` and `YYYY-MM`, returning the half-open range that covers it. An
    /// agent translating "back in May" passes `--since 2026-05 --until 2026-05`, and the whole
    /// month is included because `until` resolves to the end of its unit.
    public static func range(_ text: String) throws -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let numbers = parts.compactMap(Int.init)
        // Insist on a four-digit year: '26-05-01' would otherwise resolve to the year 26.
        guard numbers.count == parts.count, (2...3).contains(parts.count), parts[0].count == 4,
              let year = numbers.first, (1...12).contains(numbers.count > 1 ? numbers[1] : 1)
        else {
            throw CLIError.usage("Use a date like 2026-05-17 or a month like 2026-05, not '\(text)'.")
        }
        var components = DateComponents(year: year, month: numbers[1], day: parts.count == 3 ? numbers[2] : 1)
        components.calendar = calendar
        guard let start = calendar.date(from: components), components.isValidDate else {
            throw CLIError.usage("'\(text)' is not a real date.")
        }
        let unit: Calendar.Component = parts.count == 3 ? .day : .month
        guard let end = calendar.date(byAdding: unit, value: 1, to: start) else {
            throw CLIError.usage("'\(text)' is not a usable date.")
        }
        return (start, end)
    }

    public static func filter(_ meetings: [Meeting], _ filter: MeetingFilter) -> [Meeting] {
        var result = meetings.filter { meeting in
            let date = meeting.createdDate
            if let since = filter.since, date < since { return false }
            if let until = filter.until, date >= until { return false }
            if let status = filter.status, meeting.status != status { return false }
            if let speaker = filter.speaker, !speaker.isEmpty, !mentions(speaker, in: meeting) { return false }
            return true
        }
        result.sort { $0.createdAt > $1.createdAt }
        if let limit = filter.limit, limit >= 0, result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }

    static func mentions(_ speaker: String, in meeting: Meeting) -> Bool {
        let needle = speaker.lowercased()
        return meeting.speakers.contains { id, name in
            name.lowercased().contains(needle) || id.lowercased().contains(needle)
        }
    }

    /// Resolves a meeting reference: a full id, a unique id prefix, or `latest`.
    public static func resolve(_ reference: String, in meetings: [Meeting]) throws -> Meeting {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError.usage("Name a meeting, or use 'latest'.") }
        if trimmed.lowercased() == "latest" {
            guard let latest = meetings.max(by: { $0.createdAt < $1.createdAt }) else {
                throw CLIError.notFound("There are no meetings yet.")
            }
            return latest
        }
        if let exact = meetings.first(where: { $0.id == trimmed }) { return exact }
        let prefixed = meetings.filter { $0.id.hasPrefix(trimmed.lowercased()) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            let ids = prefixed.prefix(5).map(\.id).joined(separator: ", ")
            throw CLIError.ambiguous("'\(trimmed)' matches \(prefixed.count) meetings: \(ids)")
        }
        // A person is far more likely to paste a title than an id they never see.
        let titled = meetings.filter { $0.title.lowercased() == trimmed.lowercased() }
        if titled.count == 1 { return titled[0] }
        if titled.count > 1 {
            throw CLIError.ambiguous("\(titled.count) meetings are called '\(trimmed)'. Use a meeting id.")
        }
        throw CLIError.notFound("No meeting matches '\(trimmed)'.")
    }

    public static func fields(_ raw: String?) throws -> Set<SearchField> {
        guard let raw, !raw.isEmpty else { return Set(SearchField.allCases) }
        var fields: Set<SearchField> = []
        for name in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let field = SearchField(rawValue: name.lowercased()) else {
                let known = SearchField.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("Unknown search field '\(name)'. Use any of: \(known).")
            }
            fields.insert(field)
        }
        guard !fields.isEmpty else { throw CLIError.usage("--in needs at least one field.") }
        return fields
    }

    public static func search(
        _ meetings: [Meeting], query: String, fields: Set<SearchField> = Set(SearchField.allCases),
        filter: MeetingFilter = MeetingFilter(), context: Int = 80
    ) throws -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { throw CLIError.usage("Give something to search for.") }
        // The limit applies to matching meetings, so filter by date and speaker first and cut
        // only after scoring.
        var unlimited = filter
        unlimited.limit = nil
        var results: [SearchResult] = []
        for meeting in Self.filter(meetings, unlimited) {
            var hits: [SearchHit] = []
            var matches = 0

            if fields.contains(.title) {
                let count = occurrences(of: needle, in: meeting.title)
                if count > 0 {
                    matches += count
                    hits.append(SearchHit(field: .title, snippet: meeting.title))
                }
            }
            if fields.contains(.transcript) {
                for segment in meeting.segments {
                    let count = occurrences(of: needle, in: segment.text)
                    guard count > 0 else { continue }
                    matches += count
                    hits.append(SearchHit(
                        field: .transcript,
                        snippet: snippet(segment.text, around: needle, context: context),
                        speaker: meeting.speakerName(segment.speaker),
                        start: segment.start
                    ))
                }
            }
            if fields.contains(.summary), let summary = meeting.summary {
                let passages = [summary.overview] + summary.keyPoints + summary.decisions
                    + summary.actionItems.map(\.text)
                for passage in passages {
                    let count = occurrences(of: needle, in: passage)
                    guard count > 0 else { continue }
                    matches += count
                    hits.append(SearchHit(
                        field: .summary, snippet: snippet(passage, around: needle, context: context)
                    ))
                }
            }
            if fields.contains(.notes) {
                let count = occurrences(of: needle, in: meeting.notes)
                if count > 0 {
                    matches += count
                    hits.append(SearchHit(
                        field: .notes, snippet: snippet(meeting.notes, around: needle, context: context)
                    ))
                }
            }

            guard matches > 0 else { continue }
            results.append(SearchResult(
                id: meeting.id, title: meeting.title, createdAt: meeting.createdAt,
                speakers: meeting.orderedSpeakerIDs().map { meeting.speakerName($0) },
                matches: matches, hits: hits
            ))
        }
        if let limit = filter.limit, limit >= 0, results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(
            of: needle, options: [.caseInsensitive], range: searchRange
        ) {
            count += 1
            guard found.upperBound < haystack.endIndex else { break }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// A window around the first match, so a long note or a long segment stays readable.
    static func snippet(_ text: String, around needle: String, context: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard context > 0, collapsed.count > context * 2 + needle.count,
              let found = collapsed.range(of: needle, options: [.caseInsensitive])
        else { return collapsed }
        let start = collapsed.index(found.lowerBound, offsetBy: -context, limitedBy: collapsed.startIndex)
            ?? collapsed.startIndex
        let end = collapsed.index(found.upperBound, offsetBy: context, limitedBy: collapsed.endIndex)
            ?? collapsed.endIndex
        let prefix = start == collapsed.startIndex ? "" : "…"
        let suffix = end == collapsed.endIndex ? "" : "…"
        return prefix + String(collapsed[start..<end]) + suffix
    }
}
