import Foundation

/// Subtitle cue used for JSON / SRT / ASS export.
public struct SubtitleSegment: Sendable, Equatable, Identifiable, Codable, Hashable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String

    public init(id: String, start: Double, end: Double, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }

    public init(from segment: TranscriptSegment, id: String? = nil) {
        self.id = id ?? segment.id
        self.start = segment.start
        self.end = segment.end
        self.speaker = segment.speaker
        self.text = segment.text
    }
}

/// ASS style options.
public struct SubtitleStyle: Sendable, Equatable {
    public var fontName: String
    public var fontSize: Int?
    public var alignment: Int
    public var marginV: Int
    public var showSpeaker: Bool
    public var speakerColors: Bool
    public var primaryColor: String
    public var outlineColor: String
    public var backColor: String
    public var outline: Int
    public var shadow: Int
    public var speakerNames: [String: String]

    public init(
        fontName: String = "Noto Sans CJK SC",
        fontSize: Int? = nil,
        alignment: Int = 2,
        marginV: Int = 56,
        showSpeaker: Bool = true,
        speakerColors: Bool = true,
        primaryColor: String = "&H00FFFFFF",
        outlineColor: String = "&H00000000",
        backColor: String = "&H64000000",
        outline: Int = 3,
        shadow: Int = 1,
        speakerNames: [String: String] = [:]
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.alignment = alignment
        self.marginV = marginV
        self.showSpeaker = showSpeaker
        self.speakerColors = speakerColors
        self.primaryColor = primaryColor
        self.outlineColor = outlineColor
        self.backColor = backColor
        self.outline = outline
        self.shadow = shadow
        self.speakerNames = speakerNames
    }
}

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case json
    case srt
    case ass
}
