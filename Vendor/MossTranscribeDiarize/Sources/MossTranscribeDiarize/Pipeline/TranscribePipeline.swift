import Foundation
@preconcurrency import MLX
import MLXAudioCore

/// Options for a full job matching `mtd-mlx` / `mtd-subtitle` outputs.
public struct PipelineOptions: Sendable, Equatable {
    public var parameters: GenerateParameters
    public var postprocessSubtitles: Bool
    public var showSpeakerInSRT: Bool
    public var burnSubtitles: Bool
    public var overwriteRender: Bool

    public init(
        parameters: GenerateParameters = GenerateParameters(),
        postprocessSubtitles: Bool = false,
        showSpeakerInSRT: Bool = true,
        burnSubtitles: Bool = false,
        overwriteRender: Bool = true
    ) {
        self.parameters = parameters
        self.postprocessSubtitles = postprocessSubtitles
        self.showSpeakerInSRT = showSpeakerInSRT
        self.burnSubtitles = burnSubtitles
        self.overwriteRender = overwriteRender
    }
}

/// Artifacts written by a complete transcription job.
public struct PipelineArtifacts: Sendable, Equatable {
    public var outDirectory: URL
    public var rawTranscriptURL: URL
    public var segmentsJSONURL: URL
    public var srtURL: URL
    public var assURL: URL
    public var renderedVideoURL: URL?
    public var result: TranscribeResult
    public var subtitleSegments: [SubtitleSegment]
    public var summary: [String: String]

    public init(
        outDirectory: URL,
        rawTranscriptURL: URL,
        segmentsJSONURL: URL,
        srtURL: URL,
        assURL: URL,
        renderedVideoURL: URL? = nil,
        result: TranscribeResult,
        subtitleSegments: [SubtitleSegment],
        summary: [String: String] = [:]
    ) {
        self.outDirectory = outDirectory
        self.rawTranscriptURL = rawTranscriptURL
        self.segmentsJSONURL = segmentsJSONURL
        self.srtURL = srtURL
        self.assURL = assURL
        self.renderedVideoURL = renderedVideoURL
        self.result = result
        self.subtitleSegments = subtitleSegments
        self.summary = summary
    }
}

/// End-to-end pipeline: load audio → generate → parse → export → optional burn-in.
public struct TranscribePipeline {
    public let model: MossModel

    public init(model: MossModel) {
        self.model = model
    }

    public func run(
        inputURL: URL,
        outDirectory: URL,
        options: PipelineOptions = PipelineOptions()
    ) throws -> PipelineArtifacts {
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

        let result = try model.generate(fileURL: inputURL, parameters: options.parameters)
        let cues = SubtitlePostprocess.subtitleSegments(
            from: result.segments,
            postprocess: options.postprocessSubtitles
        )

        let rawURL = outDirectory.appendingPathComponent("raw_transcript.txt")
        try result.text.write(to: rawURL, atomically: true, encoding: .utf8)

        let jsonURL = outDirectory.appendingPathComponent("segments.json")
        try SubtitleExport.write(try SubtitleExport.exportJSON(cues), to: jsonURL)

        let srtURL = outDirectory.appendingPathComponent("subtitle.srt")
        let srt = SubtitleExport.exportSRT(cues, showSpeaker: options.showSpeakerInSRT)
        // Match Python utf-8-sig for SRT/ASS consumers.
        try writeUTF8BOM(srt, to: srtURL)

        let videoSize = FFmpegTools.probeVideoSize(at: inputURL)
        let assURL = outDirectory.appendingPathComponent("subtitle.ass")
        let ass = SubtitleExport.exportASS(
            cues,
            style: SubtitleStyle(),
            videoWidth: videoSize.width,
            videoHeight: videoSize.height
        )
        try writeUTF8BOM(ass, to: assURL)

        var rendered: URL?
        if options.burnSubtitles {
            let outputMP4 = outDirectory.appendingPathComponent("output.mp4")
            rendered = try FFmpegTools.burnASSSubtitles(
                inputMedia: inputURL,
                assURL: assURL,
                outputURL: outputMP4,
                overwrite: options.overwriteRender
            )
        }

        let summary: [String: String] = [
            "backend": "mlx-swift",
            "input": inputURL.path,
            "model_sample_rate": String(model.sampleRate),
            "out_dir": outDirectory.path,
            "segments": String(cues.count),
            "prompt_tokens": String(result.promptTokens),
            "generation_tokens": String(result.generationTokens),
            "total_time": String(format: "%.4f", result.totalTime),
            "generation_tps": String(format: "%.2f", result.generationTokensPerSecond),
            "raw_transcript": rawURL.path,
            "segments_json": jsonURL.path,
            "srt": srtURL.path,
            "ass": assURL.path,
            "mp4": rendered?.path ?? "",
        ]

        return PipelineArtifacts(
            outDirectory: outDirectory,
            rawTranscriptURL: rawURL,
            segmentsJSONURL: jsonURL,
            srtURL: srtURL,
            assURL: assURL,
            renderedVideoURL: rendered,
            result: result,
            subtitleSegments: cues,
            summary: summary
        )
    }

    private func writeUTF8BOM(_ text: String, to url: URL) throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
