import StillnoteCore
import SwiftUI

/// When Stillnote offers to record, and how saved audio is cleaned up and split.
struct RecordSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("When a meeting starts") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    reminderOption(
                        on: true, title: "Offer to record",
                        detail: "When Teams, Zoom, Webex, Slack, FaceTime, Discord, or a web browser starts using the microphone."
                    )
                    reminderOption(on: false, title: "Don’t offer", detail: "Record only when you start it yourself.")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("When a meeting starts")
                SettingsCaption("Stillnote sees only which app is using the microphone, never its audio, and nothing leaves your Mac.")
            }
        }

        SettingsSection("After recording") {
            SettingsCard {
                RecordingTimelinePreview(example: example)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                SettingsRow(
                    "Trim silence from saved recordings",
                    caption: "Removes leading and trailing silence when a recording is saved, for the times a recording kept running after the meeting ended. The recording file is rewritten, and only cuts longer than a minute are applied."
                ) {
                    SettingsSwitch("Trim silence from saved recordings", isOn: model.setting(\.cleanup.trimRecording))
                }
                SettingsRow(
                    "Silence background noise between speech",
                    caption: "Mutes typing, fans, and static wherever nobody is speaking, in the copy sent to transcription only. Speech itself is never filtered, so recognition accuracy is unaffected and playback keeps the original audio."
                ) {
                    SettingsSwitch("Silence background noise between speech", isOn: model.setting(\.cleanup.suppressNonSpeech))
                }
                SettingsRow("Sensitivity", caption: model.settings.cleanup.sensitivity.detail) {
                    Picker("Sensitivity", selection: model.setting(\.cleanup.sensitivity)) {
                        ForEach(CleanupSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .disabled(!model.settings.cleanup.trimRecording && !model.settings.cleanup.suppressNonSpeech)
                SettingsRow(
                    "Offer to split recordings longer than",
                    caption: "Shows Split Recording for saved audio at this length, and Stop, Transcribe & Summarize splits such recordings automatically. Each part is 20 minutes; the last keeps the remainder. Screen recordings cannot be split."
                ) {
                    let threshold = model.settings.splitThresholdMinutes
                    SettingsStepper(
                        label: "Split threshold", value: model.setting(\.splitThresholdMinutes), step: 5,
                        range: min(5, threshold)...1440, format: { "\($0) min" }
                    )
                }
                if !model.speech.cleanupAvailable {
                    SettingsNotice(text: "Download the speech models to enable cleanup. Until then recordings are saved and transcribed in full.")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var example: RecordingTimelineExample {
        RecordingTimelineExample(
            trim: model.settings.cleanup.trimRecording,
            mute: model.settings.cleanup.suppressNonSpeech,
            splitMinutes: model.settings.splitThresholdMinutes
        )
    }

    private func reminderOption(on: Bool, title: String, detail: String) -> some View {
        let selected = model.settings.meetingReminders.enabled == on
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
        return Button {
            model.changeSettings { $0.meetingReminders.enabled = on }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    if selected {
                        Circle().fill(DS.accent)
                        Circle().fill(.white).frame(width: 6, height: 6)
                    } else {
                        Circle().strokeBorder(DS.track, lineWidth: 1.5)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.text)
                    SettingsCaption(detail)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.card, in: shape)
            .overlay { shape.strokeBorder(DS.cardBorder, lineWidth: 0.5) }
            .overlay { if selected { shape.strokeBorder(DS.accent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Timeline example

/// A fixed 72-minute example recording, with speech from minute 2 to minute 60, showing what
/// the current trim and split settings would do to it.
struct RecordingTimelineExample: Equatable {
    static let duration = 72
    static let speechStart = 2
    static let speechEnd = 60
    static let partMinutes = 20
    static let barCount = 90

    struct Part: Equatable {
        /// Fractions of the whole recording.
        let start: Double
        let width: Double
        let label: String
    }

    struct Bar: Equatable {
        let height: CGFloat
        let speech: Bool
        let faded: Bool
    }

    let trim: Bool
    let mute: Bool
    let splitMinutes: Int

    var kept: ClosedRange<Int> { trim ? Self.speechStart...Self.speechEnd : 0...Self.duration }
    var keptMinutes: Int { kept.upperBound - kept.lowerBound }
    var splits: Bool { keptMinutes >= splitMinutes }

    /// Minute boundaries of the saved parts.
    var bounds: [Int] {
        var bounds = [kept.lowerBound]
        if splits {
            var minute = kept.lowerBound + Self.partMinutes
            while minute < kept.upperBound {
                bounds.append(minute)
                minute += Self.partMinutes
            }
        }
        bounds.append(kept.upperBound)
        return bounds
    }

    var parts: [Part] {
        let bounds = bounds
        return (0..<(bounds.count - 1)).map { index in
            let minutes = bounds[index + 1] - bounds[index]
            let width = Double(minutes) / Double(Self.duration)
            let label = splits
                ? "Part \(index + 1)" + (width > 0.2 ? " · \(minutes) min" : "")
                : "Not split · \(minutes) min"
            return Part(start: Double(bounds[index]) / Double(Self.duration), width: width, label: label)
        }
    }

    /// Positions of the split marks, as fractions of the whole recording.
    var marks: [Double] {
        splits ? bounds.dropFirst().dropLast().map { Double($0) / Double(Self.duration) } : []
    }

    var summary: String {
        let trimmed = trim
            ? "Trims \(Self.duration - keptMinutes) min of silence"
            : "Keeps all \(Self.duration) min"
        return trimmed + " · " + (splits ? "offers \(parts.count) parts" : "no split offered")
    }

    var bars: [Bar] {
        (0..<Self.barCount).map { index in
            let minute = (Double(index) + 0.5) / Double(Self.barCount) * Double(Self.duration)
            let speech = minute >= Double(Self.speechStart) && minute <= Double(Self.speechEnd)
            let pause = speech && Self.noise(Double(index) * 3.1) < 0.12
            let height: CGFloat = !speech ? 3 : pause ? (mute ? 2 : 6)
                : (8 + 26 * pow(Self.noise(Double(index) + 0.7), 0.8)).rounded()
            return Bar(height: height, speech: speech, faded: !speech && trim)
        }
    }

    /// A repeatable pseudo-random value in 0..<1, so the example waveform never changes.
    private static func noise(_ seed: Double) -> Double {
        abs((sin(seed * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1))
    }
}

private struct RecordingTimelinePreview: View {
    let example: RecordingTimelineExample

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(example.summary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.accentInk)
                .contentTransition(.numericText())
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    DS.well
                    if example.trim {
                        trimmedEnd(from: 0, to: Double(RecordingTimelineExample.speechStart), width: width)
                        trimmedEnd(from: Double(RecordingTimelineExample.speechEnd),
                                   to: Double(RecordingTimelineExample.duration), width: width)
                    }
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(example.bars.enumerated()), id: \.offset) { _, bar in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(bar.speech ? DS.wave : DS.waveSilence)
                                .opacity(bar.faded ? 0.25 : bar.speech ? 0.9 : 0.5)
                                .frame(maxWidth: .infinity)
                                .frame(height: bar.height)
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(width: width, height: 44)
                    ForEach(example.marks, id: \.self) { mark in
                        Path { path in
                            path.move(to: CGPoint(x: mark * width, y: 0))
                            path.addLine(to: CGPoint(x: mark * width, y: 44))
                        }
                        .stroke(DS.text, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                }
                .frame(width: width, height: 44)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
            }
            .frame(height: 44)
            .padding(.top, 10)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(example.parts.enumerated()), id: \.offset) { _, part in
                        Text(part.label)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .frame(width: part.width * proxy.size.width)
                            .offset(x: part.start * proxy.size.width)
                    }
                }
            }
            .frame(height: 16)
            .padding(.top, 6)
        }
        .animation(.easeOut(duration: 0.2), value: example)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example recording: \(example.summary)")
    }

    private func trimmedEnd(from: Double, to: Double, width: CGFloat) -> some View {
        let duration = Double(RecordingTimelineExample.duration)
        return HatchPattern()
            .fill(DS.hatch)
            .frame(width: (to - from) / duration * width, height: 44)
            .clipped()
            .offset(x: from / duration * width)
    }
}

/// Diagonal stripes, 4 points wide with 4-point gaps, like the design's trimmed ends.
private struct HatchPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period: CGFloat = 8 * 2.squareRoot()
        let stripe: CGFloat = 4 * 2.squareRoot()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripe, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + stripe + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.closeSubpath()
            x += period
        }
        return path
    }
}
