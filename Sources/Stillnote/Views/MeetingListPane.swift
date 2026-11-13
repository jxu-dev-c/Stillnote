import AppKit
import StillnoteCore
import SwiftUI

/// The selection that stands for the recording in progress, which has no meeting yet.
enum RecordingSelection {
    static let id = "stillnote.recording-in-progress"
}

/// The meeting list column: date-grouped meetings with Mail-style swipe actions and the
/// floating New Meeting button.
struct MeetingListPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    let destination: SidebarDestination
    @Binding var selection: String?
    @Binding var sheet: RootSheet?
    /// False while the sidebar is folded, when the window's own controls take the title's place.
    var showsTitle = true

    @State private var filtering = false
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var search = LibrarySearch()
    @State private var swipe = SwipeState()
    @State private var exporting: ExportDocument?
    @State private var exportName = ""

    static let width: CGFloat = 300

    private var title: String {
        switch destination {
        case .all, .calendar: "All Meetings"
        case .recentlyDeleted: "Recently Deleted"
        case .today: "Today"
        case .starred: "Starred"
        case .category(let id): model.category(id)?.name ?? "All Meetings"
        }
    }

    private var visible: [MeetingListItem] {
        let query = MeetingLibrary.normalizedQuery(self.query)
        return model.meetings.filter {
            !feedback.pendingDeletes.contains($0.id) && destination.includes($0)
                && (query.isEmpty || search.matches.contains($0.id))
        }
    }

    private var groups: [(group: ListGroup, rows: [MeetingListItem])] {
        let now = Date.now
        var result: [(group: ListGroup, rows: [MeetingListItem])] = []
        for meeting in visible.sorted(by: { $0.startDate > $1.startDate }) {
            let group = ListGroup(meeting.startDate, now: now)
            if result.last?.group == group {
                result[result.count - 1].rows.append(meeting)
            } else {
                result.append((group, [meeting]))
            }
        }
        return result
    }

    /// The recording in progress leads the list wherever today's meetings are shown.
    private var showsRecording: Bool {
        guard model.isRecording, query.isEmpty else { return false }
        switch destination {
        case .all, .today, .calendar: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if filtering { filterField }
            content
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            NewMeetingButton(selection: $selection, sheet: $sheet)
                .padding(.bottom, 22)
        }
        .background(SwipeScrollMonitor(swipe: swipe, canDelete: canDelete, settle: settle))
        .task(id: LibrarySearch.Request(query: MeetingLibrary.normalizedQuery(query), revision: model.meetingSearchRevision)) {
            await search.run(MeetingLibrary.normalizedQuery(query), revision: model.meetingSearchRevision, model: model)
        }
        .onChange(of: destination) { _, _ in swipe.close(animated: false) }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting,
            contentType: exporting?.format == .json ? .json : .plainText,
            defaultFilename: exportName
        ) { _ in exporting = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            if showsTitle {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .letterSpacing(-0.02, size: 20)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    filtering.toggle()
                    if !filtering { query = "" }
                }
                queryFocused = filtering
            } label: {
                Icon(.search, size: 20)
                    .foregroundStyle(filtering || !query.isEmpty ? DS.accentInk : DS.text2)
                    .frame(width: 32, height: 32)
                    .hoverFill(Circle(), active: filtering)
            }
            .buttonStyle(.plain)
            .help("Search meetings")
            .accessibilityLabel("Search meetings")
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Icon(.search, size: 16, lineWidth: 1.9)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DS.text)
                .focused($queryFocused)
                .onExitCommand {
                    query = ""
                    withAnimation(.snappy(duration: 0.2)) { filtering = false }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Icon(.close, size: 10, lineWidth: 3.4)
                        .foregroundStyle(DS.menuSolid)
                        .frame(width: 20, height: 20)
                        .background(DS.text3, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(DS.text2)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(DS.field, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if model.meetings.isEmpty && !model.isRecording {
            ListMessage(
                title: "No meetings yet",
                detail: "Record a meeting or import a recording to get started.",
                action: StatusAction("Import Audio…") { sheet = .importAudio }
            )
        } else if !query.isEmpty && search.pending {
            ListMessage(title: "Searching…", detail: nil)
        } else if let error = search.error, !query.isEmpty {
            ListMessage(title: "Could not search meetings", detail: error)
        } else if groups.isEmpty && !showsRecording {
            ListMessage(title: emptyTitle, detail: emptyDetail)
        } else {
            rows
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No results for “\(query)”" }
        switch destination {
        case .today: return "No meetings today"
        case .starred: return "No starred meetings"
        default: return "No meetings in \(title)"
        }
    }

    private var emptyDetail: String {
        if !query.isEmpty { return "Check the spelling or try a different search." }
        switch destination {
        case .today: return "Meetings recorded today appear here."
        case .starred: return "Swipe right on a meeting to star it."
        default: return "Add a meeting to this category from its context menu."
        }
    }

    private var rows: some View {
        let groups = self.groups
        let todayFirst = groups.first?.group == .today
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showsRecording && !todayFirst {
                    GroupLabel(label: "Today", first: true)
                    RecordingListRow(selected: selection == RecordingSelection.id) { selection = RecordingSelection.id }
                }
                ForEach(Array(groups.enumerated()), id: \.element.group) { index, entry in
                    GroupLabel(label: entry.group.label, first: index == 0 && !(showsRecording && !todayFirst))
                    if showsRecording && entry.group == .today {
                        RecordingListRow(selected: selection == RecordingSelection.id) { selection = RecordingSelection.id }
                    }
                    ForEach(Array(entry.rows.enumerated()), id: \.element.id) { rowIndex, meeting in
                        SwipeableMeetingRow(
                            meeting: meeting, group: entry.group,
                            selected: selection == meeting.id, swipe: swipe,
                            open: { open(meeting.id) }, settle: settle,
                            star: { toggleStar(meeting) }, delete: { delete(meeting) }
                        )
                        .padding(.top, rowIndex == 0 && !(showsRecording && entry.group == .today) ? 0 : 2)
                        .contextMenu { contextMenu(meeting) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 90)
        }
        .scrollIndicators(.never)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private func contextMenu(_ meeting: MeetingListItem) -> some View {
        Button("Open") { open(meeting.id) }
        Divider()
        MeetingOrganizeItems(meeting: meeting)
        Divider()
        Menu("Export") {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button(format.label) { Task { await export(meeting.id, format) } }
            }
        }
        .disabled(meeting.status.isBusy)
        Button("Reveal Original Audio in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.audioURL(meeting.id)])
        }
        if meeting.hasVideo {
            Button("Reveal Screen Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.paths.videoURL(meeting.id)])
            }
        }
        Divider()
        Button("Delete", role: .destructive) { delete(meeting) }
            .disabled(meeting.status.isBusy)
    }

    // MARK: Actions

    private func open(_ id: String) {
        if swipe.id != nil {
            settleClosed()
            return
        }
        selection = id
    }

    private func settleClosed() {
        withAnimation(SwipeState.animation) { swipe.close(animated: true) }
    }

    /// Where a swipe comes to rest: past `full` it acts, past 40 points it stays open.
    private func settle(_ id: String) {
        guard let meeting = model.libraryItem(id) else { return settleClosed() }
        let dx = swipe.id == id ? swipe.dx : 0
        let canDelete = SwipeState.canDelete(meeting)
        if dx >= SwipeState.full { toggleStar(meeting); return }
        if dx <= -SwipeState.full && canDelete { delete(meeting); return }
        withAnimation(SwipeState.animation) {
            if dx >= 40 {
                swipe.open(id, dx: SwipeState.openWidth)
            } else if dx <= -40 && canDelete {
                swipe.open(id, dx: -SwipeState.openWidth)
            } else {
                swipe.close(animated: true)
            }
        }
    }

    /// Read when a swipe starts, so it reflects the row as it is now rather than when the
    /// pointer arrived over it.
    private func canDelete(_ id: String) -> Bool {
        model.libraryItem(id).map(SwipeState.canDelete) ?? false
    }

    private func toggleStar(_ meeting: MeetingListItem) {
        withAnimation(SwipeState.animation) { swipe.close(animated: true) }
        Task { await model.setStarred(meeting.id, !meeting.starred) }
    }

    private func delete(_ meeting: MeetingListItem) {
        withAnimation(SwipeState.animation) { swipe.close(animated: true) }
        if selection == meeting.id { selection = nil }
        feedback.delete(meeting, model: model)
    }

    private func export(_ id: String, _ format: ExportFormat) async {
        do {
            let meeting = try await model.store.get(id)
            exportName = Exporter.suggestedFilename(meeting, format: format)
            exporting = ExportDocument(text: Exporter.text(meeting, format: format), format: format)
        } catch {
            model.report(error)
        }
    }
}

// MARK: - Search

/// The meeting filter's results, computed off the main actor and debounced.
@MainActor
@Observable
final class LibrarySearch {
    struct Request: Equatable {
        var query: String
        var revision: Int
    }

    private(set) var matches = Set<String>()
    private(set) var completed: Request?
    private(set) var error: String?
    private var latest: Request?

    var pending: Bool { latest != nil && completed != latest }

    func run(_ query: String, revision: Int, model: AppModel) async {
        let request = Request(query: query, revision: revision)
        latest = request
        error = nil
        guard !query.isEmpty else {
            matches = []
            completed = request
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let found = try await model.searchMeetings(query)
            try Task.checkCancellation()
            guard latest == request else { return }
            matches = found
            completed = request
        } catch is CancellationError {
            // A newer query or content change owns the next result.
        } catch {
            guard latest == request else { return }
            self.error = error.localizedDescription
            completed = request
        }
    }
}

// MARK: - Pieces

private struct GroupLabel: View {
    let label: String
    let first: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.text2)
            .padding(EdgeInsets(top: first ? 6 : 14, leading: 12, bottom: 6, trailing: 12))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ListMessage: View {
    let title: String
    let detail: String?
    var action: StatusAction?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.text)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.text2)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.accentInk)
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The two lines under a title, shared by meeting rows and the recording row.
private struct RowText: View {
    let title: String
    let meta: String
    let snippet: String
    let selected: Bool
    var trailing: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .letterSpacing(-0.01, size: 14.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing { trailing }
            }
            .frame(minHeight: 19)
            Text(meta)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? Color.white.opacity(0.88) : DS.text2)
                .lineLimit(1)
                .padding(.top, 2)
            Text(snippet)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? Color.white.opacity(0.88) : DS.text2)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .foregroundStyle(selected ? Color.white : DS.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DS.selection : .clear, in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
    }
}

private struct RecordingListRow: View {
    @Environment(AppModel.self) private var model
    let selected: Bool
    let open: () -> Void

    var body: some View {
        let session = model.recorder.session
        let started = session?.startedAt.flatMap(Meeting.parseTimestamp) ?? .now
        let paused = session?.status == .paused
        Button(action: open) {
            RowText(
                title: "New Meeting",
                meta: "\(MeetingText.time(started)) · \(paused ? "Paused" : "Recording")",
                snippet: paused ? "Recording paused" : "Recording audio…",
                selected: selected,
                trailing: AnyView(Circle().fill(Color(nsColor: .rgba(255, 69, 58))).frame(width: 10, height: 10))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Meeting, recording")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Swiping

/// One open swipe at a time, shared by every row and the trackpad monitor.
@MainActor
@Observable
final class SwipeState {
    static let openWidth: CGFloat = 76
    static let full: CGFloat = 150
    static let maximum: CGFloat = 230
    static let animation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)

    private(set) var id: String?
    private(set) var dx: CGFloat = 0
    /// The row under the pointer, which a two-finger swipe moves.
    var hovered: String?
    @ObservationIgnored var dragBase: CGFloat = 0
    @ObservationIgnored var justDragged = false

    /// A meeting still being processed can't be deleted. The open meeting can; deleting it
    /// closes it, as the detail's own Delete does.
    static func canDelete(_ meeting: MeetingListItem) -> Bool {
        !meeting.status.isBusy
    }

    func offset(for id: String) -> CGFloat { self.id == id ? dx : 0 }

    func open(_ id: String, dx: CGFloat) {
        self.id = id
        self.dx = dx
    }

    func track(_ id: String, base: CGFloat, delta: CGFloat, canDelete: Bool) {
        self.id = id
        dx = max(canDelete ? -Self.maximum : 0, min(Self.maximum, base + delta))
    }

    func close(animated: Bool) {
        id = nil
        dx = 0
    }
}

private struct SwipeableMeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: MeetingListItem
    let group: ListGroup
    let selected: Bool
    let swipe: SwipeState
    let open: () -> Void
    let settle: (String) -> Void
    let star: () -> Void
    let delete: () -> Void

    var body: some View {
        let dx = swipe.offset(for: meeting.id)
        let canDelete = SwipeState.canDelete(meeting)
        ZStack {
            if dx != 0 { underlay(dx) }
            Button(action: tap) {
                RowText(
                    title: meeting.title,
                    meta: MeetingText.listMeta(meeting, group: group),
                    snippet: MeetingText.listSnippet(meeting),
                    selected: selected,
                    trailing: trailing
                )
            }
            .buttonStyle(.plain)
            .offset(x: dx)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if !swipe.justDragged {
                            swipe.dragBase = swipe.offset(for: meeting.id)
                            swipe.justDragged = true
                        }
                        swipe.track(meeting.id, base: swipe.dragBase, delta: value.translation.width, canDelete: canDelete)
                    }
                    .onEnded { _ in
                        guard swipe.justDragged else { return }
                        settle(meeting.id)
                        // The button's own click follows the drag; let it pass first.
                        DispatchQueue.main.async { swipe.justDragged = false }
                    }
            )
        }
        .clipShape(.rect(cornerRadius: 14))
        .onHover { inside in
            if inside {
                swipe.hovered = meeting.id
            } else if swipe.hovered == meeting.id {
                swipe.hovered = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meeting.title + (meeting.starred ? ", starred" : ""))
        .accessibilityValue(MeetingText.listMeta(meeting, group: group))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: meeting.starred ? "Unstar" : "Star", star)
        .accessibilityAction(named: "Delete") { if canDelete { delete() } }
    }

    private func tap() {
        guard !swipe.justDragged else { return }
        open()
    }

    private var trailing: AnyView? {
        var marks: [AnyView] = []
        if meeting.starred {
            marks.append(AnyView(Icon(.star, size: 14, lineWidth: 1.6, filled: true)
                .foregroundStyle(selected ? Color.white : DS.starMark)))
        }
        if meeting.status.isBusy {
            marks.append(AnyView(RingSpinner(
                size: 15, track: selected ? .white.opacity(0.4) : DS.text3.opacity(0.6),
                arc: selected ? .white : DS.text2
            )))
        } else if meeting.status == .error {
            marks.append(AnyView(Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white : Color.orange)))
        }
        guard !marks.isEmpty else { return nil }
        return AnyView(HStack(spacing: 8) { ForEach(marks.indices, id: \.self) { marks[$0] } })
    }

    @ViewBuilder
    private func underlay(_ dx: CGFloat) -> some View {
        let open = SwipeState.openWidth
        let leftScale = max(0, min(1, (dx - 12) / (open - 24)))
        let rightScale = max(0, min(1, (-dx - 12) / (open - 24)))
        HStack(spacing: 0) {
            Button(action: star) {
                Icon(.star, size: 20, lineWidth: 1.9, filled: !meeting.starred)
                    .foregroundStyle(DS.starInk)
                    .overlay {
                        if !meeting.starred { Icon(.star, size: 20, lineWidth: 1.9).foregroundStyle(DS.starInk) }
                    }
                    .frame(width: 44, height: 44)
                    .background(DS.star, in: .circle)
                    .scaleEffect(leftScale)
                    .opacity(leftScale)
                    .frame(width: max(0, dx))
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(meeting.starred ? "Unstar" : "Star")
            Spacer(minLength: 0)
            Button(action: delete) {
                Icon(.trash, size: 20, lineWidth: 1.9)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(DS.swipeDelete, in: .circle)
                    .scaleEffect(rightScale)
                    .opacity(rightScale)
                    .frame(width: max(0, -dx))
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
    }
}

/// Two-finger horizontal swipes over a row move it, as in Mail. Vertical scrolling is left
/// to the list, and a swipe that starts vertically stays a scroll.
private struct SwipeScrollMonitor: NSViewRepresentable {
    let swipe: SwipeState
    let canDelete: (String) -> Bool
    let settle: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.swipe = swipe
        context.coordinator.canDelete = canDelete
        context.coordinator.settle = settle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(swipe: swipe, canDelete: canDelete, settle: settle) }

    @MainActor
    final class Coordinator {
        var swipe: SwipeState
        var canDelete: (String) -> Bool
        var settle: (String) -> Void
        private var monitor: Any?
        private var axis: Axis?
        private var target: String?
        private var base: CGFloat = 0
        private var travel: CGFloat = 0
        private var targetCanDelete = true

        init(swipe: SwipeState, canDelete: @escaping (String) -> Bool, settle: @escaping (String) -> Void) {
            self.swipe = swipe
            self.canDelete = canDelete
            self.settle = settle
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Momentum after a horizontal swipe belongs to that swipe.
            if event.momentumPhase != [] { return axis == .horizontal ? nil : event }
            guard event.hasPreciseScrollingDeltas else { return event }
            if event.phase.contains(.began) {
                axis = nil
                target = swipe.hovered
                targetCanDelete = target.map(canDelete) ?? false
                travel = 0
            }
            guard let target else { return event }
            if axis == nil {
                let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
                guard dx + dy > 0.5 else { return event }
                axis = dx > dy ? .horizontal : .vertical
                if axis == .horizontal {
                    base = swipe.offset(for: target)
                    if swipe.id != nil && swipe.id != target { swipe.close(animated: false) }
                }
            }
            guard axis == .horizontal else { return event }
            // Deltas describe content movement; follow the fingers either way round.
            let finger = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            travel += finger
            swipe.track(target, base: base, delta: travel, canDelete: targetCanDelete)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                settle(target)
                self.target = nil
            }
            return nil
        }
    }
}

// MARK: - New Meeting

/// Starts a recording with the saved defaults, or returns to the one in progress.
struct NewMeetingButton: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @Binding var sheet: RootSheet?

    var body: some View {
        let recording = model.isRecording
        Button {
            if recording {
                selection = RecordingSelection.id
            } else {
                Task { if await model.startQuickRecording() { selection = RecordingSelection.id } }
            }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(DS.record)
                    .frame(width: 12, height: 12)
                    .background { if recording { Circle().fill(DS.recordTint).padding(-4) } }
                Text(recording ? "Recording" : "New Meeting")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                if recording {
                    RecordingClock(style: .compact)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.text2)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 44)
            .background { if recording { Capsule().fill(DS.recordTint) } }
            .designGlassCapsule(blur: true)
            .overlay { if recording { Capsule().strokeBorder(DS.record, lineWidth: 0.5) } }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(recording ? "Show the recording in progress" : "Start recording a meeting (⌘R for options)")
        .contextMenu {
            Button("New Recording with Options…") { sheet = .record }
                .disabled(recording)
            Button("Import Audio…") { sheet = .importAudio }
        }
    }
}

/// The recording's elapsed time, updated continuously while it records.
struct RecordingClock: View {
    enum Style { case compact, hundredths }
    @Environment(AppModel.self) private var model
    let style: Style

    var body: some View {
        TimelineView(.periodic(from: .now, by: style == .compact ? 1 : 1.0 / 30)) { context in
            Text(text(now: context.date)).monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        let seconds = model.recorder.liveElapsed(at: now)
        let whole = Int(seconds)
        let clock = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
            : String(format: "%02d:%02d", whole / 60, whole % 60)
        return clock
    }
}
