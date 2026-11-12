import StillnoteCore
import SwiftUI

/// How a meeting's speaker is drawn: a tinted initial for a known person, or a dashed
/// numbered portrait for a voice nobody has identified yet.
struct SpeakerLook: Equatable {
    let name: String
    let initial: String
    let accent: DS.Accent?

    var unknown: Bool { accent == nil }
    var fill: Color { accent?.tint ?? DS.field }
    var ink: Color { accent?.ink ?? DS.text2 }
}

extension Meeting {
    /// Speaker labels in transcription order (speaker_2 before speaker_10), voices with lines only.
    var speakerOrder: [String] {
        let used = Set(segments.map(\.speaker))
        return speakers.keys.filter { used.contains($0) || segments.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The voice's number: the one transcription named it with, or its place in the order.
    func voiceNumber(_ speakerID: String) -> Int {
        if let match = speakerName(speakerID).wholeMatch(of: #/Speaker (\d+)/#), let number = Int(match.1) {
            return number
        }
        return (speakerOrder.firstIndex(of: speakerID) ?? 0) + 1
    }

    func look(_ speakerID: String) -> SpeakerLook {
        let name = speakerName(speakerID)
        if let profile = speakerProfiles[speakerID] {
            return SpeakerLook(name: name, initial: Self.initial(name), accent: .stable(profile))
        }
        if Self.isPlaceholderName(name, label: speakerID) {
            // Keep the number transcription gave the voice; number raw labels by their order.
            if let match = name.wholeMatch(of: #/Speaker (\d+)/#) {
                return SpeakerLook(name: name, initial: String(match.1), accent: nil)
            }
            let number = (speakerOrder.firstIndex(of: speakerID) ?? 0) + 1
            return SpeakerLook(name: "Speaker \(number)", initial: name == "Unknown speaker" ? "?" : "\(number)", accent: nil)
        }
        return SpeakerLook(name: name, initial: Self.initial(name), accent: .stable(name))
    }

    /// The names transcription gives voices before anyone is identified.
    static func isPlaceholderName(_ name: String, label: String) -> Bool {
        name == label || name == "Unknown speaker"
            || name.wholeMatch(of: #/Speaker \d+/#) != nil || name.wholeMatch(of: #/SPEAKER_\d+/#) != nil
    }

    static func initial(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// The colors a meeting is drawn in on the calendar, from its category.
struct EventTone {
    let solid: Color
    let tint: Color
    let ink: Color

    init(_ color: CategoryColor?) {
        switch color {
        case .purple: self.init(.purple)
        case .orange: self.init(.orange)
        case .green: self.init(.green)
        case .blue, nil: self.init(.blue)
        case let other?:
            self.init(solid: other.color, tint: other.color.opacity(0.2), ink: other.color)
        }
    }

    init(_ accent: DS.Accent) {
        self.init(solid: accent.color, tint: accent.tint, ink: accent.ink)
    }

    init(solid: Color, tint: Color, ink: Color) {
        self.solid = solid
        self.tint = tint
        self.ink = ink
    }
}

/// Text for the meeting list and the detail header.
enum MeetingText {
    /// "41 min", "1 hr 5 min", or "30 sec".
    static func length(_ seconds: Double) -> String {
        Formatting.calendarDuration(seconds)
    }

    static func people(_ count: Int) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "person" : "people")" : nil
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "Today", "Yesterday", "Tuesday, Nov 10", or "Tuesday, Nov 10, 2025".
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    /// The list's second line: when, how long, and who, or what is happening to it now.
    static func listMeta(_ meeting: MeetingListItem, group: ListGroup) -> String {
        let date = meeting.startDate
        let when: String
        switch group {
        case .today, .yesterday: when = time(date)
        case .previous7: when = date.formatted(.dateTime.weekday(.wide))
        default:
            when = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
                ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        var parts = [when]
        if meeting.duration > 0 { parts.append(length(meeting.duration)) }
        switch meeting.status {
        case .transcribing: parts.append("Transcribing")
        case .summarizing: parts.append("Summarizing")
        case .error: parts.append("Needs attention")
        default: if let people = people(meeting.speakerCount) { parts.append(people) }
        }
        return parts.joined(separator: " · ")
    }

    static func listSnippet(_ meeting: MeetingListItem) -> String {
        switch meeting.status {
        case .transcribing: return "Transcribing audio…"
        case .summarizing: return "Writing summary…"
        default: break
        }
        if !meeting.snippet.isEmpty { return meeting.snippet }
        switch meeting.status {
        case .ready: return "Not transcribed yet"
        case .error: return "Something went wrong. Open the meeting for details."
        default: return "No speech detected"
        }
    }
}

/// Mail-style date sections for the meeting list.
enum ListGroup: Hashable {
    case today, yesterday, previous7, previous30
    case month(Int, Int)
    case year(Int)

    init(_ date: Date, now: Date = .now) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        if calendar.isDateInToday(date) || date > now { self = .today; return }
        if calendar.isDateInYesterday(date) { self = .yesterday; return }
        if let week = calendar.date(byAdding: .day, value: -7, to: start), date >= week { self = .previous7; return }
        if let month = calendar.date(byAdding: .day, value: -30, to: start), date >= month { self = .previous30; return }
        let year = calendar.component(.year, from: date)
        if year == calendar.component(.year, from: now) {
            self = .month(year, calendar.component(.month, from: date))
        } else {
            self = .year(year)
        }
    }

    var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7: "Previous 7 Days"
        case .previous30: "Previous 30 Days"
        case .month(_, let month): Calendar.current.standaloneMonthSymbols[month - 1]
        case .year(let year): String(year)
        }
    }
}
