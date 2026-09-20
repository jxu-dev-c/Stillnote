import Foundation

/// Streaming parser for compact MOSS transcript output.
///
/// Expected segment format:
///
///     [start][Sxx]text[end]
///
/// Character-scanning state machine ported from the Python package
/// (`transcript_parser.py`) — avoids regular expressions and supports
/// incremental decoding while tokens stream.
public final class TranscriptStreamParser: @unchecked Sendable {
    private enum State {
        case seekStart
        case readStart
        case expectSpeakerOpen
        case readSpeaker
        case readText
        case readEnd
        case afterEnd
    }

    public var stripText: Bool
    public var skipEmpty: Bool

    private var state: State = .seekStart
    private var token: [Character] = []
    private var text: [Character] = []
    private var pendingAfterEnd: [Character] = []
    private var start: Double?
    private var end: Double?
    private var endToken = ""
    private var speaker: String?

    public init(stripText: Bool = true, skipEmpty: Bool = true) {
        self.stripText = stripText
        self.skipEmpty = skipEmpty
    }

    public func reset() {
        state = .seekStart
        token.removeAll(keepingCapacity: true)
        text.removeAll(keepingCapacity: true)
        pendingAfterEnd.removeAll(keepingCapacity: true)
        start = nil
        end = nil
        endToken = ""
        speaker = nil
    }

    @discardableResult
    public func feed(_ chunk: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        feed(chunk) { segments.append($0) }
        return segments
    }

    public func feed(_ chunk: String, emit: (TranscriptSegment) -> Void) {
        for character in chunk {
            switch state {
            case .seekStart:
                seekStart(character)
            case .readStart:
                readStart(character)
            case .expectSpeakerOpen:
                expectSpeakerOpen(character)
            case .readSpeaker:
                readSpeaker(character)
            case .readText:
                readText(character)
            case .readEnd:
                readEnd(character, emit: emit)
            case .afterEnd:
                afterEnd(character, emit: emit)
            }
        }
    }

    @discardableResult
    public func close() -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        close { segments.append($0) }
        return segments
    }

    public func close(emit: (TranscriptSegment) -> Void) {
        if state == .afterEnd {
            emitSegment(emit)
        }
        reset()
    }

    // MARK: - States

    private func seekStart(_ character: Character) {
        if character == "[" {
            token.removeAll(keepingCapacity: true)
            state = .readStart
        }
    }

    private func readStart(_ character: Character) {
        if character == "]" {
            guard let value = parseTimestamp(token) else {
                reset()
                return
            }
            start = value
            state = .expectSpeakerOpen
            token.removeAll(keepingCapacity: true)
            return
        }

        if isTimestampChar(character) {
            token.append(character)
            if token.count <= 32 { return }
        }

        reset()
        if character == "[" {
            state = .readStart
        }
    }

    private func expectSpeakerOpen(_ character: Character) {
        if character == "[" {
            token.removeAll(keepingCapacity: true)
            state = .readSpeaker
        } else if !character.isWhitespace {
            reset()
        }
    }

    private func readSpeaker(_ character: Character) {
        if character == "]" {
            guard let value = parseSpeaker(token) else {
                reset()
                return
            }
            speaker = value
            text.removeAll(keepingCapacity: true)
            state = .readText
            token.removeAll(keepingCapacity: true)
            return
        }

        if isSpeakerChar(character) {
            token.append(character)
            if token.count <= 16 { return }
        }

        reset()
        if character == "[" {
            state = .readStart
        }
    }

    private func readText(_ character: Character) {
        if character == "[" {
            token.removeAll(keepingCapacity: true)
            state = .readEnd
        } else {
            text.append(character)
        }
    }

    private func readEnd(_ character: Character, emit: (TranscriptSegment) -> Void) {
        if character == "]" {
            if let value = parseTimestamp(token),
               let start,
               value >= start {
                end = value
                endToken = String(token)
                pendingAfterEnd.removeAll(keepingCapacity: true)
                state = .afterEnd
            } else {
                text.append("[")
                text.append(contentsOf: token)
                text.append("]")
                state = .readText
            }
            token.removeAll(keepingCapacity: true)
            return
        }

        if isTimestampChar(character) {
            token.append(character)
            if token.count <= 32 { return }
        }

        text.append("[")
        text.append(contentsOf: token)
        text.append(character)
        token.removeAll(keepingCapacity: true)
        state = .readText
    }

    private func afterEnd(_ character: Character, emit: (TranscriptSegment) -> Void) {
        if character == "[" {
            emitSegment(emit)
            token.removeAll(keepingCapacity: true)
            state = .readStart
            return
        }

        if character.isWhitespace {
            pendingAfterEnd.append(character)
            return
        }

        text.append("[")
        text.append(contentsOf: endToken)
        text.append("]")
        text.append(contentsOf: pendingAfterEnd)
        text.append(character)
        pendingAfterEnd.removeAll(keepingCapacity: true)
        end = nil
        endToken = ""
        state = .readText
    }

    private func emitSegment(_ emit: (TranscriptSegment) -> Void) {
        guard let start, let end, let speaker else {
            reset()
            return
        }

        var body = String(text)
        if stripText {
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !body.isEmpty || !skipEmpty {
            emit(TranscriptSegment(start: start, end: end, speaker: speaker, text: body))
        }

        token.removeAll(keepingCapacity: true)
        text.removeAll(keepingCapacity: true)
        pendingAfterEnd.removeAll(keepingCapacity: true)
        self.start = nil
        self.end = nil
        endToken = ""
        self.speaker = nil
        state = .seekStart
    }
}

// MARK: - Free functions

/// Parse a complete transcript string into segments.
public func parseTranscript(_ text: String, stripText: Bool = true, skipEmpty: Bool = true) -> [TranscriptSegment] {
    let parser = TranscriptStreamParser(stripText: stripText, skipEmpty: skipEmpty)
    var segments = parser.feed(text)
    segments.append(contentsOf: parser.close())
    return segments
}

// MARK: - Helpers

private func parseTimestamp(_ chars: [Character]) -> Double? {
    guard !chars.isEmpty else { return nil }
    var dotCount = 0
    var digitCount = 0
    for character in chars {
        if character >= "0" && character <= "9" {
            digitCount += 1
        } else if character == "." {
            dotCount += 1
            if dotCount > 1 { return nil }
        } else {
            return nil
        }
    }
    guard digitCount > 0 else { return nil }
    return Double(String(chars))
}

private func parseSpeaker(_ chars: [Character]) -> String? {
    guard chars.count >= 2, chars[0] == "S" else { return nil }
    for character in chars.dropFirst() {
        guard character >= "0" && character <= "9" else { return nil }
    }
    return String(chars)
}

private func isTimestampChar(_ character: Character) -> Bool {
    (character >= "0" && character <= "9") || character == "."
}

private func isSpeakerChar(_ character: Character) -> Bool {
    character == "S" || (character >= "0" && character <= "9")
}
