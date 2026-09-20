import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Full-featured SwiftUI studio: model, prompt/hotwords, postprocess, export, burn-in.
public struct TranscribeView: View {
    @State private var transcriber = Transcriber()
    @State private var selectedVariant: ModelVariant = .int8
    @State private var customModelPath = ""
    @State private var isImporterPresented = false
    @State private var selectedAudioURL: URL?
    @State private var useStreaming = false
    @State private var hotwordsText = ""
    @State private var promptText = MossDefaults.prompt
    @State private var lastExportURL: URL?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                modelSection
                audioSection
                generationSection
                actionSection
                statusSection
                if !transcriber.segments.isEmpty {
                    segmentsSection
                }
            }
            .navigationTitle("MOSS Transcribe")
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.audio, .movie, .mpeg4Movie],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result {
                    selectedAudioURL = urls.first
                }
            }
        }
    }

    // MARK: - Sections

    private var modelSection: some View {
        Section("Model") {
            Picker("Variant", selection: $selectedVariant) {
                ForEach(ModelVariant.allCases) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            .accessibilityLabel("Model variant")

            Text(selectedVariant.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Or local path / custom HF repo", text: $customModelPath)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            Button {
                Task {
                    let path = customModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    await transcriber.load(modelPath: path.isEmpty ? selectedVariant.repositoryID : path)
                }
            } label: {
                if transcriber.isLoadingModel {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label(
                        transcriber.isModelLoaded ? "Reload Model" : "Load Model",
                        systemImage: "arrow.down.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(transcriber.isLoadingModel || transcriber.isTranscribing)
            .buttonStyle(.borderedProminent)
        }
    }

    private var audioSection: some View {
        Section("Audio / Video") {
            Button {
                isImporterPresented = true
            } label: {
                Label(
                    selectedAudioURL?.lastPathComponent ?? "Choose Media File",
                    systemImage: "waveform"
                )
            }
            .accessibilityHint("Opens a file picker for audio or video")

            LabeledContent("FFmpeg") {
                Text(FFmpegTools.detect().isAvailable ? "Available" : "Missing")
                    .foregroundStyle(FFmpegTools.detect().isAvailable ? .green : .orange)
            }
        }
    }

    private var generationSection: some View {
        Section("Generation") {
            TextField("Prompt", text: $promptText, axis: .vertical)
                .lineLimit(3...8)
            TextField("Hotwords (comma-separated)", text: $hotwordsText)
            Toggle("Stream tokens", isOn: $useStreaming)
            Toggle("Postprocess subtitles", isOn: $transcriber.postprocessSubtitles)
            Toggle("Burn ASS into MP4", isOn: $transcriber.burnSubtitles)
                .disabled(!FFmpegTools.detect().isAvailable)
            Stepper(
                "Max tokens: \(transcriber.parameters.maxTokens)",
                value: $transcriber.parameters.maxTokens,
                in: 64...16_384,
                step: 256
            )
        }
    }

    private var actionSection: some View {
        Section("Run") {
            Button {
                guard let selectedAudioURL else { return }
                syncParameters()
                Task {
                    if transcriber.burnSubtitles || !useStreaming {
                        let out = FileManager.default.temporaryDirectory
                            .appendingPathComponent("moss-\(UUID().uuidString.prefix(8))", isDirectory: true)
                        await transcriber.runPipeline(audioURL: selectedAudioURL, outDirectory: out)
                    } else {
                        await transcriber.transcribe(audioURL: selectedAudioURL, stream: true)
                    }
                }
            } label: {
                if transcriber.isTranscribing {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Transcribe", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!transcriber.isModelLoaded || selectedAudioURL == nil || transcriber.isTranscribing)
            .buttonStyle(.borderedProminent)

            if transcriber.isTranscribing {
                Button("Cancel", role: .destructive) {
                    transcriber.cancel()
                }
            }

            if !transcriber.segments.isEmpty {
                Menu {
                    Button("Export JSON") { export(.json) }
                    Button("Export SRT") { export(.srt) }
                    Button("Export ASS") { export(.ass) }
                } label: {
                    Label("Export Subtitles", systemImage: "square.and.arrow.up")
                }
            }

            if let artifacts = transcriber.lastArtifacts {
                LabeledContent("Output") {
                    Text(artifacts.outDirectory.lastPathComponent)
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("State", value: transcriber.statusMessage)
            if let modelID = transcriber.modelID {
                LabeledContent("Model", value: modelID)
            }
            if let error = transcriber.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if !transcriber.streamedText.isEmpty && transcriber.isTranscribing {
                Text(transcriber.streamedText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
    }

    private var segmentsSection: some View {
        Section("Segments (\(transcriber.segments.count))") {
            ForEach(transcriber.segments) { segment in
                SegmentRowView(segment: segment)
            }
        }
    }

    // MARK: - Helpers

    private func syncParameters() {
        transcriber.parameters.prompt = promptText
        transcriber.parameters.hotwords = hotwordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func export(_ format: SubtitleFormat) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moss-transcribe-export", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try transcriber.exportSubtitles(format: format, to: directory)
            lastExportURL = url
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
        } catch {
            transcriber.setError(error.localizedDescription)
        }
    }
}

#Preview {
    TranscribeView()
}
