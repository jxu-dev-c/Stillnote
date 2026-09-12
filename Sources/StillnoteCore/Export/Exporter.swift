import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case markdown = "md"
    case text = "txt"
    case subtitles = "srt"
    case json

    public var label: String {
        switch self {
        case .markdown: return "Markdown notes"
        case .text: return "Plain text transcript"
        case .subtitles: return "Subtitles (.srt)"
        case .json: return "All meeting data (.json)"
        }
    }

    public var fileExtension: String { rawValue }
}

public enum Exporter {
    public static func text(_ meeting: Meeting, format: ExportFormat) -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(meeting)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        case .subtitles:
            let cues = meeting.segments.enumerated().map { index, segment in
                """
                \(index + 1)
                \(Formatting.timestamp(segment.start, srt: true)) --> \(Formatting.timestamp(segment.end, srt: true))
                \(meeting.speakerName(segment.speaker)): \(segment.text)
                """
            }
            return cues.joined(separator: "\n\n") + "\n"
        case .markdown, .text:
            return document(meeting, heading: format == .markdown ? "# " : "", markdown: format == .markdown)
        }
    }

    private static func document(_ meeting: Meeting, heading: String, markdown: Bool) -> String {
        var lines = ["\(heading)\(meeting.title)", "", "Recorded: \(meeting.createdAt)", ""]
        if let summary = meeting.summary {
            lines += ["\(heading)Summary", "", summary.overview, ""]
            lines += ["\(heading)Key points", ""]
            lines += summary.keyPoints.map { "- \($0)" }
            lines.append("")
            lines += ["\(heading)Decisions", ""]
            lines += summary.decisions.map { "- \($0)" }
            lines.append("")
            lines += ["\(heading)Action items", ""]
            lines += summary.actionItems.map { item in
                var text = item.text
                if let owner = item.owner { text += " — Owner: \(owner)" }
                if let due = item.due { text += " — Due: \(due)" }
                return "- \(text)"
            }
            lines.append("")
            lines += ["Summary provider: \(summary.provider) (\(summary.model))", ""]
        }
        if !meeting.notes.isEmpty || !meeting.contextLinks.isEmpty {
            lines += ["\(heading)Context", ""]
            if !meeting.notes.isEmpty { lines += [meeting.notes, ""] }
            for link in meeting.contextLinks {
                if markdown {
                    // Escape the label and angle-bracket the target so punctuation in a
                    // page title cannot break out of the link.
                    let title = escapeMarkdown(link.title.isEmpty ? link.url : link.title)
                    let url = link.url.replacingOccurrences(of: "<", with: "%3C")
                        .replacingOccurrences(of: ">", with: "%3E")
                    lines.append("- [\(title)](<\(url)>)")
                } else {
                    lines.append(link.title.isEmpty ? "- \(link.url)" : "- \(link.title): \(link.url)")
                }
            }
            if !meeting.contextLinks.isEmpty { lines.append("") }
        }
        lines += ["\(heading)Transcript", ""]
        for segment in meeting.segments {
            lines += [
                "[\(Formatting.timestamp(segment.start))] \(meeting.speakerName(segment.speaker)): \(segment.text)",
                "",
            ]
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeMarkdown(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\`*_{}[]<>()!".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    public static func suggestedFilename(_ meeting: Meeting, format: ExportFormat) -> String {
        let allowed = meeting.title.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == " " || character == "_"
                ? character : " "
        }
        let name = String(allowed).trimmingCharacters(in: .whitespaces).prefix(100)
        return "\(name.isEmpty ? "meeting" : String(name)).\(format.fileExtension)"
    }
}
