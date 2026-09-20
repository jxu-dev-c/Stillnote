import Foundation
@preconcurrency import MLX
import MLXAudioCore

public struct BenchmarkSample: Sendable, Equatable, Codable {
    public var id: String
    public var audio: String
    public var expectedText: String?
    public var expectedSpeakers: Int?
    public var prompt: String?

    public init(
        id: String,
        audio: String,
        expectedText: String? = nil,
        expectedSpeakers: Int? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.audio = audio
        self.expectedText = expectedText
        self.expectedSpeakers = expectedSpeakers
        self.prompt = prompt
    }
}

public struct BenchmarkResult: Sendable, Equatable, Codable {
    public var id: String
    public var audio: String
    public var text: String
    public var segments: Int
    public var speakers: Int
    public var audioDurationSec: Double
    public var elapsedSec: Double
    public var rtf: Double
    public var promptTokens: Int
    public var generatedTokens: Int
    public var generationTps: Double
    public var expectedText: String?
    public var normalizedTextMatch: Bool?
    public var expectedSpeakers: Int?
    public var speakerCountMatch: Bool?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id, audio, text, segments, speakers
        case audioDurationSec = "audio_duration_sec"
        case elapsedSec = "elapsed_sec"
        case rtf
        case promptTokens = "prompt_tokens"
        case generatedTokens = "generated_tokens"
        case generationTps = "generation_tps"
        case expectedText = "expected_text"
        case normalizedTextMatch = "normalized_text_match"
        case expectedSpeakers = "expected_speakers"
        case speakerCountMatch = "speaker_count_match"
        case error
    }
}

/// SGLang Omni-shaped local benchmark (raw / speed / evaluation JSON).
public enum BenchmarkRunner {
    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "flac", "mp3", "m4a", "ogg", "mp4", "mov", "mkv",
    ]

    public static func loadSamples(from inputURL: URL) throws -> [BenchmarkSample] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw MossError.invalidAudio("Benchmark input not found: \(inputURL.path)")
        }

        if isDir.boolValue {
            let files = try FileManager.default.contentsOfDirectory(
                at: inputURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { BenchmarkSample(id: $0.deletingPathExtension().lastPathComponent, audio: $0.path) }
        }

        switch inputURL.pathExtension.lowercased() {
        case "json":
            let data = try Data(contentsOf: inputURL)
            let object = try JSONSerialization.jsonObject(with: data)
            let rows: [[String: Any]]
            if let dict = object as? [String: Any], let samples = dict["samples"] as? [[String: Any]] {
                rows = samples
            } else if let array = object as? [[String: Any]] {
                rows = array
            } else {
                throw MossError.invalidAudio("Unsupported JSON benchmark format.")
            }
            return try rows.map { try sample(from: $0, base: inputURL.deletingLastPathComponent()) }
        case "jsonl":
            let text = try String(contentsOf: inputURL, encoding: .utf8)
            return try text.split(whereSeparator: \.isNewline).compactMap { line -> BenchmarkSample? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let row = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return try sample(from: row, base: inputURL.deletingLastPathComponent())
            }
        case "csv":
            return try loadCSV(inputURL)
        default:
            throw MossError.invalidAudio("Unsupported benchmark input: \(inputURL.path)")
        }
    }

    public static func run(
        model: MossModel,
        samples: [BenchmarkSample],
        outDirectory: URL,
        parameters: GenerateParameters = GenerateParameters(),
        keepGoing: Bool = true
    ) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        var results: [BenchmarkResult] = []

        for sample in samples {
            let audioURL = URL(fileURLWithPath: sample.audio)
            let started = Date()
            do {
                var params = parameters
                if let prompt = sample.prompt { params.prompt = prompt }
                let output = try model.generate(fileURL: audioURL, parameters: params)
                results.append(
                    evaluate(sample: sample, output: output, elapsed: Date().timeIntervalSince(started))
                )
            } catch {
                let duration = (try? audioDuration(at: audioURL)) ?? 0
                results.append(
                    BenchmarkResult(
                        id: sample.id,
                        audio: sample.audio,
                        text: "",
                        segments: 0,
                        speakers: 0,
                        audioDurationSec: duration,
                        elapsedSec: Date().timeIntervalSince(started),
                        rtf: 0,
                        promptTokens: 0,
                        generatedTokens: 0,
                        generationTps: 0,
                        expectedText: sample.expectedText,
                        expectedSpeakers: sample.expectedSpeakers,
                        error: "\(error)"
                    )
                )
                if !keepGoing { throw error }
            }
        }

        let summary = summarize(results)
        let speed: [String: Any] = [
            "backend": "mlx-swift",
            "samples": summary["samples"] as Any,
            "succeeded": summary["succeeded"] as Any,
            "failed": summary["failed"] as Any,
            "total_audio_duration_sec": summary["total_audio_duration_sec"] as Any,
            "total_elapsed_sec": summary["total_elapsed_sec"] as Any,
            "aggregate_rtf": summary["aggregate_rtf"] as Any,
            "mean_rtf": summary["mean_rtf"] as Any,
            "mean_generation_tps": summary["mean_generation_tps"] as Any,
            "text_exact_match": summary["text_exact_match"] as Any,
            "speaker_count_accuracy": summary["speaker_count_accuracy"] as Any,
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let rawData = try encoder.encode(results)
        try rawData.write(to: outDirectory.appendingPathComponent("raw_asr_results.json"))

        let speedData = try JSONSerialization.data(withJSONObject: speed, options: [.prettyPrinted, .sortedKeys])
        try speedData.write(to: outDirectory.appendingPathComponent("speed_results.json"))

        let payload: [String: Any] = ["speed": speed, "results": try JSONSerialization.jsonObject(with: rawData)]
        let evalData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try evalData.write(to: outDirectory.appendingPathComponent("evaluation.json"))

        return payload
    }

    // MARK: - Internals

    private static func sample(from row: [String: Any], base: URL) throws -> BenchmarkSample {
        guard let audio = row["audio"] as? String
            ?? row["audio_path"] as? String
            ?? row["path"] as? String
            ?? row["file"] as? String
        else {
            throw MossError.invalidAudio("Sample missing audio path: \(row)")
        }
        let expandedAudio = (audio as NSString).expandingTildeInPath
        let audioURL: URL
        if (expandedAudio as NSString).isAbsolutePath {
            audioURL = URL(fileURLWithPath: expandedAudio)
        } else {
            audioURL = base.appendingPathComponent(expandedAudio)
        }
        let speakersValue = row["expected_speakers"] ?? row["speakers"]
        let expectedSpeakers: Int?
        if let number = speakersValue as? Int {
            expectedSpeakers = number
        } else if let string = speakersValue as? String, let number = Int(string) {
            expectedSpeakers = number
        } else {
            expectedSpeakers = nil
        }
        return BenchmarkSample(
            id: (row["id"] as? String) ?? audioURL.deletingPathExtension().lastPathComponent,
            audio: audioURL.path,
            expectedText: (row["expected_text"] as? String) ?? (row["text"] as? String),
            expectedSpeakers: expectedSpeakers,
            prompt: row["prompt"] as? String
        )
    }

    private static func loadCSV(_ url: URL) throws -> [BenchmarkSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = headerLine.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return try lines.dropFirst().compactMap { line -> BenchmarkSample? in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard cols.count == headers.count else { return nil }
            var row: [String: Any] = [:]
            for (header, value) in zip(headers, cols) {
                row[header] = value
            }
            return try sample(from: row, base: url.deletingLastPathComponent())
        }
    }

    private static func evaluate(
        sample: BenchmarkSample,
        output: TranscribeResult,
        elapsed: TimeInterval
    ) -> BenchmarkResult {
        let duration = (try? audioDuration(at: URL(fileURLWithPath: sample.audio))) ?? 0
        let speakers = Set(output.segments.map(\.speaker))
        var textMatch: Bool?
        if let expected = sample.expectedText {
            let hypothesis = output.segments.isEmpty
                ? output.text
                : output.segments.map(\.text).joined(separator: " ")
            textMatch = normalize(hypothesis) == normalize(expected)
        }
        var speakerMatch: Bool?
        if let expected = sample.expectedSpeakers {
            speakerMatch = speakers.count == expected
        }
        return BenchmarkResult(
            id: sample.id,
            audio: sample.audio,
            text: output.text,
            segments: output.segments.count,
            speakers: speakers.count,
            audioDurationSec: duration,
            elapsedSec: elapsed,
            rtf: duration > 0 ? elapsed / duration : 0,
            promptTokens: output.promptTokens,
            generatedTokens: output.generationTokens,
            generationTps: output.generationTokensPerSecond,
            expectedText: sample.expectedText,
            normalizedTextMatch: textMatch,
            expectedSpeakers: sample.expectedSpeakers,
            speakerCountMatch: speakerMatch
        )
    }

    private static func summarize(_ results: [BenchmarkResult]) -> [String: Any] {
        let ok = results.filter { $0.error == nil }
        let totalAudio = ok.map(\.audioDurationSec).reduce(0, +)
        let totalElapsed = ok.map(\.elapsedSec).reduce(0, +)
        let textScored = ok.compactMap(\.normalizedTextMatch)
        let speakerScored = ok.compactMap(\.speakerCountMatch)
        return [
            "samples": results.count,
            "succeeded": ok.count,
            "failed": results.count - ok.count,
            "total_audio_duration_sec": totalAudio,
            "total_elapsed_sec": totalElapsed,
            "aggregate_rtf": totalAudio > 0 ? totalElapsed / totalAudio : 0,
            "mean_rtf": ok.isEmpty ? 0 : ok.map(\.rtf).reduce(0, +) / Double(ok.count),
            "mean_generation_tps": ok.isEmpty ? 0 : ok.map(\.generationTps).reduce(0, +) / Double(ok.count),
            "text_exact_match": textScored.isEmpty
                ? NSNull()
                : Double(textScored.filter { $0 }.count) / Double(textScored.count),
            "speaker_count_accuracy": speakerScored.isEmpty
                ? NSNull()
                : Double(speakerScored.filter { $0 }.count) / Double(speakerScored.count),
        ]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func audioDuration(at url: URL) throws -> Double {
        if FFmpegTools.detect().ffprobe != nil,
           let media = try? FFmpegTools.probeMedia(at: url),
           let format = media["format"] as? [String: Any],
           let durationString = format["duration"] as? String,
           let duration = Double(durationString) {
            return duration
        }
        let (sampleRate, audio) = try loadAudioArray(from: url, sampleRate: 16_000)
        let samples = max(audio.dim(0), 1)
        return Double(samples) / Double(max(sampleRate, 1))
    }
}
