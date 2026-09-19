import StillnoteCore
import SwiftUI

struct TranscriptTab: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let player: PlayerModel?
    let retranscribe: () -> Void

    @State private var search = ""
    @State private var editing: Segment?
    @State private var renaming: String?
    @State private var copied = false

    private var filtered: [Segment] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return meeting.segments }
        return meeting.segments.filter {
            "\(meeting.speakerName($0.speaker)) \($0.text)".lowercased().contains(query)
        }
    }

    var body: some View {
        let segments = filtered
        // The meeting owns the ScrollView. Build only the visible transcript rows
        // instead of laying out every selectable text view when switching tabs.
        LazyVStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transcript").font(StillnoteTheme.detailHeadingFont)
                Spacer()
                Button {
                    copyTranscript()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Button(action: retranscribe) {
                    Label("Transcribe Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(meeting.status.isBusy)
            }

            TextField("Search transcript", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityLabel("Search transcript")

            speakerChips

            if segments.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(segments) { segment in
                    TranscriptSegmentRow(
                        segment: segment,
                        speakerName: meeting.speakerName(segment.speaker),
                        speakerColor: SpeakerTint.color(for: segment.speaker, in: meeting),
                        player: player,
                        canEdit: !meeting.status.isBusy,
                        rename: { beginRename(segment.speaker) },
                        edit: { editing = segment }
                    )
                }
            }
        }
        .font(StillnoteTheme.detailBodyFont)
        .sheet(item: $editing) { segment in
            SegmentEditor(meeting: meeting, segment: segment)
        }
        .sheet(isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            if let id = renaming {
                SpeakerEditor(meetingID: meeting.id, speakerID: id)
            }
        }
    }

    /// Speakers sit above the transcript as renameable chips: a panel would have to be
    /// the window's inspector, which belongs to the whole meeting, not this one tab.
    private var speakerChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(meeting.orderedSpeakerIDs(), id: \.self) { id in
            Button { beginRename(id) } label: {
                HStack(spacing: 6) {
                    SpeakerAvatar(
                        name: meeting.speakerName(id),
                        color: SpeakerTint.color(for: id, in: meeting), size: 28
                    )
                    Text(meeting.speakerName(id))
                        .font(StillnoteTheme.detailBodyFont)
                        .lineLimit(1)
                    Image(systemName: "pencil").font(StillnoteTheme.detailSupportingFont).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Edit speaker profile")
            .disabled(meeting.status.isBusy)
        }
    }

    private func beginRename(_ id: String) {
        guard !meeting.status.isBusy else { return }
        renaming = id
    }

    private func copyTranscript() {
        let text = meeting.segments.map {
            "[\(Formatting.timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Observe playback at the row boundary so each timer tick updates highlights
/// without rerunning transcript search or rebuilding all of the other rows.
private struct TranscriptSegmentRow: View {
    let segment: Segment
    let speakerName: String
    let speakerColor: Color
    let player: PlayerModel?
    let canEdit: Bool
    let rename: () -> Void
    let edit: () -> Void

    var body: some View {
        let active = player.map { $0.currentTime >= segment.start && $0.currentTime < segment.end } ?? false
        HStack(alignment: .top, spacing: 10) {
            Button(action: rename) {
                SpeakerAvatar(name: speakerName, color: speakerColor, size: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .help("Edit speaker profile")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(speakerName, action: rename)
                        .disabled(!canEdit)
                        .buttonStyle(.plain)
                        .font(StillnoteTheme.detailBodyFont.weight(.semibold))
                    Button(Formatting.timestamp(segment.start)) { player?.play(from: segment.start) }
                        .buttonStyle(.link)
                        .font(StillnoteTheme.detailSupportingFont.monospacedDigit())
                        .accessibilityLabel("Play from \(Formatting.timestamp(segment.start))")
                    Spacer()
                    Button(action: edit) { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit segment")
                        .disabled(!canEdit)
                }
                Text(segment.text)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(active ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 12))
    }
}

struct SegmentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let segment: Segment

    @State private var text = ""
    @State private var speaker = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit transcript").font(.headline)
            Text("Editing at \(Formatting.timestamp(segment.start)) clears the current summary.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Speaker", selection: $speaker) {
                ForEach(meeting.orderedSpeakerIDs(), id: \.self) { Text(meeting.speakerName($0)).tag($0) }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            text = segment.text
            speaker = segment.speaker
        }
    }

    private func save() {
        dismiss()
        Task {
            await model.editTranscript(meeting.id) { meeting in
                guard let index = meeting.segments.firstIndex(where: { $0.id == segment.id }) else { return }
                meeting.segments[index].text = text
                meeting.segments[index].speaker = speaker
            }
        }
    }
}

/// Re-transcription replaces corrections, so it is confirmed and lets the language and
/// speaker hints be adjusted first.
struct RetranscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    @State private var language = "auto"
    @State private var speakerCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe again").font(.headline)
            Text("Replaces the transcript, corrections, speaker names, and summary. "
                + "Keeps the recording and context.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
            }
            .formStyle(.grouped)
            .frame(height: 100)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Transcribe Again") {
                    dismiss()
                    Task { await model.transcribe(meeting.id, language: language, speakerCount: .some(speakerCount)) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            language = meeting.language.isEmpty ? "auto" : meeting.language
            speakerCount = meeting.speakerCount
        }
    }
}
