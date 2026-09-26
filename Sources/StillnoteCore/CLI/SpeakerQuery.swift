import Foundation

/// Resolves a `<profile>` argument to one saved speaker profile.
public enum SpeakerQuery {
    /// Accepts a full id, a unique id prefix, an exact name, or an exact email, all ignoring case.
    /// An ambiguous reference is an error listing the candidates rather than a guess.
    public static func resolve(_ reference: String, in profiles: [SpeakerProfile]) throws -> SpeakerProfile {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError.usage("Name a speaker profile. 'stillnote speaker list' lists them.") }
        let needle = trimmed.lowercased()
        if let exact = profiles.first(where: { $0.id.lowercased() == needle }) { return exact }
        let named = profiles.filter { $0.name.lowercased() == needle }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let ids = named.prefix(5).map(\.id).joined(separator: ", ")
            throw CLIError.ambiguous("\(named.count) speaker profiles are called '\(trimmed)': \(ids). Use an id.")
        }
        let mailed = profiles.filter { !$0.email.isEmpty && $0.email.lowercased() == needle }
        if mailed.count == 1 { return mailed[0] }
        let prefixed = profiles.filter { $0.id.lowercased().hasPrefix(needle) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            let ids = prefixed.prefix(5).map(\.id).joined(separator: ", ")
            throw CLIError.ambiguous("'\(trimmed)' matches \(prefixed.count) speaker profiles: \(ids)")
        }
        throw CLIError.notFound("No speaker profile matches '\(trimmed)'. 'stillnote speaker list' lists them.")
    }

    /// Every place a profile is linked, newest meeting first.
    public static func appearances(of profileID: String, in meetings: [Meeting]) -> [SpeakerAppearance] {
        meetings.sorted { $0.createdAt > $1.createdAt }.flatMap { meeting in
            meeting.speakerProfiles.filter { $0.value == profileID }.keys.sorted().map {
                SpeakerAppearance(id: meeting.id, title: meeting.title, createdAt: meeting.createdAt, speaker: $0)
            }
        }
    }
}
