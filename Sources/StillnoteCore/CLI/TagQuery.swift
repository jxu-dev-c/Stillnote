import Foundation

/// Resolves a `<tag>` argument to one tag, and finds the meetings carrying it.
public enum TagQuery {
    /// Accepts a full id, an exact name, or a unique id prefix, all ignoring case. An ambiguous
    /// reference is an error listing the candidates rather than a guess.
    public static func resolve(_ reference: String, in tags: [MeetingTag]) throws -> MeetingTag {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError.usage("Name a tag. 'stillnote tag list' lists them.") }
        let needle = trimmed.lowercased()
        if let exact = tags.first(where: { $0.id.lowercased() == needle }) { return exact }
        let named = tags.filter { $0.name.lowercased() == needle }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let ids = named.prefix(5).map(\.id).joined(separator: ", ")
            throw CLIError.ambiguous("\(named.count) tags are called '\(trimmed)': \(ids). Use an id.")
        }
        let prefixed = tags.filter { $0.id.lowercased().hasPrefix(needle) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            let ids = prefixed.prefix(5).map(\.id).joined(separator: ", ")
            throw CLIError.ambiguous("'\(trimmed)' matches \(prefixed.count) tags: \(ids)")
        }
        throw CLIError.notFound("No tag matches '\(trimmed)'. 'stillnote tag list' lists them.")
    }

    /// Meetings carrying `tagID`, newest first.
    public static func meetings(tagged tagID: String, in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { $0.tagIDs.contains(tagID) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// `TagColor` by name, for `tag create --color`.
    public static func color(_ raw: String) throws -> TagColor {
        guard let color = TagColor(rawValue: raw.lowercased()) else {
            throw CLIError.usage("Unknown color '\(raw)'. Use one of: \(TagColor.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return color
    }
}
