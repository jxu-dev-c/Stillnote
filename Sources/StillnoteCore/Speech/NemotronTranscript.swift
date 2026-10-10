import Foundation

/// Turns the Nemotron pair's output — words from the recognizer, a speaker timeline from the
/// diarizer — into the transcript the rest of the app already understands.
///
/// This replaces `MossParser` and deliberately keeps its contract: stable `speaker_n` ids
/// numbered by first appearance, `Speaker N` display names, `segment_n` ids, timestamps shifted
/// by a removed silent head and clamped to the stored recording, and millisecond rounding.
/// What changes is the input: structured values instead of a text grammar, so a truncated
/// generation is no longer a thing that can be misread as content.
public enum NemotronTranscript {
    /// Punctuation that ends a sentence, including the full-width forms Nemotron emits for
    /// Chinese and Japanese.
    private static let sentenceEnders: Set<Character> = [
        ".", "!", "?", "。", "！", "？", "…",
    ]

    /// Characters that must not be preceded by a space when words are joined.
    private static let leadingNoSpace: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "%", "'", "\u{2019}", "\u{201D}",
        "，", "。", "！", "？", "；", "：", "、", "）", "】", "」", "』",
    ]

    /// Characters that must not be followed by a space.
    private static let trailingNoSpace: Set<Character> = [
        "(", "[", "{", "\u{2018}", "\u{201C}", "（", "【", "「", "『",
    ]

    /// `offset` puts timestamps back on the stored recording's timeline when the audio the
    /// models saw had its silent head removed. Clamping still uses the full `duration`, so the
    /// result stays inside the recording the player seeks through.
    public static func build(
        words: [TranscribedWord], activity: [SpeakerActivity], duration: Double,
        language: String, offset: Double = 0, options: SpeakerAttribution.Options = .init()
    ) throws -> TranscriptionResult {
        let usable = try validated(words)
        guard !usable.isEmpty else {
            return TranscriptionResult(
                duration: rounded(duration), language: language.isEmpty ? "auto" : language,
                speakers: [:], segments: []
            )
        }
        let attributed = SpeakerAttribution.attribute(
            words: usable, activity: activity, options: options
        )

        var labels: [Int: String] = [:]
        var order: [String] = []
        var segments: [Segment] = []
        for run in runs(attributed, options: options) {
            let text = joined(run.map(\.word.text))
            if text.isEmpty { continue }
            let channel = run.first?.speaker
            let label: String
            if let channel {
                if let existing = labels[channel] {
                    label = existing
                } else {
                    label = "speaker_\(labels.count + 1)"
                    labels[channel] = label
                    order.append(label)
                }
            } else {
                label = "speaker_unknown"
                if !order.contains(label) { order.append(label) }
            }
            let start = run.map(\.word.start).min() ?? 0
            let end = run.map(\.word.end).max() ?? start
            segments.append(
                Segment(
                    id: "segment_\(segments.count + 1)",
                    start: rounded(max(0, min(start + offset, duration))),
                    end: rounded(max(0, min(end + offset, duration))),
                    speaker: label,
                    text: text
                )
            )
        }

        var speakers: [String: String] = [:]
        var number = 0
        for label in order {
            if label == "speaker_unknown" {
                speakers[label] = "Unknown speaker"
            } else {
                number += 1
                speakers[label] = "Speaker \(number)"
            }
        }
        return TranscriptionResult(
            duration: rounded(duration), language: language.isEmpty ? "auto" : language,
            speakers: speakers, segments: segments
        )
    }

    /// Rejects word timings that cannot be placed on a timeline. `MossParser` threw on output
    /// that did not match its grammar; the equivalent here is a time we cannot trust, because
    /// a transcript with nonsense timestamps desynchronizes the player silently.
    private static func validated(_ words: [TranscribedWord]) throws -> [TranscribedWord] {
        var usable: [TranscribedWord] = []
        usable.reserveCapacity(words.count)
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start, word.start >= 0
            else {
                throw SpeechError.message(
                    "The model returned invalid timestamps. Please retry transcription."
                )
            }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            usable.append(TranscribedWord(text: text, start: word.start, end: word.end))
        }
        return usable
    }

    /// Groups consecutive words into the runs that become segments.
    static func runs(
        _ words: [SpeakerAttribution.AttributedWord], options: SpeakerAttribution.Options
    ) -> [[SpeakerAttribution.AttributedWord]] {
        var runs: [[SpeakerAttribution.AttributedWord]] = []
        var current: [SpeakerAttribution.AttributedWord] = []
        for word in words {
            guard let last = current.last else {
                current = [word]
                continue
            }
            let speakerChanged = last.speaker != word.speaker
            let gap = word.word.start - last.word.end
            let runStart = current.first?.word.start ?? word.word.start
            let longEnough = last.word.end - runStart >= options.targetSegmentSeconds
            let endsSentence = last.word.text.last.map(sentenceEnders.contains) ?? false
            if speakerChanged || gap >= options.maxGap || (longEnough && endsSentence) {
                runs.append(current)
                current = [word]
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Joins words into readable text. Nemotron strips SentencePiece's word marker, so words
    /// arrive without their leading space; punctuation attaches to the word it follows, and
    /// scripts that do not separate words with spaces must not gain them.
    static func joined(_ words: [String]) -> String {
        var text = ""
        for word in words {
            guard let first = word.first else { continue }
            if text.isEmpty {
                text = word
                continue
            }
            let previous = text.last
            let needsSpace = !leadingNoSpace.contains(first)
                && !isUnspaced(first)
                && !(previous.map(isUnspaced) ?? false)
                && !(previous.map(trailingNoSpace.contains) ?? false)
            text += needsSpace ? " " + word : word
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scripts written without spaces between words. Hangul is excluded on purpose: Korean
    /// does separate words with spaces.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,  // CJK symbols and punctuation
             0x3040...0x30FF,  // Hiragana, Katakana
             0x3400...0x4DBF,  // CJK extension A
             0x4E00...0x9FFF,  // CJK unified ideographs
             0xF900...0xFAFF,  // CJK compatibility ideographs
             0xFF00...0xFF65,  // full-width forms
             0x20000...0x2FA1F:  // CJK extensions B and beyond
            return true
        default:
            return false
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
