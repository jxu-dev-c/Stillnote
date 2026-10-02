import StillnoteCore
import SwiftUI

/// All Meetings laid out like Calendar.app: a month grid, or a day or week timeline where
/// each meeting is placed at its start time and sized by its length.
struct MeetingCalendarView: View {
    let meetings: [Meeting]
    @Binding var selection: String?
    var onDelete: (String) -> Void

    // Kept per window so opening a meeting and coming back returns to the same page.
    @SceneStorage("calendarSpan") private var span: CalendarSpan = .month
    @SceneStorage("calendarDate") private var anchorTime: Double = Date.now.timeIntervalSinceReferenceDate

    private let layout = CalendarLayout()

    private var anchor: Date {
        get { Date(timeIntervalSinceReferenceDate: anchorTime) }
        nonmutating set { anchorTime = newValue.timeIntervalSinceReferenceDate }
    }

    private var meetingsByDay: [Date: [Meeting]] {
        // `startDate` parses a timestamp, so read it once per meeting.
        let dated = meetings.map { ($0.startDate, $0) }.sorted { $0.0 < $1.0 }
        return Dictionary(grouping: dated) { layout.calendar.startOfDay(for: $0.0) }
            .mapValues { $0.map(\.1) }
    }

    var body: some View {
        // Ticks each minute so today's highlight and the current-time line stay right.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let byDay = meetingsByDay
        return VStack(spacing: 0) {
            header(now: now)
            Divider()
            switch span {
            case .month:
                MonthGrid(
                    layout: layout, month: anchor, today: now, meetingsByDay: byDay,
                    open: open, onDelete: onDelete,
                    showDay: { day in
                        anchor = day
                        span = .day
                    }
                )
            case .week, .day:
                TimelineGrid(
                    layout: layout, days: layout.days(span, containing: anchor), now: now,
                    meetingsByDay: byDay, open: open, onDelete: onDelete
                )
            }
        }
        .background(.background)
    }

    private func open(_ id: String) { selection = id }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if span == .day {
                    Text(anchor, format: .dateTime.weekday(.wide))
                        .font(StillnoteTheme.detailSupportingFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Picker("Calendar range", selection: $span) {
                ForEach(CalendarSpan.allCases) { span in
                    Text(span.rawValue.capitalized).tag(span)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ControlGroup {
                Button { move(by: -1) } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .help("Previous \(span.rawValue)")
                Button("Today") { anchor = now }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("Go to Today (⌘T)")
                Button { move(by: 1) } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .help("Next \(span.rawValue)")
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: some View {
        let year = Text(anchor, format: .dateTime.year())
        let lead: Text
        switch span {
        case .day:
            lead = Text(anchor, format: .dateTime.month(.wide).day())
        case .week:
            let days = layout.days(.week, containing: anchor)
            let first = days.first ?? anchor, last = days.last ?? anchor
            lead = layout.calendar.isDate(first, equalTo: last, toGranularity: .month)
                ? Text(anchor, format: .dateTime.month(.wide))
                : Text("\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated)))")
        case .month:
            lead = Text(anchor, format: .dateTime.month(.wide))
        }
        // Calendar.app writes a day as "September 28, 2026" and a month as "October 2026".
        let title = span == .day ? Text("\(lead.fontWeight(.bold)), \(year)") : Text("\(lead.fontWeight(.bold)) \(year)")
        return title
            .font(.system(size: 28))
            .accessibilityAddTraits(.isHeader)
    }

    private func move(by value: Int) {
        anchor = layout.step(anchor, span, by: value)
    }
}

/// The color a meeting is drawn in. Busy and failed meetings stand out from the rest.
private extension Meeting {
    var calendarTint: Color {
        switch status {
        case .error: return .orange
        case .transcribing, .summarizing: return .gray
        default: return .accentColor
        }
    }

    var timeRange: String {
        let start = startDate
        return (start..<start.addingTimeInterval(max(duration, 0))).formatted(.interval.hour().minute())
    }
}

/// Open and delete actions shared by both event styles, matching the table's context menu.
private struct MeetingEventMenu: ViewModifier {
    let meeting: Meeting
    let open: (String) -> Void
    let onDelete: (String) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open") { open(meeting.id) }
                Button("Delete…", role: .destructive) { onDelete(meeting.id) }
                    .disabled(meeting.status.isBusy)
            }
            .help("\(meeting.title)\n\(meeting.timeRange)")
            .accessibilityLabel("\(meeting.title), \(meeting.timeRange), \(meeting.status.label)")
    }
}

// MARK: - Month

private struct MonthGrid: View {
    let layout: CalendarLayout
    let month: Date
    let today: Date
    let meetingsByDay: [Date: [Meeting]]
    let open: (String) -> Void
    let onDelete: (String) -> Void
    let showDay: (Date) -> Void

    var body: some View {
        let rows = layout.monthGrid(containing: month)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(layout.orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            ForEach(rows, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        MonthDayCell(
                            day: day,
                            inMonth: layout.calendar.isDate(day, equalTo: month, toGranularity: .month),
                            isToday: layout.calendar.isDate(day, inSameDayAs: today),
                            meetings: meetingsByDay[day] ?? [],
                            open: open, onDelete: onDelete, showDay: showDay
                        )
                        if day != week.last { Divider() }
                    }
                }
                .frame(maxHeight: .infinity)
                if week != rows.last { Divider() }
            }
        }
    }
}

private struct MonthDayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let meetings: [Meeting]
    let open: (String) -> Void
    let onDelete: (String) -> Void
    let showDay: (Date) -> Void

    private static let chipHeight: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let fits = max(0, Int((proxy.size.height - 34) / Self.chipHeight))
            let shown = meetings.count > fits ? max(0, fits - 1) : meetings.count
            VStack(alignment: .leading, spacing: 0) {
                dayNumber
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 2)
                ForEach(meetings.prefix(shown)) { meeting in
                    MonthEventChip(meeting: meeting, open: open)
                        .frame(height: Self.chipHeight)
                        .modifier(MeetingEventMenu(meeting: meeting, open: open, onDelete: onDelete))
                }
                if shown < meetings.count {
                    Button("\(meetings.count - shown) more") { showDay(day) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                        .frame(height: Self.chipHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(inMonth ? Color.clear : Color.primary.opacity(0.035))
        .contentShape(.rect)
        .onTapGesture(count: 2) { showDay(day) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private var dayNumber: some View {
        Text(day, format: .dateTime.day())
            .font(.system(size: 14, weight: isToday ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(minWidth: 24, minHeight: 24)
            .background {
                if isToday { Circle().fill(.red) }
            }
    }
}

private struct MonthEventChip: View {
    let meeting: Meeting
    let open: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button { open(meeting.id) } label: {
            HStack(spacing: 5) {
                if meeting.status.isBusy {
                    ProgressView().controlSize(.mini).frame(width: 7, height: 7)
                } else {
                    Circle().fill(meeting.calendarTint).frame(width: 7, height: 7)
                }
                // Like Calendar.app, a narrow cell gives the title the room and drops the time.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text(meeting.title).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        Text(meeting.startDate, format: .dateTime.hour().minute())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    Text(meeting.title).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .background(hovering ? meeting.calendarTint.opacity(0.15) : .clear, in: .rect(cornerRadius: 4))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Day and week

private struct TimelineGrid: View {
    let layout: CalendarLayout
    let days: [Date]
    let now: Date
    let meetingsByDay: [Date: [Meeting]]
    let open: (String) -> Void
    let onDelete: (String) -> Void

    static let hourHeight: CGFloat = 48
    static let gutterWidth: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            columnHeaders
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(days, id: \.self) { day in
                            Divider()
                            dayColumn(day)
                        }
                    }
                    .frame(height: Self.hourHeight * 24)
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToFirstMeeting(proxy) }
                .onChange(of: days) { scrollToFirstMeeting(proxy) }
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = layout.calendar.isDate(day, inSameDayAs: now)
                HStack(spacing: 6) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .foregroundStyle(isToday ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Text(day, format: .dateTime.day())
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(isToday ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .frame(minWidth: 26, minHeight: 26)
                        .background {
                            if isToday { Circle().fill(.red) }
                        }
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: days.count == 1 ? .leading : .center)
                .padding(.horizontal, days.count == 1 ? 12 : 0)
                .padding(.vertical, 8)
            }
        }
    }

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(hour == 0 ? 0 : 1)
                    .offset(y: -7)
                    .frame(width: Self.gutterWidth - 8, height: Self.hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .id(hour)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        // Label from a day without a clock change, so a skipped or repeated hour cannot
        // shift or duplicate the gutter.
        let reference = layout.calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? now
        return reference.formatted(.dateTime.hour())
    }

    private func dayColumn(_ day: Date) -> some View {
        let meetings = meetingsByDay[day] ?? []
        let spans = Dictionary(uniqueKeysWithValues: meetings.map {
            ($0.id, layout.clockSpan(start: $0.startDate, duration: $0.duration))
        })
        let placements = CalendarLayout.placements(meetings.map { ($0.id, spans[$0.id]!.start, spans[$0.id]!.end) })
        let isToday = layout.calendar.isDate(day, inSameDayAs: now)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                hourLines(width: proxy.size.width)
                ForEach(meetings) { meeting in
                    let placement = placements[meeting.id] ?? .init(column: 0, columns: 1)
                    let frame = eventFrame(spans[meeting.id]!, placement: placement, width: proxy.size.width)
                    TimelineEventBlock(meeting: meeting, compact: frame.height < 36, open: open)
                        .modifier(MeetingEventMenu(meeting: meeting, open: open, onDelete: onDelete))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if isToday {
                    currentTimeLine(width: proxy.size.width)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(isToday && days.count > 1 ? Color.red.opacity(0.03) : .clear)
    }

    private func hourLines(width: CGFloat) -> some View {
        Canvas { context, size in
            for hour in 0...24 {
                let y = CGFloat(hour) * Self.hourHeight
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1)
            }
        }
        .frame(width: width, height: Self.hourHeight * 24)
        .allowsHitTesting(false)
    }

    private func y(for date: Date) -> CGFloat {
        CGFloat(layout.clockOffset(date) / 3600) * Self.hourHeight
    }

    private func eventFrame(
        _ span: (start: TimeInterval, end: TimeInterval), placement: CalendarLayout.Placement, width: CGFloat
    ) -> CGRect {
        let top = CGFloat(span.start / 3600) * Self.hourHeight
        let height = CGFloat((span.end - span.start) / 3600) * Self.hourHeight - 2
        let slice = (width - 6) / CGFloat(placement.columns)
        return CGRect(x: 2 + slice * CGFloat(placement.column), y: top + 1, width: slice - 2, height: max(height, 12))
    }

    private func currentTimeLine(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .frame(width: width + 4)
        .offset(x: -4, y: y(for: now) - 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scrollToFirstMeeting(_ proxy: ScrollViewProxy) {
        // The earliest time of day across the visible days, not the earliest date: a Monday
        // 9:00 meeting needs the view higher than a Sunday 16:00 one.
        let first = days.flatMap { meetingsByDay[$0] ?? [] }.map { layout.clockOffset($0.startDate) }.min()
        let hour = first.map { max(0, Int($0 / 3600) - 1) } ?? 8
        proxy.scrollTo(min(hour, 16), anchor: .top)
    }
}

private struct TimelineEventBlock: View {
    let meeting: Meeting
    let compact: Bool
    let open: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let tint = meeting.calendarTint
        Button { open(meeting.id) } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if meeting.status.isBusy { ProgressView().controlSize(.mini) }
                        if compact {
                            // A short block has one line; the start time goes first when space is tight.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 4) {
                                    title.lineLimit(1).fixedSize()
                                    Text(meeting.startDate, format: .dateTime.hour().minute())
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                                title.lineLimit(1)
                            }
                        } else {
                            title.lineLimit(2)
                        }
                    }
                    if !compact {
                        Text(meeting.timeRange)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, compact ? 1 : 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint.opacity(hovering ? 0.28 : 0.18))
            .clipShape(.rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var title: Text {
        Text(meeting.title).font(.system(size: 12, weight: .semibold))
    }
}
