import AppKit
import StillnoteCore
import SwiftUI

/// The recording in progress, shown in the window with the same anatomy as a transcript:
/// a speaker-style status, the running time, and a dock with the live input along it.
struct RecordingPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Binding var selection: String?

    @State private var page: MeetingPage = .transcript
    @State private var query = ""
    @State private var levels = LevelHistory()
    @State private var finishing: FinishAction?
    @State private var confirmingDiscard = false

    private enum FinishAction { case stop, summarize }

    /// The meeting actions, shown but unavailable until the recording is saved.
    private static let idleActions = [
        ToolbarAction(icon: .nameMeeting, symbol: "wand.and.sparkles", label: "Name Meeting", help: "Available after the recording is saved", enabled: false) {},
        ToolbarAction(icon: .autoTag, symbol: "wand.and.stars", label: "Auto-Tag Speakers", help: "Available after the recording is saved", enabled: false) {},
        ToolbarAction(icon: .transcribeAgain, symbol: "waveform.badge.magnifyingglass", label: "Transcribe Again", help: "Available after the recording is saved", enabled: false) {},
        ToolbarAction(icon: .regenerate, symbol: "arrow.triangle.2.circlepath", label: "Regenerate Summary", help: "Available after the recording is saved", enabled: false) {},
    ]

    var body: some View {
        if let session = model.recorder.session {
            content(session)
        } else {
            Color.clear
        }
    }

    private func content(_ session: RecordingSessionState) -> some View {
        VStack(spacing: 0) {
            DetailToolbar(actions: Self.idleActions, actionsEnabled: false, deleteEnabled: false,
                          page: $page, query: $query, onSearch: { _ in }) {
                ToolbarIconButton(icon: .trash, label: "Delete Meeting", help: "Available after the recording is saved", tint: DS.danger, enabled: false) {}
            }
            VStack(spacing: 0) {
                header(session)
                ZStack(alignment: .bottom) {
                    switch page {
                    case .transcript: live(session)
                    case .summary: summary(session)
                    }
                    BottomFade()
                    dock(session)
                        .padding(.leading, 28)
                        .padding(.trailing, 32)
                        .padding(.bottom, 22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toastOverlay(feedback, top: 12)
        }
        .onChange(of: model.recorder.microphoneLevel) { _, level in
            levels.append(max(level?.rms ?? 0, model.recorder.systemLevel?.rms ?? 0),
                          paused: model.recorder.session?.status != .recording)
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    await model.recorder.discard()
                    selection = nil
                }
            }
        } message: {
            Text("Stops recording and deletes the unsaved audio and video.")
        }
    }

    private func header(_ session: RecordingSessionState) -> some View {
        let started = session.startedAt.flatMap(Meeting.parseTimestamp) ?? .now
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("New Meeting")
                    .font(.system(size: 30, weight: .bold))
                    .letterSpacing(-0.025, size: 30)
                    .foregroundStyle(DS.text)
                    .frame(height: 34.5)
                HStack(spacing: 10) {
                    switch session.status {
                    case .recording: StatusPill(text: "Recording", tone: .record)
                    case .paused: StatusPill(text: "Paused", tone: .warning)
                    case .starting: StatusPill(text: "Starting", tone: .accent)
                    case .stopping, .stopped: StatusPill(text: model.recorder.isSaving ? "Saving" : "Stopped", tone: .accent)
                    }
                    Text("Started \(MeetingText.time(started))")
                        .font(.system(size: 13.5))
                        .foregroundStyle(DS.text2)
                }
                .padding(.top, 6)
                .frame(minHeight: 22)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 28, bottom: 4, trailing: 28))
    }

    private func summary(_ session: RecordingSessionState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Icon(.sparkle, size: 16, lineWidth: 1.8).foregroundStyle(DS.accentInk)
                        Text("Summary")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.text)
                        Spacer(minLength: 8)
                    }
                    .frame(minHeight: 28)
                    .padding(.bottom, 12)

                    Text("No summary yet. A summary is created after the meeting ends.")
                        .font(.system(size: 20, weight: .medium))
                        .letterSpacing(-0.015, size: 20)
                        .lineSpacing(4)
                        .foregroundStyle(DS.text2)
                        .frame(maxWidth: 780, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hairline().padding(.vertical, 28)
                RecordingMasonryLayout(columnSpacing: 48, rowSpacing: 32) {
                    RecordingLinksSection(session: session)
                    RecordingNotesSection(session: session)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 28, bottom: 112, trailing: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Recording summary and context")
    }

    // MARK: Live

    private func live(_ session: RecordingSessionState) -> some View {
        var save: StatusAction?
        if session.status == .stopped && !model.recorder.isSaving {
            save = StatusAction("Save Recording") { Task { await finish(.stop) } }
        }
        return StatusPage(
            labelView: { label(session) },
            bigView: { if session.status != .starting { RecordingTimer() } },
            message: message(session),
            action: save
        )
    }

    @ViewBuilder
    private func label(_ session: RecordingSessionState) -> some View {
        switch session.status {
        case .recording:
            StatusLabel(text: "Listening", dot: DS.record, pulsing: true, detail: sources(session))
        case .paused:
            StatusLabel(text: "Paused", dot: .orange, detail: sources(session))
        case .starting:
            StatusLabel(text: "Waiting for permission", dot: DS.accent, pulsing: true)
        case .stopping:
            StatusLabel(text: "Finishing recording", dot: DS.accent, pulsing: true)
        case .stopped:
            StatusLabel(text: model.recorder.isSaving ? "Saving" : "Stopped", dot: DS.text3, pulsing: model.recorder.isSaving)
        }
    }

    private func sources(_ session: RecordingSessionState) -> String {
        var sources = [session.options.systemAudio ? "System audio and your microphone" : "Your microphone"]
        if session.options.screenVideo { sources.append("screen") }
        return sources.joined(separator: " · ")
    }

    private func message(_ session: RecordingSessionState) -> String? {
        if let error = session.error { return error }
        switch session.status {
        case .starting:
            return "Allow Microphone and Screen & System Audio Recording in the macOS prompts."
        case .paused:
            return "Recording is paused. Resume when you’re ready."
        default:
            return nil
        }
    }

    private func dock(_ session: RecordingSessionState) -> some View {
        let locked = finishing != nil || model.recorder.isSaving || session.status == .starting || session.status == .stopping
        let paused = session.status == .paused
        return HStack(spacing: 22) {
            HStack(spacing: 4) {
                Button {
                    paused ? model.recorder.resume() : model.recorder.pause()
                } label: {
                    Icon(paused ? .play : .pause, size: 22, filled: true)
                        .foregroundStyle(DS.text)
                        .frame(width: 44, height: 44)
                        .hoverFill(Circle())
                }
                .buttonStyle(.plain)
                .disabled(locked || !(session.status == .recording || paused))
                .help(paused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(paused ? "Resume recording" : "Pause recording")

                Button { Task { await finish(model.speech.ready ? .summarize : .stop) } } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .frame(width: 48, height: 48)
                        .background(DS.record, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help(model.speech.ready
                      ? "Stop, then transcribe and summarize. Right-click for more."
                      : "Stop and save the recording. Right-click for more.")
                .accessibilityLabel("Stop recording")
                .contextMenu {
                    Button("Stop, Transcribe & Summarize") { Task { await finish(.summarize) } }
                        .disabled(!model.speech.ready || locked)
                    Button("Stop Recording") { Task { await finish(.stop) } }
                        .disabled(locked)
                    Divider()
                    Button("Discard Recording…", role: .destructive) { confirmingDiscard = true }
                        .disabled(locked)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 60)
            .designGlassCapsule(blur: true)
            .opacity(locked ? 0.6 : 1)

            LiveStrip(levels: levels.values)
            HStack(spacing: 7) {
                if session.status == .recording {
                    PulsingDot(color: DS.record, size: 7)
                } else {
                    Circle().fill(DS.text3).frame(width: 7, height: 7)
                }
                RecordingClock(style: .compact)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.text2)
            .fixedSize()
        }
        .frame(height: 60)
    }

    // MARK: Actions

    private func finish(_ action: FinishAction) async {
        finishing = action
        defer { finishing = nil }
        guard let meeting = await model.finishRecording() else { return }
        selection = meeting.id
        if action == .summarize {
            let processed = await model.processRecording(meeting)
            // A split replaces the recording; show its first part unless the user moved on.
            if selection == meeting.id, let first = processed.first, first.id != meeting.id {
                selection = first.id
            }
        }
    }
}

/// 64-point minutes and seconds with the hundredths dimmed.
private struct RecordingTimer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let seconds = model.recorder.liveElapsed(at: context.date)
            let whole = Int(seconds)
            let clock = whole >= 3600
                ? String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
                : String(format: "%02d:%02d", whole / 60, whole % 60)
            BigFigure(value: clock, suffix: String(format: ".%02d", Int((seconds - Double(whole)) * 100)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording time")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The last 150 input levels, newest last.
struct LevelHistory {
    static let count = 150
    private(set) var values: [Double] = Array(repeating: 0, count: count)

    mutating func append(_ rms: Double, paused: Bool) {
        // −60 dBFS to 0 dBFS, the range where speech is legible on a meter.
        let decibels = 20 * log10(max(rms, 0.001))
        let level = paused ? 0 : max(0, min(1, (decibels + 60) / 60))
        values.removeFirst()
        values.append(level)
    }
}

/// Input level bars filling in from the right, with the red recording head at the edge.
private struct LiveStrip: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let usable = size.width - 8
            let gap = (usable - CGFloat(count) * 2) / CGFloat(count - 1)
            for (index, level) in levels.enumerated() {
                let height = max(2, min(26, 2 + 24 * level))
                let rect = CGRect(x: CGFloat(index) * (2 + gap), y: (size.height - height) / 2, width: 2, height: height)
                let opacity = index > count - 16 ? 1 : 0.6
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(DS.text.opacity(opacity)))
            }
        }
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(DS.record)
                .frame(width: 3)
                .padding(.vertical, 4)
                .shadow(color: DS.record, radius: 4)
        }
        .frame(height: 44)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Live Context & Notes

private struct RecordingMasonryLayout: Layout {
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat
    var twoColumnMinimum: CGFloat = 560

    private struct Arrangement {
        var columns: Int
        var columnWidth: CGFloat
        var heights: [CGFloat]
        var slots: [MasonryPlacement.Slot]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 720
        let arrangement = arrange(subviews, width: width)
        let height = MasonryPlacement.height(
            heights: arrangement.heights, columns: arrangement.columns, spacing: rowSpacing
        )
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let slot = arrangement.slots[index]
            let x = bounds.minX + CGFloat(slot.column) * (arrangement.columnWidth + columnSpacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + slot.y),
                proposal: ProposedViewSize(width: arrangement.columnWidth, height: arrangement.heights[index])
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> Arrangement {
        let columns = width >= twoColumnMinimum ? 2 : 1
        let columnWidth = max(0, (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        let slots = MasonryPlacement.slots(heights: heights, columns: columns, spacing: rowSpacing)
        return Arrangement(columns: columns, columnWidth: columnWidth, heights: heights, slots: slots)
    }
}

private struct RecordingSectionBlock<Content: View, Accessory: View>: View {
    let title: String
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(
        title: String, spacing: CGFloat = 12, @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.spacing = spacing
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 28)
            .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

private struct RecordingLinksSection: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSessionState
    @State private var adding = false
    @State private var editing: ContextLink?

    var body: some View {
        RecordingSectionBlock(title: "Links", spacing: 2) {
            if session.contextLinks.isEmpty {
                Text("No links yet. Add any you want to keep with this meeting.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(DS.text2)
            }
            ForEach(session.contextLinks) { link in
                RecordingLinkRow(
                    link: link,
                    edit: { editing = link },
                    remove: { model.removeRecordingContextLink(link.url) }
                )
            }
        } accessory: {
            Button { adding = true } label: {
                Icon(.plus, size: 16, lineWidth: 2)
                    .foregroundStyle(DS.accentInk)
                    .frame(width: 24, height: 24)
                    .hoverFill(Circle())
            }
            .buttonStyle(.plain)
            .disabled(session.contextLinks.count >= Validation.maxContextLinks)
            .help("Add link")
            .accessibilityLabel("Add link")
        }
        .sheet(isPresented: $adding) { RecordingLinkEditor(session: session, existing: nil) }
        .sheet(item: $editing) { link in RecordingLinkEditor(session: session, existing: link) }
    }
}

private struct RecordingLinkRow: View {
    let link: ContextLink
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        let url = URL(string: link.url)
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 12) {
                Icon(.link, size: 16, lineWidth: 1.8)
                    .foregroundStyle(DS.accentInk)
                    .frame(width: 32, height: 32)
                    .background(DS.hover, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.title.isEmpty ? host : link.title)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .help(link.url)
        .contextMenu {
            Button("Open in Browser") { if let url { NSWorkspace.shared.open(url) } }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
            }
            Button("Edit…", action: edit)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

private struct RecordingNotesSection: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSessionState
    @State private var draft = NotesDraft()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        RecordingSectionBlock(title: "Notes", spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.system(size: 15))
                .lineSpacing(4.5)
                .foregroundStyle(DS.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 14)
                .frame(height: 112)
                .background(DS.field, in: .rect(cornerRadius: 14))
                .accessibilityLabel("Meeting notes")
                .onChange(of: draft.text) { scheduleSave() }
            if let error = draft.error {
                HStack(spacing: 8) {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry") { Task { await save() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accentInk)
                }
                .font(.system(size: 12.5))
            }
        } accessory: {
            if draft.isDirty && draft.error == nil {
                Text("Saving…").font(.system(size: 12.5)).foregroundStyle(DS.text3)
            }
        }
        .onAppear { draft.load(meetingID: session.id, savedText: session.notes) }
        .onChange(of: session.id) { _, _ in
            saveTask?.cancel()
            draft.load(meetingID: session.id, savedText: session.notes)
        }
        .onDisappear {
            saveTask?.cancel()
            Task { await save() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        draft.recordEdit()
        guard draft.isDirty else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        await draft.save { pending in
            model.updateRecordingNotes(pending)
        }
    }
}

private struct RecordingLinkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: RecordingSessionState
    let existing: ContextLink?

    @State private var address = ""
    @State private var label = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add link" : "Edit link").font(.headline)
            Form {
                TextField("URL", text: $address, prompt: Text("https://example.com"))
                TextField("Label", text: $label, prompt: Text("Use the page title"))
            }
            .formStyle(.grouped)
            .frame(height: 90)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            address = existing?.url ?? ""
            label = existing?.title ?? ""
        }
    }

    private func save() async {
        let others = session.contextLinks.filter { $0.url != existing?.url }
        do {
            let url = try Validation.contextLinkURL(address, existing: others)
            saving = true
            var title = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = await LinkMetadata.pageTitle(url) }
            let link = ContextLink(url: url, title: String(title.prefix(Validation.maxLinkTitleLength)))
            _ = try model.saveRecordingContextLink(link, replacing: existing?.url)
            dismiss()
        } catch {
            saving = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
