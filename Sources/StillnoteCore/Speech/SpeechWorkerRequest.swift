import Foundation

/// Validated native worker input. Paths are passed as argv values, never through a shell.
public struct SpeechWorkerRequest: Sendable {
    public let pcmURL: URL
    public let modelURL: URL
    public let prompt: String
    public let mode: TranscriptionMode

    public init(arguments: [String]) throws {
        guard (4...6).contains(arguments.count) else {
            throw SpeechError.message("The speech worker was started with unexpected arguments.")
        }
        if arguments.count == 6 {
            guard let value = TranscriptionMode(rawValue: arguments[5]) else { throw SpeechError.message("Unknown transcription mode.") }
            mode = value
        } else { mode = .quality }
        pcmURL = URL(fileURLWithPath: arguments[0])
        modelURL = URL(fileURLWithPath: arguments[1])
        let language = try Validation.language(arguments[2].isEmpty ? "auto" : arguments[2])
        guard let count = Int(arguments[3]), count == 0 || Validation.speakerCountRange.contains(count) else {
            throw SpeechError.message("Speaker count must be between 1 and 20, or automatic.")
        }
        let words = arguments.count >= 5
            ? TranscriptionSettings.normalizeHotWords(try JSONDecoder().decode([String].self, from: Data(arguments[4].utf8)))
            : []
        var value = "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"
        if language != "auto" { value += " Audio language: \(language)." }
        if count != 0 { value += " Expected speakers: \(count)." }
        if !words.isEmpty { value += " 热词提示：" + words.joined(separator: ", ") }
        prompt = value
    }

    public static func tokenBudget(duration: Double) -> Int {
        min(65536, max(2048, Int(ceil(duration * 16)) + 512))
    }
}
