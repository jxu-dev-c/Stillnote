import Foundation

/// One word from the recognizer with the span it was decoded over.
///
/// RNN-T emits a word only once its tokens are unambiguous, so these times are
/// emission-aligned rather than force-aligned: a word's span trails its true onset by a
/// small, roughly constant lag. `SpeakerAttribution.Options.emissionLag` compensates.
public struct TranscribedWord: Codable, Hashable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One stretch of audio the diarizer attributed to a speaker channel. Channels are the
/// diarizer's own arrival-ordered slots, not the `speaker_n` ids the rest of the app uses.
public struct SpeakerActivity: Codable, Hashable, Sendable {
    public let speaker: Int
    public let start: Double
    public let end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    var duration: Double { max(0, end - start) }
}

/// Joins a recognizer's words to a diarizer's speaker timeline.
///
/// The previous engine labeled speakers inside one model, so there was nothing to join. Two
/// independent models have to be reconciled on a shared timeline, and this is where that
/// happens: pure value-to-value, no model and no I/O, so it is unit-testable and identical
/// for the live preview and the final pass.
public enum SpeakerAttribution {
    public struct Options: Hashable, Sendable {
        /// Subtracted from every word span before matching. One encoder frame is 80 ms.
        public var emissionLag: Double
        /// The user's Expected speakers setting, already clamped to the diarizer's channels.
        /// `nil` keeps every channel the diarizer reported.
        public var speakerLimit: Int?
        /// A silence at least this long ends a segment even when the speaker has not changed.
        public var maxGap: Double
        /// Once a segment is this long, the next sentence boundary ends it, so a monologue
        /// does not become one unreadable paragraph.
        public var targetSegmentSeconds: Double
        /// A word whose span is degenerate is widened to at least this much, so a one-token
        /// word still overlaps the diarizer's timeline instead of scoring zero everywhere.
        public var minimumWordSpan: Double

        public init(
            emissionLag: Double = 0.08, speakerLimit: Int? = nil, maxGap: Double = 0.7,
            targetSegmentSeconds: Double = 12, minimumWordSpan: Double = 0.04
        ) {
            self.emissionLag = emissionLag
            self.speakerLimit = speakerLimit
            self.maxGap = maxGap
            self.targetSegmentSeconds = targetSegmentSeconds
            self.minimumWordSpan = minimumWordSpan
        }
    }

    public struct AttributedWord: Hashable, Sendable {
        public let word: TranscribedWord
        /// The diarizer channel, or `nil` when no channel was active across the word's span
        /// and no neighbouring word could lend one.
        public let speaker: Int?

        public init(word: TranscribedWord, speaker: Int?) {
            self.word = word
            self.speaker = speaker
        }
    }

    /// Total time each channel was active, which is how a speaker limit decides what to keep.
    public static func activeDurations(_ activity: [SpeakerActivity]) -> [Int: Double] {
        activity.reduce(into: [:]) { totals, span in
            totals[span.speaker, default: 0] += span.duration
        }
    }

    /// The channels to consider, honouring a speaker limit by keeping the most active ones.
    ///
    /// Words from a dropped channel are not discarded — they fall through to whichever kept
    /// channel overlaps them best. Expected speakers therefore caps how many speakers appear
    /// rather than silently doing nothing, which is what a user setting it to 2 is asking for.
    public static func keptChannels(
        activity: [SpeakerActivity], limit: Int?
    ) -> Set<Int> {
        let durations = activeDurations(activity)
        guard let limit, limit > 0, durations.count > limit else { return Set(durations.keys) }
        // Ties break towards the earlier channel, which is the earlier arrival.
        let ranked = durations.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }
        return Set(ranked.prefix(limit).map(\.key))
    }

    /// Attributes every word to a channel.
    public static func attribute(
        words: [TranscribedWord], activity: [SpeakerActivity], options: Options = .init()
    ) -> [AttributedWord] {
        guard !words.isEmpty else { return [] }
        let kept = keptChannels(activity: activity, limit: options.speakerLimit)
        guard !kept.isEmpty else { return words.map { AttributedWord(word: $0, speaker: nil) } }

        var byChannel: [Int: [SpeakerActivity]] = [:]
        for span in activity where kept.contains(span.speaker) && span.duration > 0 {
            byChannel[span.speaker, default: []].append(span)
        }
        for channel in byChannel.keys {
            byChannel[channel]?.sort { $0.start < $1.start }
        }

        var attributed: [AttributedWord] = []
        attributed.reserveCapacity(words.count)
        var previous: Int?
        for word in words {
            let span = correctedSpan(for: word, options: options)
            var best: (channel: Int, overlap: Double)?
            for (channel, spans) in byChannel {
                let overlap = spans.reduce(0.0) { total, active in
                    total + max(0, min(span.end, active.end) - max(span.start, active.start))
                }
                guard overlap > 0 else { continue }
                if let current = best {
                    // A tie goes to whoever was already speaking: a word that straddles a
                    // handover should not flip the speaker on a rounding difference.
                    let better = overlap > current.overlap
                        || (overlap == current.overlap
                            && (channel == previous
                                || (current.channel != previous && channel < current.channel)))
                    if better { best = (channel, overlap) }
                } else {
                    best = (channel, overlap)
                }
            }
            attributed.append(AttributedWord(word: word, speaker: best?.channel))
            if let channel = best?.channel { previous = channel }
        }
        return fillGaps(attributed)
    }

    /// A word spoken over silence the diarizer found no channel for inherits its neighbours'
    /// speaker rather than becoming an unknown speaker of its own. A positive attribution is
    /// never overridden.
    private static func fillGaps(_ words: [AttributedWord]) -> [AttributedWord] {
        var result = words
        var carried: Int?
        for index in result.indices {
            if let speaker = result[index].speaker {
                carried = speaker
            } else if let carried {
                result[index] = AttributedWord(word: result[index].word, speaker: carried)
            }
        }
        // Words before the first attributed word take the first one's speaker.
        guard let first = result.first(where: { $0.speaker != nil })?.speaker else { return result }
        for index in result.indices {
            guard result[index].speaker == nil else { break }
            result[index] = AttributedWord(word: result[index].word, speaker: first)
        }
        return result
    }

    static func correctedSpan(
        for word: TranscribedWord, options: Options
    ) -> (start: Double, end: Double) {
        let start = max(0, word.start - options.emissionLag)
        var end = max(start, word.end - options.emissionLag)
        if end - start < options.minimumWordSpan { end = start + options.minimumWordSpan }
        return (start, end)
    }
}
