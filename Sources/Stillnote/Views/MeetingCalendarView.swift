import StillnoteCore
import SwiftUI

/// The calendar replaces the meeting list and detail; the sidebar stays. Choosing a meeting
/// opens it in All Meetings.
struct MeetingCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Binding var destination: SidebarDestination
    @Binding var selection: String?
    @Binding var sheet: RootSheet?

    // Kept per window so opening a meeting and coming back returns to the same page.
    @SceneStorage("calendarSpan") private var span: CalendarSpan = .week
    @SceneStorage("calendarDate") private var anchorTime: Double = Date.now.timeIntervalSinceReferenceDate

    private let layout = CalendarLayout()

    private var anchor: Date {
        get { Date(timeIntervalSinceReferenceDate: anchorTime) }
        nonmutating set { anchorTime = newValue.timeIntervalSinceReferenceDate }
    }

    private var meetings: [MeetingListItem] {
        model.meetings.filter { !feedback.pendingDeletes.contains($0.id) }
    }

    var body: some View {
        // Ticks each minute so today's highlight and the current-time line stay right.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .toastOverlay(feedback, top: 84)
    }

    private func content(now: Date) -> some View {
        let byDay = Dictionary(grouping: meetings) { layout.calendar.startOfDay(for: $0.startDate) }
        let days = layout.days(span, containing: anchor)
        let empty = span != .month && !days.contains { !(byDay[$0] ?? []).isEmpty }
        return VStack(spacing: 0) {
            toolbar(now: now)
            switch span {
            case .month:
                MonthGrid(layout: layout, month: anchor, today: now, meetingsByDay: byDay,
                          selection: selection, open: open, onDelete: delete) { day in
                    anchor = day
                    span = .day
                }
                .padding(.top, 6)
            case .week, .day:
                WeekGrid(layout: layout, days: days, now: now, meetingsByDay: byDay,
                         tags: MeetingTag.sorted(model.tags, by: .manual), selection: selection, open: open, onDelete: delete)
                    .padding(.top, 6)
            }
        }
        .overlay {
            if empty {
                Text(span == .day ? "No meetings this day" : "No meetings this week")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .designGlassCapsule()
                    .offset(x: 32)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            NewMeetingButton(selection: openingBinding, sheet: $sheet)
                .offset(x: 32)
                .padding(.bottom, 22)
        }
    }

    /// Starting a recording from the calendar shows it in All Meetings.
    private var openingBinding: Binding<String?> {
        Binding(get: { selection }, set: { id in
            if let id { open(id) } else { selection = nil }
        })
    }

    private func toolbar(now: Date) -> some View {
        HStack(spacing: 12) {
            Button { destination = .all } label: {
                Icon(.back, size: 18, lineWidth: 2.2)
                    .foregroundStyle(DS.text)
                    .frame(width: 36, height: 36)
                    .designGlass(Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Back to All Meetings")
            .accessibilityLabel("Back to All Meetings")
            title
                .padding(.leading, 4)
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                ForEach(CalendarSpan.allCases) { value in
                    let selected = span == value
                    Button { span = value } label: {
                        Text(value.rawValue.capitalized)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : DS.text2)
                            .padding(.horizontal, 16)
                            .frame(height: 30)
                            .background(selected ? DS.selection : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 36)
            .designGlassCapsule()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Calendar range")

            HStack(spacing: 2) {
                Button { anchor = layout.step(anchor, span, by: -1) } label: {
                    Icon(.previous, size: 16, lineWidth: 2.2)
                        .frame(width: 32, height: 30)
                        .hoverFill(Capsule())
                }
                .buttonStyle(.plain)
                .help("Previous \(span.rawValue)")
                .accessibilityLabel("Previous \(span.rawValue)")
                Hairline(vertical: true).frame(height: 16)
                let showingToday = layout.interval(span, containing: anchor).contains(now)
                Button { anchor = now } label: {
                    Text("Today")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .hoverFill(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("t", modifiers: .command)
                .help("Go to Today (⌘T)")
                .opacity(showingToday ? 0.5 : 1)
                Hairline(vertical: true).frame(height: 16)
                Button { anchor = layout.step(anchor, span, by: 1) } label: {
                    Icon(.next, size: 16, lineWidth: 2.2)
                        .frame(width: 32, height: 30)
                        .hoverFill(Capsule())
                }
                .buttonStyle(.plain)
                .help("Next \(span.rawValue)")
                .accessibilityLabel("Next \(span.rawValue)")
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 3)
            .frame(height: 36)
            .designGlassCapsule()
        }
        .padding(EdgeInsets(top: 28, leading: 16, bottom: 8, trailing: 24))
        .frame(height: 72)
    }

    private var title: some View {
        let year = Text(anchor, format: .dateTime.year()).fontWeight(.regular).foregroundColor(DS.text2)
        let lead: Text
        switch span {
        case .day:
            lead = Text(anchor, format: .dateTime.month(.wide).day())
        case .week:
            let days = layout.days(.week, containing: anchor)
            let first = days.first ?? anchor, last = days.last ?? anchor
            lead = layout.calendar.isDate(first, equalTo: last, toGranularity: .month)
                ? Text(last, format: .dateTime.month(.wide))
                : Text("\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated)))")
        case .month:
            lead = Text(anchor, format: .dateTime.month(.wide))
        }
        return Text("\(lead.fontWeight(.bold).foregroundColor(DS.text)) \(year)")
            .font(.system(size: 26))
            .letterSpacing(-0.025, size: 26)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private func open(_ id: String) {
        destination = .all
        selection = id
    }

    private func delete(_ meeting: MeetingListItem) {
        if selection == meeting.id { selection = nil }
        feedback.delete(meeting, model: model)
    }
}

/// Open, star, tag, and delete, as the meeting list offers.
private struct MeetingEventMenu: ViewModifier {
    let meeting: MeetingListItem
    let open: (String) -> Void
    let onDelete: (MeetingListItem) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open") { open(meeting.id) }
                Divider()
                MeetingOrganizeItems(meeting: meeting)
                Divider()
                Button("Delete", role: .destructive) { onDelete(meeting) }
                    .disabled(meeting.status.isBusy)
            }
    }
}

private extension MeetingListItem {
    var timeRange: String {
        let start = startDate
        return (start..<start.addingTimeInterval(max(duration, 0))).formatted(.interval.hour().minute())
    }
}

// MARK: - Day and week

private struct WeekGrid: View {
    let layout: CalendarLayout
    let days: [Date]
    let now: Date
    let meetingsByDay: [Date: [MeetingListItem]]
    /// In sidebar order, so a meeting takes its first tag's color.
    let tags: [MeetingTag]
    let selection: String?
    let open: (String) -> Void
    let onDelete: (MeetingListItem) -> Void

    static let hourHeight: CGFloat = 60
    static let gutter: CGFloat = 64
    static let topPadding: CGFloat = 12
    /// Short meetings are drawn at least this long, so their titles fit.
    static let minimumMinutes: Double = 26

    /// 7 AM to 9 PM, widened to include every meeting shown.
    private var hours: ClosedRange<Int> {
        let shown = days.flatMap { meetingsByDay[$0] ?? [] }
        var first = 7, last = 21
        for meeting in shown {
            let start = layout.clockOffset(meeting.startDate) / 60
            let end = start + max(meeting.duration / 60, Self.minimumMinutes)
            first = min(first, Int(start / 60))
            last = max(last, min(24, Int((end / 60).rounded(.up))))
        }
        return first...last
    }

    private func y(_ minutes: Double) -> CGFloat {
        CGFloat((minutes - Double(hours.lowerBound * 60)) / 60) * Self.hourHeight + Self.topPadding
    }

    var body: some View {
        let hours = self.hours
        let gridHeight = y(Double(hours.upperBound * 60)) + 96
        let today = days.first { layout.calendar.isDate($0, inSameDayAs: now) }
        let nowMinutes = layout.clockOffset(now) / 60
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Hour rules
                ForEach(Array(hours), id: \.self) { hour in
                    Hairline().offset(x: Self.gutter, y: y(Double(hour * 60)))
                        .padding(.trailing, Self.gutter)
                }
                HStack(spacing: 0) {
                    gutterLabels(hours: hours, nowMinutes: today == nil ? nil : nowMinutes)
                        .frame(width: Self.gutter, height: gridHeight, alignment: .topLeading)
                    ForEach(days, id: \.self) { day in
                        column(day, isToday: day == today, nowMinutes: nowMinutes)
                            .frame(maxWidth: .infinity)
                            .frame(height: gridHeight)
                    }
                }
            }
            .frame(height: gridHeight)
        }
        .scrollIndicators(.automatic)
        .safeAreaInset(edge: .top, spacing: 0) { header(today: today) }
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func header(today: Date?) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = day == today
                HStack(spacing: 6) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(isToday ? DS.text : DS.text2)
                    Text(day, format: .dateTime.day())
                        .fontWeight(isToday ? .bold : .semibold)
                        .foregroundStyle(isToday ? Color.white : DS.text)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(isToday ? DS.record : .clear, in: .capsule)
                }
                .font(.system(size: 15))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(height: 48)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                DS.edge
            }
        }
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func gutterLabels(hours: ClosedRange<Int>, nowMinutes: Double?) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(hours), id: \.self) { hour in
                // An hour label the "now" label would sit on is hidden.
                if nowMinutes.map({ abs(Double(hour * 60) - $0) >= 14 }) ?? true {
                    Text(Self.hourLabel(hour, layout: layout))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(DS.text3)
                        .fixedSize()
                        .frame(height: 14)
                        .offset(y: y(Double(hour * 60)) - 7)
                }
            }
            if let nowMinutes, Double(hours.lowerBound * 60) <= nowMinutes, nowMinutes <= Double(hours.upperBound * 60) {
                Text(Self.clock(nowMinutes))
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(DS.record)
                    .fixedSize()
                    .frame(height: 16)
                    .offset(x: 2, y: y(nowMinutes) - 8)
            }
        }
        .padding(.trailing, 10)
        .frame(width: Self.gutter, alignment: .topTrailing)
        .accessibilityHidden(true)
    }

    /// "1:40": the time without AM or PM, as the design's now label shows it.
    static func clock(_ minutes: Double) -> String {
        let whole = Int(minutes), hour = whole / 60 % 12
        return String(format: "%d:%02d", hour == 0 ? 12 : hour, whole % 60)
    }

    static func hourLabel(_ hour: Int, layout: CalendarLayout) -> String {
        // Label from a day without a clock change, so a skipped or repeated hour cannot
        // shift or duplicate the gutter.
        let reference = layout.calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour % 24)) ?? .now
        return hour == 24 ? "12 AM" : reference.formatted(.dateTime.hour())
    }

    private func column(_ day: Date, isToday: Bool, nowMinutes: Double) -> some View {
        let meetings = (meetingsByDay[day] ?? []).sorted { $0.startDate < $1.startDate }
        let spans = Dictionary(uniqueKeysWithValues: meetings.map { meeting -> (String, (Double, Double)) in
            let start = layout.clockOffset(meeting.startDate) / 60
            return (meeting.id, (start, start + max(meeting.duration / 60, Self.minimumMinutes)))
        })
        let placements = CalendarLayout.placements(meetings.map { ($0.id, spans[$0.id]!.0 * 60, spans[$0.id]!.1 * 60) })
        let weekend = layout.calendar.isDateInWeekend(day) && days.count > 1
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(meetings) { meeting in
                    let span = spans[meeting.id]!
                    let placement = placements[meeting.id] ?? .init(column: 0, columns: 1)
                    let slice = proxy.size.width / CGFloat(placement.columns)
                    let height = CGFloat(span.1 - span.0) / 60 * Self.hourHeight - 2
                    EventBlock(
                        meeting: meeting, tone: EventTone(tags.first { meeting.tagIDs.contains($0.id) }?.color),
                        selected: meeting.id == selection, tall: height >= 40, open: open
                    )
                    .modifier(MeetingEventMenu(meeting: meeting, open: open, onDelete: onDelete))
                    .frame(width: max(0, slice - 5), height: height)
                    .offset(x: slice * CGFloat(placement.column) + 2, y: y(span.0))
                }
                if isToday {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(DS.record).frame(height: 1.5)
                        Circle().fill(DS.record).frame(width: 8, height: 8).offset(x: -4.5)
                    }
                    .offset(y: y(nowMinutes) - 0.75)
                    .allowsHitTesting(false)
                    .zIndex(3)
                }
            }
        }
        .background(weekend ? DS.weekend : .clear)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
    }
}

private struct EventBlock: View {
    let meeting: MeetingListItem
    let tone: EventTone
    let selected: Bool
    let tall: Bool
    let open: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button { open(meeting.id) } label: {
            Group {
                if tall {
                    VStack(alignment: .leading, spacing: 1) {
                        title
                        detail(MeetingText.time(meeting.startDate) + " · " + length)
                    }
                    .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    HStack(spacing: 6) {
                        title.layoutPriority(0)
                        detail(length).layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .background(selected ? tone.solid : tone.tint)
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? Color.white.opacity(0.55) : tone.solid).frame(width: 3)
            }
            .brightness(hovering ? 0.06 : 0)
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(meeting.title)\n\(meeting.timeRange) · \(Formatting.calendarDuration(meeting.duration))")
        .accessibilityLabel("\(meeting.title), \(meeting.startDate.formatted(date: .complete, time: .shortened)), \(Formatting.calendarDuration(meeting.duration)). Open meeting")
        .zIndex(2)
    }

    private var length: String {
        switch meeting.status {
        case .transcribing: "Transcribing"
        case .summarizing: "Summarizing"
        default: Formatting.calendarDuration(meeting.duration)
        }
    }

    private var title: some View {
        Text(meeting.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? Color.white : DS.text)
            .lineLimit(1)
            .frame(height: 15)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(selected ? Color.white.opacity(0.86) : tone.ink)
            .lineLimit(1)
            .fixedSize()
            .frame(height: 15)
    }
}

// MARK: - Month

private struct MonthGrid: View {
    @Environment(AppModel.self) private var model
    let layout: CalendarLayout
    let month: Date
    let today: Date
    let meetingsByDay: [Date: [MeetingListItem]]
    let selection: String?
    let open: (String) -> Void
    let onDelete: (MeetingListItem) -> Void
    let showDay: (Date) -> Void

    var body: some View {
        let rows = layout.monthGrid(containing: month)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(layout.orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.text2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 10)
                }
            }
            .frame(height: 36)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
            ForEach(rows, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        MonthDayCell(
                            day: day,
                            inMonth: layout.calendar.isDate(day, equalTo: month, toGranularity: .month),
                            isToday: layout.calendar.isDate(day, inSameDayAs: today),
                            meetings: (meetingsByDay[day] ?? []).sorted { $0.startDate < $1.startDate },
                            tags: MeetingTag.sorted(model.tags, by: .manual), selection: selection,
                            open: open, onDelete: onDelete, showDay: showDay
                        )
                        .overlay(alignment: .leading) { if day != week.first { Hairline(vertical: true) } }
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Hairline() }
            }
        }
        .padding(.bottom, 80)
    }
}

private struct MonthDayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let meetings: [MeetingListItem]
    /// In sidebar order, so a meeting takes its first tag's color.
    let tags: [MeetingTag]
    let selection: String?
    let open: (String) -> Void
    let onDelete: (MeetingListItem) -> Void
    let showDay: (Date) -> Void

    private static let chipHeight: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let fits = max(0, Int((proxy.size.height - 36) / (Self.chipHeight + 2)))
            let shown = meetings.count > fits ? max(0, fits - 1) : meetings.count
            VStack(alignment: .leading, spacing: 2) {
                Text(day, format: .dateTime.day())
                    .font(.system(size: 14, weight: isToday ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : inMonth ? DS.text : DS.text3)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(isToday ? DS.record : .clear, in: .capsule)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 2)
                ForEach(meetings.prefix(shown)) { meeting in
                    let tone = EventTone(tags.first { meeting.tagIDs.contains($0.id) }?.color)
                    let selected = meeting.id == selection
                    Button { open(meeting.id) } label: {
                        Text(meeting.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : DS.text)
                            .lineLimit(1)
                            .padding(.leading, 8)
                            .padding(.trailing, 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .background(selected ? tone.solid : tone.tint)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(selected ? Color.white.opacity(0.55) : tone.solid).frame(width: 3)
                            }
                            .clipShape(.rect(cornerRadius: 5))
                            .contentShape(.rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .frame(height: Self.chipHeight)
                    .modifier(MeetingEventMenu(meeting: meeting, open: open, onDelete: onDelete))
                }
                if shown < meetings.count {
                    Button("\(meetings.count - shown) more") { showDay(day) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DS.text2)
                        .padding(.leading, 8)
                        .frame(height: Self.chipHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(inMonth ? Color.clear : DS.weekend)
        .contentShape(.rect)
        .onTapGesture(count: 2) { showDay(day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}
