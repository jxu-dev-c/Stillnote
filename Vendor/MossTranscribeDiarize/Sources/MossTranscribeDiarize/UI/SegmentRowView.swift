import SwiftUI

/// One diarized segment row for lists / review UIs.
public struct SegmentRowView: View {
    public let segment: TranscriptSegment
    public var showSpeaker: Bool

    public init(segment: TranscriptSegment, showSpeaker: Bool = true) {
        self.segment = segment
        self.showSpeaker = showSpeaker
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showSpeaker {
                    Text(segment.speaker)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(speakerTint.opacity(0.18), in: Capsule())
                        .foregroundStyle(speakerTint)
                        .accessibilityLabel("Speaker \(segment.speaker)")
                }

                Text(timeRangeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("From \(segment.start, format: .number.precision(.fractionLength(2))) to \(segment.end, format: .number.precision(.fractionLength(2))) seconds")

                Spacer(minLength: 0)
            }

            Text(segment.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var timeRangeLabel: String {
        String(format: "%.2f – %.2fs", segment.start, segment.end)
    }

    private var speakerTint: Color {
        let palette: [Color] = [
            .blue, .teal, .green, .orange, .purple, .pink, .indigo, .mint,
        ]
        let digits = segment.speaker.drop(while: { !$0.isNumber })
        let index = Int(digits) ?? abs(segment.speaker.hashValue)
        return palette[abs(index) % palette.count]
    }
}

#Preview {
    List {
        SegmentRowView(
            segment: TranscriptSegment(
                start: 0.12,
                end: 3.45,
                speaker: "S01",
                text: "Hello from MOSS Transcribe Diarize."
            )
        )
        SegmentRowView(
            segment: TranscriptSegment(
                start: 3.50,
                end: 7.10,
                speaker: "S02",
                text: "This is a second speaker turn."
            )
        )
    }
}
