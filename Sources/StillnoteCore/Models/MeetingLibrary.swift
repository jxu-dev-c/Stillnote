import Foundation

public enum MeetingLibrary {
    public static let recentLimit = 50

    /// Apply a current metadata snapshot without sorting the library on ordinary updates.
    /// Revisions prevent a delayed detail/refresh read from overwriting a newer CLI edit.
    @discardableResult
    public static func apply(_ item: MeetingListItem, to meetings: inout [MeetingListItem]) -> Bool {
        if let index = meetings.firstIndex(where: { $0.id == item.id }) {
            let previous = meetings[index]
            guard item.revision >= previous.revision else { return false }
            if previous.createdAt == item.createdAt {
                if previous != item { meetings[index] = item }
                return true
            }
            meetings.remove(at: index)
        }
        let index = meetings.firstIndex { $0.createdAt < item.createdAt } ?? meetings.endIndex
        meetings.insert(item, at: index)
        return true
    }

    public static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
    }

    public static func searchText(_ meeting: Meeting) -> String {
        ([meeting.title] + meeting.segments.map(\.text)).joined(separator: " ").lowercased().precomposedStringWithCanonicalMapping
    }
}
