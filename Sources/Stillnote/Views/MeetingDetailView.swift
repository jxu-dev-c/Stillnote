import StillnoteCore
import SwiftUI
import UniformTypeIdentifiers

enum MeetingPage: String {
    case transcript, summary
}

/// Which speaker the Assign Speaker popover is about: a whole voice from a header portrait,
/// or one line from the transcript's speaker chip.
enum PickerTarget: Equatable {
    case voice(String)
    case line(String)
}

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Environment(\.openSettings) private var openSettings
    let meeting: Meeting
    @Binding var selection: String?

    @State private var page: MeetingPage
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var pendingTitle: String?
    @State private var player: PlayerModel?
    @State private var lyrics = LyricsState()
    @State private var picker: PickerTarget?
    @State private var query = ""
    @State private var retranscribing = false
    @State private var confirmingSplit = false
    @State private var exporting: ExportDocument?

    init(meeting: Meeting, selection: Binding<String?>) {
        self.meeting = meeting
        _selection = selection
        // Summarized meetings open on their summary; everything else on the transcript.
        _page = State(initialValue: meeting.summary != nil && !meeting.status.isBusy ? .summary : .transcript)
    }

    private var naming: Bool { model.namingMeetings.contains(meeting.id) }
    private var splitting: Bool { model.splittingMeetings.contains(meeting.id) }
    private var busy: Bool { meeting.status.isBusy || splitting }

    var body: some View {
        VStack(spacing: 0) {
            DetailToolbar(
                actions: actions, actionsEnabled: !busy, deleteEnabled: !busy, page: $page, query: $query,
                onSearch: searchTranscript(advance:)
            ) {
                ToolbarIconButton(icon: .trash, label: "Delete Meeting", tint: DS.danger, enabled: !busy) {
                    selection = nil
                    feedback.delete(MeetingListItem(meeting), model: model)
                }
            }
            // Above the page, so nothing the page draws past its top edge can take its clicks.
            .zIndex(1)
            main
        }
        .onAppear {
            title = meeting.title
            if player == nil { player = PlayerModel(meeting: meeting, paths: model.paths) }
        }
        .onDisappear {
            commitTitle()
            player?.player.pause()
        }
        .onChange(of: meeting.status) { old, new in
            // A finished summary is what the user was waiting for.
            if old == .summarizing, new == .complete, meeting.summary != nil, picker == nil { page = .summary }
        }
        .onChange(of: query) { _, _ in searchTranscript(advance: false) }
        .sheet(isPresented: $retranscribing) { RetranscribeSheet(meeting: meeting) }
        .sheet(isPresented: $confirmingSplit) {
            SplitRecordingSheet(meeting: meeting, selection: $selection) { player?.player.pause() }
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting,
            contentType: exporting?.format == .json ? .json : .plainText,
            defaultFilename: exporting.map { Exporter.suggestedFilename(meeting, format: $0.format) }
        ) { _ in exporting = nil }
    }

    // MARK: Toolbar

    private var actions: [ToolbarAction] {
        let hasTranscript = !meeting.segments.isEmpty
        let blocker = model.autoTagBlocker(meeting)
        return [
            ToolbarAction(icon: .nameMeeting, symbol: "wand.and.sparkles", label: "Name Meeting", busy: naming,
                          enabled: hasTranscript && !busy && !naming) {
                // The provider chosen in Settings is the consent, so naming starts straight away.
                Task { await model.suggestTitle(meeting.id, allowRemote: true) }
            },
            ToolbarAction(icon: .autoTag, symbol: "wand.and.stars", label: "Auto-Tag Speakers",
                          help: blocker ?? "Link untagged speakers to the profiles their voices match",
                          busy: model.autoTaggingMeetings.contains(meeting.id),
                          enabled: hasTranscript && blocker == nil && !busy) {
                Task {
                    do {
                        let outcome = try await model.autoTag(meeting.id)
                        feedback.show(outcome.summary)
                    } catch {
                        model.report(error)
                    }
                }
            },
            ToolbarAction(icon: .transcribeAgain, symbol: "waveform.badge.magnifyingglass",
                          label: hasTranscript ? "Transcribe Again…" : "Transcribe",
                          enabled: !busy && model.speech.ready) {
                if hasTranscript {
                    retranscribing = true
                } else {
                    Task { await model.transcribe(meeting.id) }
                }
            },
            ToolbarAction(icon: .regenerate, symbol: "arrow.triangle.2.circlepath",
                          label: meeting.summary == nil ? "Create Summary" : "Regenerate Summary",
                          enabled: hasTranscript && !busy) {
                summarize()
            },
        ]
    }

    // MARK: Main

    private var main: some View {
        VStack(spacing: 0) {
            header
            switch page {
            case .transcript:
                TranscriptPage(
                    meeting: meeting, player: player, lyrics: lyrics, picker: $picker,
                    retranscribe: { retranscribing = true }
                )
            case .summary:
                SummaryPage(meeting: meeting, summarize: summarize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(PickerSpace.name))
        .overlayPreferenceValue(PickerAnchors.self) { anchors in
            // Switching pages closes the picker, so a line's picker never outlives the transcript.
            if let picker {
                SpeakerPickerOverlay(
                    meeting: meeting, target: picker, anchors: anchors, player: player,
                    close: { self.picker = nil }
                )
            }
        }
        .toastOverlay(feedback, top: 12)
        .onChange(of: page) { _, _ in picker = nil }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold))
                    .letterSpacing(-0.025, size: 30)
                    .foregroundStyle(DS.text)
                    .frame(height: 34.5)
                    .accessibilityLabel("Meeting title")
                    .disabled(busy || naming)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                    // Name Meeting replaces the title from outside this field.
                    .onChange(of: meeting.title) { title = meeting.title }
                    .contextMenu { moreItems }
                HStack(spacing: 10) {
                    if let pill = statusPill { pill }
                    Text(subtitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                        .help(cleanupNote ?? "")
                }
                .padding(.top, 6)
                .frame(minHeight: 22)
            }
            Spacer(minLength: 0)
            if !meeting.segments.isEmpty {
                VoicePortraits(
                    meeting: meeting, current: meeting.segments.indices.contains(lyrics.focus) ? meeting.segments[lyrics.focus].speaker : nil,
                    picker: $picker,
                    enabled: !busy
                )
                .padding(.bottom, 2)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 28, bottom: 4, trailing: 28))
        .zIndex(1)
    }

    private var statusPill: StatusPill? {
        if splitting { return StatusPill(text: "Splitting", tone: .accent) }
        switch meeting.status {
        case .transcribing: return StatusPill(text: "Transcribing", tone: .accent)
        case .summarizing: return StatusPill(text: "Summarizing", tone: .accent)
        case .error: return StatusPill(text: "Needs attention", tone: .warning)
        default: return naming ? StatusPill(text: "Naming", tone: .accent) : nil
        }
    }

    private var subtitle: String {
        if meeting.status == .error, let error = meeting.error { return error }
        let start = meeting.startDate
        var parts = ["\(MeetingText.day(start)) at \(MeetingText.time(start))"]
        if meeting.duration > 0 { parts.append(MeetingText.length(meeting.duration)) }
        if meeting.source == .import { parts.append("Imported") }
        return parts.joined(separator: " · ")
    }

    private var cleanupNote: String? {
        guard let cleanup = meeting.cleanup, cleanup.removedDuration > 0 else { return nil }
        return "Trimmed \(Formatting.duration(cleanup.removedDuration)) of silence from \(Formatting.duration(cleanup.originalDuration))"
    }

    /// Less frequent meeting actions, kept on the title's context menu.
    @ViewBuilder
    private var moreItems: some View {
        Button("Copy Summary") {
            guard let summary = meeting.summary else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Exporter.summaryText(summary), forType: .string)
        }
        .disabled(meeting.summary == nil)
        Menu("Export") {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button(format.label) {
                    exporting = ExportDocument(text: Exporter.text(meeting, format: format), format: format)
                }
            }
        }
        .disabled(busy)
        if model.canSplit(meeting) {
            Button("Split Recording…") { confirmingSplit = true }
                .disabled(busy || naming || !model.splittingMeetings.isEmpty)
        }
        Divider()
        Button("Reveal Original Audio in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.paths.audioURL(meeting.id)])
        }
    }

    // MARK: Actions

    /// The provider chosen in Settings is the consent, so a summary starts straight away.
    private func summarize() {
        Task { await model.summarize(meeting.id, allowRemote: true) }
    }

    /// Moves the transcript to the next line matching the search, or the first one as the query changes.
    private func searchTranscript(advance: Bool) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { lyrics.matches = []; return }
        let matches = meeting.segments.indices.filter {
            meeting.segments[$0].text.localizedCaseInsensitiveContains(needle)
                || meeting.speakerName(meeting.segments[$0].speaker).localizedCaseInsensitiveContains(needle)
        }
        lyrics.matches = matches
        guard !matches.isEmpty else { return }
        page = .transcript
        let next = advance
            ? matches.first { $0 > lyrics.focus } ?? matches[0]
            : matches.first { $0 >= lyrics.focus } ?? matches[0]
        lyrics.browse(to: next)
    }

    private func commitTitle() {
        // The detail can disappear after deletion or after a previous save has finished.
        guard let current = model.meeting(meeting.id) else { return }
        guard let cleaned = try? Validation.title(title), cleaned != current.title else {
            title = current.title
            return
        }
        // Submit, focus loss, and disappearance can all describe the same edit.
        guard pendingTitle != cleaned else { return }
        pendingTitle = cleaned
        let meetingID = meeting.id
        Task {
            await model.edit(meetingID) {
                $0.title = cleaned
                $0.automaticTitle = false
            }
            if pendingTitle == cleaned { pendingTitle = nil }
        }
    }
}

// MARK: - Toolbar

/// One of the meeting actions in the toolbar, drawn as an icon button or as a menu item.
struct ToolbarAction: Identifiable {
    let icon: DesignIcon
    /// The menu item's image when the toolbar is too narrow for icon buttons.
    let symbol: String
    let label: String
    var help: String?
    var busy = false
    var enabled = true
    let perform: () -> Void

    var id: String { symbol }
}

/// The detail's toolbar row: meeting actions, delete, the page switcher, and transcript search.
/// As the pane narrows, the meeting actions fold into one menu first, then the switcher drops
/// its labels and search shortens.
struct DetailToolbar<Delete: View>: View {
    let actions: [ToolbarAction]
    let actionsEnabled: Bool
    let deleteEnabled: Bool
    @Binding var page: MeetingPage
    @Binding var query: String
    let onSearch: (Bool) -> Void
    @ViewBuilder let delete: Delete

    /// Widths at which the full design no longer fits, measured inside the row's padding:
    /// four 40-point buttons, the labeled switcher, and a 160-point search with their gaps.
    static var collapseBelow: CGFloat { 670 }
    /// Below this the labeled switcher and full search no longer fit beside the folded menu.
    static var compactBelow: CGFloat { 545 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - 56
            let collapsed = width < Self.collapseBelow
            let compact = width < Self.compactBelow
            HStack(spacing: 10) {
                Group {
                    if collapsed {
                        ActionsMenu(actions: actions)
                    } else {
                        HStack(spacing: 2) {
                            ForEach(actions) { action in
                                ToolbarIconButton(icon: action.icon, label: action.label, help: action.help,
                                                  busy: action.busy, enabled: action.enabled, action: action.perform)
                            }
                        }
                    }
                }
                .padding(.horizontal, 3)
                .frame(height: 36)
                .designGlassCapsule()
                .opacity(actionsEnabled ? 1 : 0.38)
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Meeting actions")
                HStack(spacing: 2) { delete }
                    .padding(.horizontal, 3)
                    .frame(height: 36)
                    .designGlassCapsule()
                    .opacity(deleteEnabled ? 1 : 0.38)
                    .fixedSize()
                Spacer(minLength: 0)
                PageSwitcher(page: $page, compact: compact).fixedSize()
                Spacer(minLength: 0)
                SearchCapsule(query: $query, placeholder: compact ? "Search" : "Search transcript",
                              onSubmit: { onSearch(true) })
                    .frame(minWidth: 36, maxWidth: compact ? 110 : 216)
                    .layoutPriority(-1)
            }
            .padding(EdgeInsets(top: 28, leading: 28, bottom: 8, trailing: 28))
            .animation(.snappy(duration: 0.2), value: collapsed)
            .animation(.snappy(duration: 0.2), value: compact)
        }
        .frame(height: 72)
    }
}

/// The meeting actions folded into one button, for narrow windows.
private struct ActionsMenu: View {
    let actions: [ToolbarAction]

    var body: some View {
        Menu {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Label(action.busy ? action.label.replacingOccurrences(of: "…", with: "") + "…" : action.label,
                          systemImage: action.symbol)
                }
                .disabled(!action.enabled || action.busy)
            }
        } label: {
            Group {
                if actions.contains(where: \.busy) {
                    ProgressView().controlSize(.small)
                } else {
                    Icon(.more, size: 20, filled: true)
                }
            }
            .foregroundStyle(DS.text)
            .frame(width: 40, height: 30)
            .hoverFill(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Meeting actions")
        .accessibilityLabel("Meeting actions")
    }
}

struct ToolbarIconButton: View {
    let icon: DesignIcon
    let label: String
    var help: String?
    var tint: Color = DS.text
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Icon(icon, size: 20)
                }
            }
            .foregroundStyle(tint)
            .frame(width: 40, height: 30)
            .hoverFill(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

private struct PageSwitcher: View {
    @Binding var page: MeetingPage
    let compact: Bool

    var body: some View {
        HStack(spacing: 2) {
            tab(.transcript, "Transcript", icon: .transcript, lineWidth: 1.9)
            tab(.summary, "Summary", icon: .sparkle, lineWidth: 1.8)
        }
        .padding(.horizontal, 3)
        .frame(height: 36)
        .designGlassCapsule()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting pages")
    }

    private func tab(_ value: MeetingPage, _ title: String, icon: DesignIcon, lineWidth: CGFloat) -> some View {
        let selected = page == value
        return Button { page = value } label: {
            HStack(spacing: 7) {
                Icon(icon, size: 17, lineWidth: lineWidth)
                if !compact { Text(title).font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(selected ? Color.white : DS.text2)
            .padding(.leading, compact ? 12 : 11)
            .padding(.trailing, compact ? 12 : 14)
            .frame(height: 30)
            .background(selected ? DS.selection : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SearchCapsule: View {
    @Binding var query: String
    let placeholder: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Icon(.search, size: 17, lineWidth: 1.8)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DS.text)
                .onSubmit(onSubmit)
                .onExitCommand { query = "" }
                .accessibilityLabel(placeholder)
        }
        .foregroundStyle(DS.text2)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .designGlassCapsule()
        .clipShape(.capsule)
    }
}

/// The header's colored status: a dot and a word.
struct StatusPill: View {
    enum Tone { case accent, record, warning }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            if tone == .record {
                PulsingDot(color: DS.record, size: 7)
            } else {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 22)
        .background(fill, in: .capsule)
    }

    private var dot: Color {
        switch tone {
        case .accent: DS.accent
        case .record: DS.record
        case .warning: .orange
        }
    }

    private var ink: Color {
        switch tone {
        case .accent: DS.accentInk
        case .record: DS.danger
        case .warning: .orange
        }
    }

    private var fill: Color {
        switch tone {
        case .accent: DS.Accent.blue.tint
        case .record: DS.recordTint
        case .warning: Color.orange.opacity(0.18)
        }
    }
}

// MARK: - Speakers

/// One portrait per voice. Choosing one opens Assign Speaker for every line in that voice.
private struct VoicePortraits: View {
    let meeting: Meeting
    let current: String?
    @Binding var picker: PickerTarget?
    let enabled: Bool

    var body: some View {
        let order = meeting.speakerOrder
        HStack(spacing: 8) {
            ForEach(order, id: \.self) { id in
                let look = meeting.look(id)
                let open = picker == .voice(id)
                let lines = meeting.segments.count { $0.speaker == id }
                Button {
                    picker = open ? nil : .voice(id)
                } label: {
                    SpeakerPortrait(look: look, size: 32, fontSize: 13)
                        .overlay {
                            if open {
                                Circle().stroke(DS.menuSolid, lineWidth: 2).padding(-2)
                                Circle().stroke(DS.accent, lineWidth: 2).padding(-4)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .hoverFill(Circle())
                        .overlay(alignment: .bottom) {
                            if current == id {
                                Capsule().fill(DS.accent).frame(width: 14, height: 3).offset(y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(enabled ? look.name : "Available when processing finishes")
                .accessibilityLabel("\(look.unknown ? "Identify" : "Change speaker for") \(look.name), \(lines) \(lines == 1 ? "line" : "lines")")
                .anchorPreference(key: PickerAnchors.self, value: .bounds) { [.voice(id): $0] }
            }
        }
        .transformAnchorPreference(key: PickerAnchors.self, value: .bounds) { $0[.voiceGroup] = $1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers")
    }
}

/// A speaker's initial (or number) in a tinted circle; unidentified voices are dashed.
struct SpeakerPortrait: View {
    let look: SpeakerLook
    let size: CGFloat
    let fontSize: CGFloat

    var body: some View {
        Text(look.initial)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(look.ink)
            .frame(width: size, height: size)
            .background(look.fill, in: .circle)
            .overlay {
                if look.unknown {
                    Circle().strokeBorder(DS.text3, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
    }
}

enum PickerSpace {
    static let name = "detail-main"
}

enum PickerAnchorID: Hashable {
    case voice(String)
    case voiceGroup
    case line
}

struct PickerAnchors: PreferenceKey {
    static let defaultValue: [PickerAnchorID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PickerAnchorID: Anchor<CGRect>], nextValue: () -> [PickerAnchorID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Split

/// Confirms splitting a long recording into parts.
struct SplitRecordingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    @Binding var selection: String?
    let willSplit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Split Recording?", systemImage: "scissors")
                .font(.title2.bold())
            Text("This replaces “\(meeting.title)” and its complete audio with these parts. The original summary will be removed. This cannot be undone.")
            if let parts = try? RecordingSplit.parts(meeting) {
                ForEach(parts) { part in
                    HStack {
                        Text(part.title).lineLimit(2)
                        Spacer()
                        Text(Formatting.duration(part.duration)).monospacedDigit()
                    }
                }
            }
            Text("Transcript sentences are assigned by their midpoint and timestamps restart in each part. Notes and context links are copied to every part. Summaries start empty.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Split and Replace Original", role: .destructive) {
                    dismiss()
                    willSplit()
                    Task {
                        if let parts = await model.splitRecording(meeting.id) { selection = parts.first?.id }
                    }
                }
                .disabled(meeting.status.isBusy || !model.splittingMeetings.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// Wraps an export as a document so the system save panel handles the write.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json]

    let text: String
    let format: ExportFormat

    init(text: String, format: ExportFormat) {
        self.text = text
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
        format = .markdown
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
