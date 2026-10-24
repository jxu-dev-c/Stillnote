import StillnoteCore
import SwiftUI
import UniformTypeIdentifiers

enum MeetingTab: String, CaseIterable, Identifiable {
    case summary, transcript, context
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let meeting: Meeting
    @Binding var selection: String?

    @State private var tab: MeetingTab = .summary
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var pendingTitle: String?
    @State private var player: PlayerModel?
    @State private var confirmingDelete = false
    @State private var confirmingSplit = false
    @State private var retranscribing = false
    @State private var exporting: ExportDocument?
    @State private var notesDirty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let error = meeting.error, meeting.status != .transcribing {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(StillnoteTheme.detailBodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentPanel()
                }
                content
            }
            .frame(maxWidth: StillnoteTheme.readingWidth, alignment: .leading)
            .padding(StillnoteTheme.contentInset)
            .frame(maxWidth: .infinity)
        }
        .disabled(splitting)
        .background(.background)
        .playbackBar {
            if let player {
                PlayerView(player: player)
                    .frame(maxWidth: StillnoteTheme.readingWidth)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(meeting.title)
        // The heading already names the meeting. Keep room for navigation at compact
        // widths; macOS retains the title in the Window menu and accessibility.
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .onAppear {
            title = meeting.title
            if player == nil { player = PlayerModel(meeting: meeting, paths: model.paths) }
        }
        .onDisappear(perform: commitTitle)
        .confirmationDialog(
            "Delete “\(meeting.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                Task {
                    await model.delete(meeting.id)
                    selection = nil
                }
            }
        } message: {
            Text("This permanently deletes the recording, transcript, summary, and context.")
        }
        .sheet(isPresented: $confirmingSplit) {
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
                    Button("Cancel", role: .cancel) { confirmingSplit = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Split and Replace Original", role: .destructive) {
                        confirmingSplit = false
                        player?.player.pause()
                        Task {
                            if let parts = await model.splitRecording(meeting.id) { selection = parts.first?.id }
                        }
                    }
                    .disabled(meeting.status.isBusy || naming || !model.splittingMeetings.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 480)
        }
        .sheet(isPresented: $retranscribing) {
            RetranscribeSheet(meeting: meeting)
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: exporting,
            contentType: exporting?.format == .json ? .json : .plainText,
            defaultFilename: exporting.map { Exporter.suggestedFilename(meeting, format: $0.format) }
        ) { _ in exporting = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(StillnoteTheme.detailTitleFont)
                    .accessibilityLabel("Meeting title")
                    .disabled(meeting.status.isBusy || naming)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    .onChange(of: titleFocused) {
                        if !titleFocused { commitTitle() }
                    }
                    .onChange(of: meeting.id) { title = meeting.title }
                    // Name Meeting replaces the title from outside this field.
                    .onChange(of: meeting.title) { title = meeting.title }
                if !meeting.segments.isEmpty {
                    nameButton
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    metadata
                    Spacer(minLength: 0)
                    headerActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { metadata }
                    headerActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if splitting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Splitting recording…")
                    Text(model.splitProgress[meeting.id] ?? "Preparing…").foregroundStyle(.secondary)
                }
            }
            if meeting.status.isBusy {
                jobProgress
            }
        }
    }

    private var splitting: Bool { model.splittingMeetings.contains(meeting.id) }

    private var naming: Bool { model.namingMeetings.contains(meeting.id) }

    private var nameButton: some View {
        // The provider chosen in Settings is the consent, so naming starts straight away.
        Button { Task { await model.suggestTitle(meeting.id, allowRemote: true) } } label: {
            if naming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Naming…")
                }
            } else {
                Label("Name Meeting", systemImage: "wand.and.sparkles")
            }
        }
        .font(StillnoteTheme.detailSupportingFont)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(meeting.status.isBusy || naming)
        .help("Suggest a title from this meeting's summary, or its transcript when there is no summary")
    }

    private var headerActions: some View {
        HStack(spacing: 16) {
            if model.canSplit(meeting) {
                Button { confirmingSplit = true } label: {
                    Label("Split Recording", systemImage: "scissors")
                }
                .font(StillnoteTheme.detailSupportingFont)
                .buttonStyle(.borderless)
                .disabled(meeting.status.isBusy || naming || !model.splittingMeetings.isEmpty)
            }
            if tab == .summary, meeting.summary != nil, !meeting.segments.isEmpty {
                Button(action: summarize) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .font(StillnoteTheme.detailSupportingFont)
                .buttonStyle(.borderless)
                .disabled(meeting.status.isBusy || splitting)
            }
            MeetingStatusLabel(status: meeting.status, font: StillnoteTheme.detailSupportingFont.weight(.medium))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var metadata: some View {
        Group {
            Label {
                Text(meeting.createdDate, format: .dateTime.month(.abbreviated).day().year())
            } icon: {
                Image(systemName: "calendar")
            }
            Label {
                Text(meeting.duration > 0 ? Formatting.duration(meeting.duration) : "Audio saved")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock")
            }
            Label(meeting.speakers.isEmpty ? "No speakers" : "\(meeting.speakers.count) \(meeting.speakers.count == 1 ? "speaker" : "speakers")",
                  systemImage: "person.2")
            // Keep the split action and trim badge mutually exclusive in this row.
            // Cleanup metadata remains on the meeting when the badge is hidden.
            if !model.canSplit(meeting), let cleanup = meeting.cleanup, cleanup.removedDuration > 0 {
                Label {
                    Text("Trimmed \(Formatting.duration(cleanup.removedDuration)) of silence from \(Formatting.duration(cleanup.originalDuration))")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "scissors")
                }
            }
        }
        .font(StillnoteTheme.detailSupportingFont)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var jobProgress: some View {
        HStack(spacing: 12) {
            ProgressView(
                value: meeting.progress, total: 100,
                label: {
                    Text(meeting.status == .transcribing ? "Transcribing" : "Summarizing")
                        .font(StillnoteTheme.detailSupportingFont.weight(.medium))
                },
                currentValueLabel: {
                    Text(meeting.stage.isEmpty ? "Preparing…" : meeting.stage)
                        .font(StillnoteTheme.detailSupportingFont)
                        .foregroundStyle(.secondary)
                }
            )
            if meeting.status == .transcribing {
                Button("Stop") { Task { await model.cancelTranscription(meeting.id) } }
                    .font(StillnoteTheme.detailSupportingFont)
                    .disabled(meeting.stage == "Stopping transcription…")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Meeting view", selection: $tab) {
                ForEach(MeetingTab.allCases) { tab in
                    Text(tab == .context && notesDirty ? "\(tab.label) •" : tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Copy Summary", systemImage: "doc.on.doc") {
                    guard let summary = meeting.summary else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Exporter.summaryText(summary), forType: .string)
                }
                .disabled(meeting.summary == nil)
                Divider()
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.label) {
                        exporting = ExportDocument(text: Exporter.text(meeting, format: format), format: format)
                    }
                }
                Divider()
                Button("Reveal Original Audio in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.audioURL(meeting.id)])
                }
                if meeting.hasVideo {
                    Button("Reveal Screen Recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.videoURL(meeting.id)])
                    }
                }
            } label: {
                ToolbarIcon("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export Meeting")
            .disabled(meeting.status.isBusy || splitting)

            Menu {
                Button("Delete Meeting…", role: .destructive) {
                    confirmingDelete = true
                }
            } label: {
                ToolbarIcon("More", systemImage: "ellipsis")
            }
            .help("More Meeting Actions")
            .disabled(meeting.status.isBusy || splitting)
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if meeting.segments.isEmpty && tab != .context {
            emptyTranscript
        } else {
            switch tab {
            case .summary:
                SummaryTab(meeting: meeting, requestSummary: summarize)
            case .transcript:
                TranscriptTab(meeting: meeting, player: player, retranscribe: { retranscribing = true })
            case .context:
                ContextTab(meeting: meeting, notesDirty: $notesDirty)
            }
        }
    }

    private var emptyTranscript: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: "text.alignleft")
        } description: {
            Text(emptyDescription)
        } actions: {
            if meeting.status != .transcribing {
                if model.speech.ready {
                    Button("Transcribe Recording") { Task { await model.transcribe(meeting.id) } }
                        .primaryActionStyle()
                } else {
                    Button("Set Up Transcription") { openSettings() }
                        .primaryActionStyle()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyTitle: String {
        if meeting.status == .transcribing { return "Transcribing…" }
        if meeting.status == .transcribed || meeting.status == .complete { return "No speech detected" }
        return "No transcript yet"
    }

    private var emptyDescription: String {
        if meeting.status == .transcribing { return meeting.stage }
        if meeting.status == .transcribed || meeting.status == .complete {
            return "Your audio is saved. Check the microphone, language, or try a clearer recording."
        }
        return model.speech.ready
            ? "Transcribe this recording to get a speaker-labeled transcript."
            : model.speech.detail
    }

    /// The provider chosen in Settings is the consent, so a summary starts straight away.
    private func summarize() {
        Task { await model.summarize(meeting.id, allowRemote: true) }
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
