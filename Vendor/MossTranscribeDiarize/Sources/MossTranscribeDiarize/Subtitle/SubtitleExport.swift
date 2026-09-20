import Foundation

private let speakerColors = [
    "&H00FFFFFF",
    "&H005BE7FF",
    "&H0086F28F",
    "&H00BBA7FF",
    "&H0000D7FF",
    "&H00FFB56B",
    "&H00FF8EDB",
    "&H00D8D8D8",
]

public enum SubtitleExport {
    public static func makeSubtitleSegments(
        from segments: [TranscriptSegment]
    ) -> [SubtitleSegment] {
        segments.enumerated().map { index, segment in
            SubtitleSegment(from: segment, id: String(index + 1))
        }
    }

    public static func exportJSON(_ segments: [SubtitleSegment], prettyPrinted: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(segments)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MossError.generationFailed("Failed to encode JSON subtitles.")
        }
        return text + "\n"
    }

    public static func exportSRT(
        _ segments: [SubtitleSegment],
        showSpeaker: Bool = true,
        speakerNames: [String: String] = [:]
    ) -> String {
        var blocks: [String] = []
        for (index, segment) in segments.enumerated() {
            let body = displayText(segment, showSpeaker: showSpeaker, speakerNames: speakerNames)
            blocks.append(
                """
                \(index + 1)
                \(formatSRTTime(segment.start)) --> \(formatSRTTime(segment.end))
                \(body)
                """
            )
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    public static func exportASS(
        _ segments: [SubtitleSegment],
        style: SubtitleStyle = SubtitleStyle(),
        videoWidth: Int = 1920,
        videoHeight: Int = 1080
    ) -> String {
        let fontSize = style.fontSize ?? max(24, Int((Double(videoHeight) * 0.045).rounded()))
        let speakers = Array(Set(segments.map(\.speaker))).sorted()

        var styleLines = [assStyleLine(name: "Default", style: style, fontSize: fontSize, primaryColor: style.primaryColor)]
        if style.speakerColors {
            for (index, speaker) in speakers.enumerated() {
                let color = speakerColors[index % speakerColors.count]
                styleLines.append(
                    assStyleLine(
                        name: speakerStyleName(speaker),
                        style: style,
                        fontSize: fontSize,
                        primaryColor: color
                    )
                )
            }
        }

        let dialogueLines = segments.map { segment -> String in
            let styleName = style.speakerColors ? speakerStyleName(segment.speaker) : "Default"
            let body = assEscape(
                displayText(
                    segment,
                    showSpeaker: style.showSpeaker,
                    speakerNames: style.speakerNames
                )
            )
            return "Dialogue: 0,\(formatASSTime(segment.start)),\(formatASSTime(segment.end)),\(styleName),,0,0,0,,\(body)"
        }

        return """
        [Script Info]
        ScriptType: v4.00+
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        PlayResX: \(videoWidth)
        PlayResY: \(videoHeight)

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        \(styleLines.joined(separator: "\n"))

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(dialogueLines.joined(separator: "\n"))

        """
    }

    public static func write(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: encoding)
    }

    public static func formatSRTTime(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    public static func formatASSTime(_ seconds: Double) -> String {
        let centiseconds = max(0, Int((seconds * 100).rounded()))
        let hours = centiseconds / 360_000
        let minutes = (centiseconds % 360_000) / 6_000
        let secs = (centiseconds % 6_000) / 100
        let centis = centiseconds % 100
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centis)
    }
}

// MARK: - Private helpers

private func displayText(
    _ segment: SubtitleSegment,
    showSpeaker: Bool,
    speakerNames: [String: String]
) -> String {
    guard showSpeaker, !segment.speaker.isEmpty else {
        return segment.text
    }
    let name = speakerNames[segment.speaker] ?? segment.speaker
    return "\(name): \(segment.text)"
}

private func assStyleLine(
    name: String,
    style: SubtitleStyle,
    fontSize: Int,
    primaryColor: String
) -> String {
    "Style: \(name),\(style.fontName),\(fontSize),\(primaryColor),&H000000FF,\(style.outlineColor),"
        + "\(style.backColor),0,0,0,0,100,100,0,0,1,\(style.outline),\(style.shadow),"
        + "\(style.alignment),48,48,\(style.marginV),1"
}

private func speakerStyleName(_ speaker: String) -> String {
    let cleaned = speaker.map { character -> Character in
        character.isLetter || character.isNumber ? character : "_"
    }
    return "Speaker_\(String(cleaned))"
}

private func assEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "{", with: "(")
        .replacingOccurrences(of: "}", with: ")")
        .replacingOccurrences(of: "\n", with: "\\N")
}
