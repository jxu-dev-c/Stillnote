import StillnoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    @State private var url: URL?
    @State private var title = ""
    @State private var language = "auto"
    @State private var speakerCount: Int?
    @State private var choosing = false
    @State private var saving = false
    @State private var initialized = false

    // The formats AVFoundation can decode on macOS. WebM and Ogg are not among them.
    static let contentTypes: [UTType] = [
        .audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie,
        UTType(filenameExtension: "flac") ?? .audio, UTType(filenameExtension: "caf") ?? .audio,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Audio").font(.title2.weight(.semibold))

            Button { choosing = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: url == nil ? "square.and.arrow.down" : "waveform")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(url?.lastPathComponent ?? "Choose a file or drop one here")
                        .lineLimit(1)
                    Text("WAV, MP3, M4A, AAC, FLAC, AIFF, MP4, MOV · up to 2 GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .contentPanel()
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { items, _ in
                guard let dropped = items.first else { return false }
                select(dropped)
                return true
            }

            Form {
                TextField("Title", text: $title)
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
            }
            .formStyle(.grouped)
            .frame(height: 130)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(saving ? "Saving…" : "Import") { Task { await save() } }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || saving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            guard !initialized else { return }
            language = model.settings.transcription.language
            speakerCount = model.settings.transcription.speakerCount
            initialized = true
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.contentTypes) { result in
            if case .success(let picked) = result { select(picked) }
        }
    }

    private func select(_ picked: URL) {
        url = picked
        if title.isEmpty { title = picked.deletingPathExtension().lastPathComponent }
    }

    private func save() async {
        guard let url else { return }
        saving = true
        defer { saving = false }
        // A file chosen through the panel is security-scoped; the copy happens inside.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let meeting = await model.importRecording(
            from: url, title: title.isEmpty ? url.lastPathComponent : title,
            language: language, speakerCount: speakerCount
        ) else { return }
        selection = meeting.id
        dismiss()
        if model.speech.ready {
            await model.transcribe(meeting.id)
        }
    }
}
