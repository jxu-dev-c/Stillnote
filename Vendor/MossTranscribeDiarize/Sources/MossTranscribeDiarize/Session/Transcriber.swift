import Foundation
@preconcurrency import MLX
import MLXAudioCore
import Observation

/// High-level async transcription session for SwiftUI / app code.
/// Covers load → transcribe → postprocess → export → optional ffmpeg burn-in.
@MainActor
@Observable
public final class Transcriber {
    public private(set) var isLoadingModel = false
    public private(set) var isTranscribing = false
    public private(set) var modelID: String?
    public private(set) var statusMessage = "Ready"
    public private(set) var lastError: String?
    public private(set) var result: TranscribeResult?
    public private(set) var streamedText = ""
    public private(set) var liveSegments: [TranscriptSegment] = []
    public private(set) var subtitleSegments: [SubtitleSegment] = []
    public private(set) var lastArtifacts: PipelineArtifacts?

    public var parameters = GenerateParameters()
    public var postprocessSubtitles = false
    public var burnSubtitles = false

    @ObservationIgnored
    private var model: MossModel?

    @ObservationIgnored
    private var streamTask: Task<Void, Never>?

    public init() {}

    public var isModelLoaded: Bool { model != nil }

    public var segments: [TranscriptSegment] {
        result?.segments ?? liveSegments
    }

    // MARK: - Load

    public func load(modelPath: String = MossDefaults.recommendedModel) async {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        lastError = nil
        statusMessage = "Loading model…"
        defer { isLoadingModel = false }

        do {
            let loaded = try await ModelLoader.load(modelPath)
            model = loaded
            modelID = modelPath
            statusMessage = "Model ready"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Load failed"
            model = nil
            modelID = nil
        }
    }

    public func unload() {
        streamTask?.cancel()
        streamTask = nil
        model = nil
        modelID = nil
        result = nil
        streamedText = ""
        liveSegments = []
        subtitleSegments = []
        lastArtifacts = nil
        statusMessage = "Ready"
    }

    // MARK: - Transcribe

    /// Full pipeline to an output directory (raw + JSON/SRT/ASS + optional MP4).
    public func runPipeline(audioURL: URL, outDirectory: URL) async {
        guard let model else {
            lastError = MossError.notLoaded.localizedDescription
            return
        }
        guard !isTranscribing else { return }
        isTranscribing = true
        lastError = nil
        statusMessage = "Running pipeline…"
        defer { isTranscribing = false }

        do {
            let options = PipelineOptions(
                parameters: parameters,
                postprocessSubtitles: postprocessSubtitles,
                burnSubtitles: burnSubtitles
            )
            let artifacts = try TranscribePipeline(model: model).run(
                inputURL: audioURL,
                outDirectory: outDirectory,
                options: options
            )
            lastArtifacts = artifacts
            result = artifacts.result
            streamedText = artifacts.result.text
            liveSegments = artifacts.result.segments
            subtitleSegments = artifacts.subtitleSegments
            statusMessage = String(
                format: "Done · %d segs · %.1fs · %.1f tok/s",
                artifacts.subtitleSegments.count,
                artifacts.result.totalTime,
                artifacts.result.generationTokensPerSecond
            )
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Failed"
        }
    }

    public func transcribe(audioURL: URL, stream: Bool = false) async {
        guard let model else {
            lastError = MossError.notLoaded.localizedDescription
            return
        }
        guard !isTranscribing else { return }

        isTranscribing = true
        lastError = nil
        result = nil
        streamedText = ""
        liveSegments = []
        subtitleSegments = []
        statusMessage = "Loading audio…"
        defer { isTranscribing = false }

        do {
            if stream {
                let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: model.sampleRate)
                try await runStreaming(model: model, audio: audio)
            } else {
                statusMessage = "Transcribing…"
                let output = try model.generate(fileURL: audioURL, parameters: parameters)
                apply(output: output)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Failed"
        }
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isTranscribing = false
        statusMessage = "Cancelled"
    }

    public func exportSubtitles(
        format: SubtitleFormat,
        to directory: URL,
        basename: String = "subtitle"
    ) throws -> URL {
        let cues = subtitleSegments.isEmpty
            ? SubtitlePostprocess.subtitleSegments(
                from: segments,
                postprocess: postprocessSubtitles
            )
            : subtitleSegments
        let text: String
        let filename: String
        switch format {
        case .json:
            text = try SubtitleExport.exportJSON(cues)
            filename = "\(basename).json"
        case .srt:
            text = SubtitleExport.exportSRT(cues)
            filename = "\(basename).srt"
        case .ass:
            text = SubtitleExport.exportASS(cues)
            filename = "\(basename).ass"
        }
        let url = directory.appendingPathComponent(filename)
        try SubtitleExport.write(text, to: url)
        statusMessage = "Exported \(url.lastPathComponent)"
        return url
    }

    public func burnIn(inputMedia: URL, assURL: URL, outputURL: URL) throws -> URL {
        let url = try FFmpegTools.burnASSSubtitles(
            inputMedia: inputMedia,
            assURL: assURL,
            outputURL: outputURL
        )
        statusMessage = "Rendered \(url.lastPathComponent)"
        return url
    }

    public func setError(_ message: String) {
        lastError = message
        statusMessage = "Failed"
    }

    // MARK: - Private

    private func apply(output: TranscribeResult) {
        result = output
        streamedText = output.text
        liveSegments = output.segments
        subtitleSegments = SubtitlePostprocess.subtitleSegments(
            from: output.segments,
            postprocess: postprocessSubtitles
        )
        statusMessage = String(
            format: "Done · %.1fs · %.1f tok/s",
            output.totalTime,
            output.generationTokensPerSecond
        )
    }

    private func runStreaming(model: MossModel, audio: MLXArray) async throws {
        statusMessage = "Streaming…"
        let parser = TranscriptStreamParser()
        var finished: TranscribeResult?

        for try await event in model.generateStream(audio: audio, parameters: parameters) {
            try Task.checkCancellation()
            switch event {
            case .token(let piece):
                streamedText += piece
                let newSegments = parser.feed(piece)
                if !newSegments.isEmpty {
                    liveSegments.append(contentsOf: newSegments)
                }
            case .finished(let output):
                let trailing = parser.close()
                if !trailing.isEmpty {
                    liveSegments.append(contentsOf: trailing)
                }
                finished = output
            }
        }

        if let finished {
            if liveSegments.isEmpty {
                liveSegments = finished.segments
            }
            apply(output: finished)
        }
    }
}
