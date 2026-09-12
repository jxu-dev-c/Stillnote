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
    @State private var player: PlayerModel?
    @State private var confirmingDelete = false
    @State private var retranscribing = false
    @State private var consenting = false
    @State private var exporting: ExportDocument?
    @State private var notesDirty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = meeting.error, meeting.status != .transcribing {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let player {
                        PlayerView(player: player)
                    }
                    Picker("View", selection: $tab) {
                        ForEach(MeetingTab.allCases) { tab in
                            Text(tab == .context && notesDirty ? "\(tab.label) •" : tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    content
                }
                .padding(20)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar { toolbar }
        .onAppear {
            title = meeting.title
            if player == nil { player = PlayerModel(meeting: meeting, paths: model.paths) }
        }
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
        .sheet(isPresented: $retranscribing) {
            RetranscribeSheet(meeting: meeting)
        }
        .sheet(isPresented: $consenting) {
            ConsentSheet(meeting: meeting)
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
        VStack(alignment: .leading, spacing: 10) {
            TextField("Meeting title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .disabled(meeting.status.isBusy)
                .onSubmit(commitTitle)
                .onChange(of: meeting.id) { title = meeting.title }

            HStack(spacing: 16) {
                Label {
                    Text(meeting.createdDate, format: .dateTime.month(.wide).day().year())
                } icon: {
                    Image(systemName: "calendar")
                }
                Label {
                    Text(meeting.duration > 0 ? Formatting.duration(meeting.duration) : "Audio saved")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
                Label {
                    Text(meeting.speakers.isEmpty ? "No speakers" : "\(meeting.speakers.count) speakers")
                } icon: {
                    Image(systemName: "person.2")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if meeting.status.isBusy {
                jobProgress
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var jobProgress: some View {
        HStack(spacing: 12) {
            ProgressView(
                value: meeting.progress, total: 100,
                label: {
                    Text(meeting.status == .transcribing ? "Transcribing" : "Summarizing")
                        .font(.caption.weight(.medium))
                },
                currentValueLabel: {
                    Text(meeting.stage.isEmpty ? "Preparing…" : meeting.stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            )
            if meeting.status == .transcribing {
                Button("Stop") { Task { await model.cancelTranscription(meeting.id) } }
                    .controlSize(.small)
                    .disabled(meeting.stage == "Stopping transcription…")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
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
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(meeting.status.isBusy)

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(meeting.status.isBusy)
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
                SummaryTab(meeting: meeting, requestSummary: { consenting = true })
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
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Set Up Transcription") { openSettings() }
                        .buttonStyle(.borderedProminent)
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

    private func commitTitle() {
        guard let cleaned = try? Validation.title(title), cleaned != meeting.title else {
            title = meeting.title
            return
        }
        Task { await model.edit(meeting.id) { $0.title = cleaned } }
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
