import Foundation

/// Validated native worker input for the Nemotron engine.
///
/// The MOSS protocol was positional argv. This pair needs two model directories, a locale, a
/// speaker cap, hot words, and a geometry, so it travels as one JSON argument instead —
/// still an argv value handed to `Process`, never a shell string.
public struct NemotronWorkerRequest: Codable, Hashable, Sendable {
    /// Diarization chunk geometry, in the diarizer's 80 ms encoder frames.
    ///
    /// `offline` is the quality configuration: 340 core frames with 40 of lookahead confirms
    /// 27.2 s of speech per call. `live` is the low-latency configuration, about 1.04 s of
    /// input latency, which is what the preview during recording can afford.
    public enum Geometry: String, Codable, Sendable {
        case offline
        case live

        public var coreEncoderFrames: Int { self == .offline ? 340 : 6 }
        public var rightContextEncoderFrames: Int { self == .offline ? 40 : 7 }
    }

    /// The diarizer predicts eight arrival-ordered channels and cannot be asked for more.
    public static let maxSpeakers = 8

    public var asrModelPath: String
    public var diarizerModelPath: String
    /// Raw 16 kHz mono float32. `nil` in `live` mode, where audio arrives on stdin.
    public var pcmPath: String?
    /// A BCP-47 locale such as `en-US`, or `auto`.
    public var language: String
    /// Expected speakers, clamped to `maxSpeakers`. `nil` lets the diarizer decide.
    public var speakerCount: Int?
    public var hotWords: [String]
    public var geometry: Geometry

    public init(
        asrModelPath: String, diarizerModelPath: String, pcmPath: String?, language: String,
        speakerCount: Int?, hotWords: [String], geometry: Geometry
    ) {
        self.asrModelPath = asrModelPath
        self.diarizerModelPath = diarizerModelPath
        self.pcmPath = pcmPath
        self.language = Self.asrLanguage(language)
        self.speakerCount = speakerCount.map { Self.clampSpeakers($0) }
        self.hotWords = TranscriptionSettings.normalizeHotWords(hotWords)
        self.geometry = geometry
    }

    /// Maps a language choice onto a tag the ASR bundle has a prompt slot for.
    ///
    /// The bundle's `languages.json` carries bare codes for most languages (`en`, `de`, `ru`)
    /// but ships Chinese and Japanese only as locales. The runtime's lookup falls back to the
    /// `auto` slot for a tag it does not know, so passing a bare `zh` or `ja` would quietly
    /// drop the language conditioning a user explicitly asked for — the model would still
    /// transcribe, just without the hint. Mapping here keeps that from happening silently.
    static let localeOverrides = ["zh": "zh-CN", "ja": "ja-JP"]

    public static func asrLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "auto" }
        return localeOverrides[trimmed.lowercased()] ?? trimmed
    }

    /// Expected speakers is stored over 1...20 for older settings documents and older CLI
    /// invocations. Silently ignoring a stored 12 would be worse than capping it and saying so,
    /// so the cap is applied here, once, where both the app and the worker can see it.
    public static func clampSpeakers(_ count: Int) -> Int {
        min(max(count, 1), maxSpeakers)
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else {
            throw SpeechError.message("The speech worker was started with unexpected arguments.")
        }
        guard !decoded.asrModelPath.isEmpty, !decoded.diarizerModelPath.isEmpty else {
            throw SpeechError.message("The speech worker was started without a model directory.")
        }
        _ = try Validation.language(decoded.language)
        if let count = decoded.speakerCount, !(1...Self.maxSpeakers).contains(count) {
            throw SpeechError.message(
                "Speaker count must be between 1 and \(Self.maxSpeakers), or automatic."
            )
        }
        if decoded.geometry == .offline, decoded.pcmPath?.isEmpty ?? true {
            throw SpeechError.message("The speech worker was started without audio.")
        }
        self = decoded
    }
}

/// What the worker reports back: the recognizer's words and the diarizer's speaker timeline,
/// unfused. Fusion is `SpeakerAttribution`, which lives in Core so the live preview and the
/// final pass cannot drift apart, and so it stays unit-testable without a model.
public struct NemotronWorkerTranscript: Codable, Hashable, Sendable {
    public var language: String
    public var words: [TranscribedWord]
    public var activity: [SpeakerActivity]

    public init(language: String, words: [TranscribedWord], activity: [SpeakerActivity]) {
        self.language = language
        self.words = words
        self.activity = activity
    }
}
