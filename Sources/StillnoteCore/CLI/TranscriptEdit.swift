import Foundation

public struct ReplaceOptions: Hashable, Sendable {
    public var find: String
    public var replacement: String
    public var regex: Bool
    public var ignoreCase: Bool
    public var wholeWord: Bool

    public init(
        find: String, replacement: String, regex: Bool = false, ignoreCase: Bool = false,
        wholeWord: Bool = false
    ) {
        self.find = find
        self.replacement = replacement
        self.regex = regex
        self.ignoreCase = ignoreCase
        self.wholeWord = wholeWord
    }
}

/// What a replacement did, or would do. `segments` counts transcript lines touched, which is
/// what a person recognizes; `matches` counts individual occurrences.
public struct ReplaceOutcome: Codable, Hashable, Sendable {
    public var matches: Int
    public var segments: Int

    public init(matches: Int = 0, segments: Int = 0) {
        self.matches = matches
        self.segments = segments
    }

    public var isEmpty: Bool { matches == 0 }
}

/// Transcript corrections, shared by the app's segment editor and the `stillnote` CLI so the
/// two cannot drift apart on what a transcript edit implies.
public enum TranscriptEdit {
    /// A transcript or speaker correction invalidates the summary drawn from it, and any
    /// speaker id a segment now references has to exist in the speaker table.
    ///
    /// This is the policy the GUI has always applied; it lives here so the CLI applies exactly
    /// the same one, and so it is reachable from tests.
    public static func finish(_ meeting: inout Meeting) {
        for segment in meeting.segments where meeting.speakers[segment.speaker] == nil {
            meeting.speakers[segment.speaker] = segment.speaker
        }
        let hasTranscript = !meeting.segments.isEmpty
        meeting.summary = nil
        meeting.status = hasTranscript ? .transcribed : .ready
        meeting.error = nil
        meeting.progress = hasTranscript ? 100 : 0
        meeting.stage = hasTranscript ? "Transcript ready" : "Ready to transcribe"
    }

    /// Counts what a replacement would change without touching the meeting.
    public static func preview(_ meeting: Meeting, options: ReplaceOptions) throws -> ReplaceOutcome {
        var copy = meeting
        return try apply(&copy, options: options, commit: false)
    }

    /// Rewrites matching segment text and applies `finish` when anything changed. Speaker
    /// names, notes, and the summary are left alone: this corrects what was said.
    @discardableResult
    public static func replace(in meeting: inout Meeting, options: ReplaceOptions) throws -> ReplaceOutcome {
        let outcome = try apply(&meeting, options: options, commit: true)
        if !outcome.isEmpty {
            meeting.segments = try Validation.segments(meeting.segments, duration: meeting.duration)
            finish(&meeting)
        }
        return outcome
    }

    private static func apply(
        _ meeting: inout Meeting, options: ReplaceOptions, commit: Bool
    ) throws -> ReplaceOutcome {
        let expression = try self.expression(options)
        let template = options.regex
            ? options.replacement
            : NSRegularExpression.escapedTemplate(for: options.replacement)
        var outcome = ReplaceOutcome()
        for index in meeting.segments.indices {
            let text = meeting.segments[index].text
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.numberOfMatches(in: text, range: range)
            guard matches > 0 else { continue }
            let rewritten = expression.stringByReplacingMatches(
                in: text, range: range, withTemplate: template
            )
            guard rewritten != text else { continue }
            guard rewritten.count <= Validation.maxSegmentTextLength else {
                throw CLIError.usage("That replacement would make a transcript segment too long to save.")
            }
            outcome.matches += matches
            outcome.segments += 1
            if commit { meeting.segments[index].text = rewritten }
        }
        return outcome
    }

    static func expression(_ options: ReplaceOptions) throws -> NSRegularExpression {
        guard !options.find.isEmpty else { throw CLIError.usage("Give some text to find.") }
        var pattern = options.regex ? options.find : NSRegularExpression.escapedPattern(for: options.find)
        if options.wholeWord {
            // Group first, so an alternation in a supplied pattern cannot escape the boundaries.
            pattern = "\\b(?:\(pattern))\\b"
        }
        do {
            return try NSRegularExpression(
                pattern: pattern, options: options.ignoreCase ? [.caseInsensitive] : []
            )
        } catch {
            throw CLIError.usage("That search pattern is not valid: \(error.localizedDescription)")
        }
    }
}
