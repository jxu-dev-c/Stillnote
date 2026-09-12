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
    @State private var newSpeakerName = ""
    @State private var copied = false

    private var filtered: [Segment] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return meeting.segments }
        return meeting.segments.filter {
            "\(meeting.speakerName($0.speaker)) \($0.text)".lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript").font(.headline)
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

            if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(filtered) { segment in
                    row(segment)
                }
            }
        }
        .inspector(isPresented: .constant(true)) {
            speakerPanel
                .inspectorColumnWidth(min: 180, ideal: 220, max: 300)
        }
        .sheet(item: $editing) { segment in
            SegmentEditor(meeting: meeting, segment: segment)
        }
        .alert("Rename speaker", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Speaker name", text: $newSpeakerName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save Name") { commitRename() }
        } message: {
            Text("Renaming this speaker clears the current summary.")
        }
    }

    private func row(_ segment: Segment) -> some View {
        let active = player.map { $0.currentTime >= segment.start && $0.currentTime < segment.end } ?? false
        return HStack(alignment: .top, spacing: 10) {
            Button {
                beginRename(segment.speaker)
            } label: {
                SpeakerAvatar(
                    name: meeting.speakerName(segment.speaker),
                    color: SpeakerTint.color(for: segment.speaker, in: meeting)
                )
            }
            .buttonStyle(.plain)
            .help("Rename speaker")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button(meeting.speakerName(segment.speaker)) { beginRename(segment.speaker) }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                    Button(Formatting.timestamp(segment.start)) { player?.play(from: segment.start) }
                        .buttonStyle(.link)
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button { editing = segment } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit segment")
                        .disabled(meeting.status.isBusy)
                }
                Text(segment.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(active ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6))
    }

    private var speakerPanel: some View {
        List {
            Section("Speakers") {
                ForEach(meeting.orderedSpeakerIDs(), id: \.self) { id in
                    HStack(spacing: 8) {
                        SpeakerAvatar(
                            name: meeting.speakerName(id),
                            color: SpeakerTint.color(for: id, in: meeting), size: 22
                        )
                        Text(meeting.speakerName(id)).lineLimit(1)
                        Spacer()
                        Button { beginRename(id) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .disabled(meeting.status.isBusy)
                    }
                }
            }
        }
    }

    private func beginRename(_ id: String) {
        newSpeakerName = meeting.speakerName(id)
        renaming = id
    }

    private func commitRename() {
        guard let id = renaming, let name = try? Validation.speakerName(newSpeakerName) else {
            renaming = nil
            return
        }
        renaming = nil
        Task { await model.editTranscript(meeting.id) { $0.speakers[id] = name } }
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
