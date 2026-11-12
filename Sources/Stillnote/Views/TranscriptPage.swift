import AppKit
import StillnoteCore
import SwiftUI

/// Which transcript line is in focus, and whether focus follows playback.
@MainActor
@Observable
final class LyricsState {
    var focus = 0
    /// While true, the focused line is the one playing. Browsing turns it off; choosing a
    /// line or pressing play turns it back on.
    var following = true
    var matches: [Int] = []

    func browse(to index: Int) {
        following = false
        focus = index
    }
}

struct TranscriptPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let meeting: Meeting
    let player: PlayerModel?
    let lyrics: LyricsState
    @Binding var picker: PickerTarget?
    let retranscribe: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if meeting.status == .transcribing {
                TranscribingStatus(meeting: meeting)
            } else if meeting.segments.isEmpty {
                emptyStatus
            } else {
                LyricsView(meeting: meeting, player: player, lyrics: lyrics, picker: $picker)
            }
            if let player, meeting.status == .transcribing || !meeting.segments.isEmpty {
                BottomFade()
                PlaybackDock(meeting: meeting, player: player, lyrics: lyrics)
                    .padding(.leading, 28)
                    .padding(.trailing, 32)
                    .padding(.bottom, 22)
            }
        }
        // The transcript's large text must not set a minimum height: at the zero width the
        // split view measures with, it would wrap a word per line.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background {
            if let player, !meeting.segments.isEmpty {
                PlaybackFollower(segments: meeting.segments, player: player, lyrics: lyrics)
            }
        }
    }

    @ViewBuilder
    private var emptyStatus: some View {
        let transcribed = meeting.status == .transcribed || meeting.status == .complete
        if meeting.status == .error {
            StatusPage(
                label: "Needs attention", dot: .orange, big: nil,
                message: meeting.error ?? "Something went wrong with this meeting.",
                action: model.speech.ready ? StatusAction("Transcribe Again") { Task { await model.transcribe(meeting.id) } } : nil
            )
        } else if transcribed {
            StatusPage(
                label: "No speech detected", dot: DS.text3, big: nil,
                message: "Your audio is saved. Check the microphone, language, or try a clearer recording.",
                action: StatusAction("Transcribe Again", perform: retranscribe)
            )
        } else if model.speech.ready {
            StatusPage(
                label: "Not transcribed", dot: DS.text3, big: nil,
                message: "Transcribe this recording to get a transcript with each speaker’s lines.",
                action: StatusAction("Transcribe") { Task { await model.transcribe(meeting.id) } }
            )
        } else {
            StatusPage(
                label: "Not transcribed", dot: DS.text3, big: nil,
                message: model.speech.detail,
                action: StatusAction("Set Up Transcription") { openSettings() }
            )
        }
    }
}

// MARK: - Status pages

/// The anatomy the recording, transcribing, and empty pages share: a speaker-style label, an
/// optional big figure, a line in the dimmed lyric style, and an action.
struct StatusPage<Label: View, Big: View>: View {
    @ViewBuilder let labelView: Label
    @ViewBuilder let bigView: Big
    let message: String?
    var action: StatusAction?
    var actionEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { labelView }
                .padding(.bottom, 8)
            bigView
            if let message {
                Text(message)
                    .font(.system(size: 28, weight: .bold))
                    .letterSpacing(-0.024, size: 28)
                    .lineSpacing(1.9)
                    .foregroundStyle(DS.lyricOff)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if let action {
                Button(action: action.perform) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .designGlassCapsule()
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!actionEnabled)
                .opacity(actionEnabled ? 1 : 0.38)
                .padding(.top, 22)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 138, trailing: 28))
    }
}

extension StatusPage where Label == StatusLabel, Big == AnyView {
    init(label: String, dot: Color, big: AnyView?, message: String?, action: StatusAction?) {
        self.labelView = StatusLabel(text: label, dot: dot)
        self.bigView = big ?? AnyView(EmptyView())
        self.message = message
        self.action = action
    }
}

struct StatusAction {
    let title: String
    let perform: () -> Void

    init(_ title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// A 22-point tinted disc with a dot, a bold word, and optional detail.
struct StatusLabel: View {
    let text: String
    let dot: Color
    var pulsing = false
    var detail: String?

    var body: some View {
        Circle()
            .fill(dot.opacity(0.22))
            .frame(width: 22, height: 22)
            .overlay {
                if pulsing { PulsingDot(color: dot) } else { Circle().fill(dot).frame(width: 8, height: 8) }
            }
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.text)
        if let detail {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DS.text2)
        }
    }
}

/// The big figure on status pages: 64-point digits with a smaller dimmed suffix.
struct BigFigure: View {
    let value: String
    let suffix: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.system(size: 64, weight: .bold)).letterSpacing(-0.035, size: 64)
            Text(suffix).font(.system(size: 28, weight: .bold)).letterSpacing(-0.035, size: 28)
                .foregroundStyle(DS.text3)
        }
        .monospacedDigit()
        .foregroundStyle(DS.text)
    }
}

private struct TranscribingStatus: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        let percent = Int(max(0, min(100, meeting.progress)).rounded())
        let stopping = meeting.stage == "Stopping transcription…"
        StatusPage(
            labelView: { StatusLabel(text: "Transcribing", dot: DS.accent, pulsing: true) },
            bigView: {
                BigFigure(value: "\(percent)", suffix: "%")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(percent) percent transcribed")
            },
            message: message,
            action: StatusAction("Cancel") { Task { await model.cancelTranscription(meeting.id) } },
            actionEnabled: !stopping && model.isTranscribing
        )
    }

    private var message: String {
        let stage = meeting.stage.trimmingCharacters(in: .whitespaces)
        guard !stage.isEmpty, stage != "Preparing…" else { return "Preparing the recording. You can listen while you wait." }
        let sentence = stage.hasSuffix(".") || stage.hasSuffix("…") ? stage : stage + "."
        return sentence + " You can listen while you wait."
    }
}

// MARK: - Lyrics

/// The transcript as lyrics: the focused line large in the middle, earlier lines fading
/// upward and later lines fading downward.
private struct LyricsView: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let player: PlayerModel?
    let lyrics: LyricsState
    @Binding var picker: PickerTarget?
    @State private var editing: Segment?
    @State private var wheel: CGFloat = 0

    private static let window = 8

    var body: some View {
        let segments = meeting.segments
        let focus = min(lyrics.focus, segments.count - 1)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(max(0, focus - Self.window)..<focus, id: \.self) { index in
                    line(index, distance: focus - index)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
            }

            CurrentLine(meeting: meeting, index: focus, player: player, lyrics: lyrics, picker: $picker)
                .padding(.vertical, 12)
                .contextMenu { menu(focus) }

            VStack(alignment: .leading, spacing: 10) {
                ForEach((focus + 1)..<min(segments.count, focus + 1 + Self.window), id: \.self) { index in
                    line(index, distance: index - focus)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 70, trailing: 28))
        .animation(.smooth(duration: 0.35), value: focus)
        .background(ScrollWheelReader { delta in browse(by: delta) })
        .sheet(item: $editing) { segment in SegmentEditor(meeting: meeting, segment: segment) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
    }

    private func line(_ index: Int, distance: Int) -> some View {
        let segment = meeting.segments[index]
        let look = meeting.look(segment.speaker)
        let level = min(3, distance)
        return Button {
            choose(index)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LineSpeaker(look: look, time: segment.start, nameInk: DS.text2)
                Text(segment.text)
                    .font(.system(size: 28, weight: .bold))
                    .letterSpacing(-0.024, size: 28)
                    .lineSpacing(1.9)
                    .foregroundStyle(DS.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
            .opacity([1, 0.55, 0.4, 0.3][level])
            .blur(radius: [0, 0.8, 2, 3][level])
        }
        .buttonStyle(.plain)
        .contextMenu { menu(index) }
        .accessibilityLabel("\(look.name), \(LineSpeaker.clock(segment.start)): \(segment.text)")
    }

    @ViewBuilder
    private func menu(_ index: Int) -> some View {
        let segment = meeting.segments[index]
        Button("Play from Here") { choose(index) }
        Button("Edit Line…") { editing = segment }
            .disabled(meeting.status.isBusy)
        Divider()
        Button("Copy Line") { copy(segment.text) }
        Button("Copy Transcript") {
            copy(meeting.segments.map {
                "[\(Formatting.timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)"
            }.joined(separator: "\n\n"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func choose(_ index: Int) {
        picker = nil
        lyrics.focus = index
        lyrics.following = true
        player?.play(from: meeting.segments[index].start)
    }

    private func step(_ delta: Int) {
        let next = max(0, min(meeting.segments.count - 1, lyrics.focus + delta))
        if next != lyrics.focus { lyrics.browse(to: next) }
    }

    /// A trackpad or wheel scroll walks through lines, one per 40 points.
    private func browse(by delta: CGFloat) {
        // Scrolling the open popover's list must not move the transcript behind it.
        guard picker == nil else { return }
        wheel += delta
        while wheel <= -40 { wheel += 40; step(1) }
        while wheel >= 40 { wheel -= 40; step(-1) }
    }
}

/// A line's speaker initial, name, and time.
private struct LineSpeaker: View {
    let look: SpeakerLook
    let time: Double
    let nameInk: Color

    var body: some View {
        HStack(spacing: 8) {
            SpeakerPortrait(look: look, size: 22, fontSize: 11)
            Text(look.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(nameInk)
            Text(Self.clock(time))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(DS.text3)
        }
    }

    /// 08:14, or 1:02:09 past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// The focused line: its speaker chip opens Assign Speaker for this line, and its text fills
/// in as it plays.
private struct CurrentLine: View {
    let meeting: Meeting
    let index: Int
    let player: PlayerModel?
    let lyrics: LyricsState
    @Binding var picker: PickerTarget?

    var body: some View {
        let segment = meeting.segments[index]
        let look = meeting.look(segment.speaker)
        let open = picker == .line(segment.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    picker = open ? nil : .line(segment.id)
                } label: {
                    HStack(spacing: 8) {
                        SpeakerPortrait(look: look, size: 22, fontSize: 11)
                        Text(look.name).font(.system(size: 13, weight: .semibold))
                        Icon(.chevronDown, size: 12, lineWidth: 2.6).opacity(0.7)
                    }
                    .foregroundStyle(look.unknown ? DS.accentInk : DS.text)
                    .padding(.leading, 4)
                    .padding(.trailing, 9)
                    .frame(height: 30)
                    .hoverFill(Capsule(), active: open, color: DS.hover)
                    .background(look.unknown && !open ? DS.Accent.blue.tint : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(meeting.status.isBusy)
                .help(meeting.status.isBusy ? "Available when processing finishes" : "Change the speaker for this line")
                .accessibilityLabel("Speaker: \(look.name). Change speaker for this line")
                .anchorPreference(key: PickerAnchors.self, value: .bounds) { [.line: $0] }
                .padding(.leading, -4)
                Text(LineSpeaker.clock(segment.start))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(DS.text2)
            }
            KaraokeText(segment: segment, player: player)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Text that fills from the dimmed lyric color to full as the line plays.
private struct KaraokeText: View {
    let segment: Segment
    let player: PlayerModel?

    var body: some View {
        let progress = self.progress
        Text(segment.text)
            .font(.system(size: 28, weight: .bold))
            .letterSpacing(-0.024, size: 28)
            .lineSpacing(1.9)
            .foregroundStyle(LinearGradient(
                stops: [
                    .init(color: DS.lyricOn, location: 0),
                    .init(color: DS.lyricOn, location: max(0, progress - 0.05)),
                    .init(color: DS.lyricOff, location: min(1, progress + 0.05)),
                    .init(color: DS.lyricOff, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            ))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var progress: CGFloat {
        guard let player else { return 0.51 }
        let time = player.currentTime
        if time >= segment.end { return 1.05 }
        if time <= segment.start { return player.isPlaying ? -0.05 : 0.51 }
        return CGFloat((time - segment.start) / max(0.1, segment.end - segment.start))
    }
}

/// Keeps the focused line on the one playing while focus follows playback.
private struct PlaybackFollower: View {
    let segments: [Segment]
    let player: PlayerModel
    let lyrics: LyricsState

    var body: some View {
        let playing = Self.index(at: player.currentTime, in: segments)
        Color.clear
            .onChange(of: playing, initial: true) { _, index in
                if lyrics.following, let index, index != lyrics.focus {
                    lyrics.focus = index
                }
            }
            .onChange(of: player.isPlaying) { _, playing in
                if playing { lyrics.following = true }
            }
    }

    /// The line being spoken, or the last one before the playhead during a pause.
    static func index(at time: Double, in segments: [Segment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        var low = 0, high = segments.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

// MARK: - Dock

/// The fade behind the dock, so lines pass under it softly.
struct BottomFade: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [DS.edge, .clear], startPoint: .bottom, endPoint: .top)
        }
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.35),
                                   .init(color: .clear, location: 1)],
                           startPoint: .bottom, endPoint: .top)
        }
        .frame(height: 150)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Playback controls with the meeting's timeline laid along the bottom.
private struct PlaybackDock: View {
    let meeting: Meeting
    let player: PlayerModel
    let lyrics: LyricsState
    @State private var showingVideo = false

    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        HStack(spacing: 22) {
            HStack(spacing: 4) {
                Button { player.skip(by: -15) } label: {
                    Icon(.back15, size: 26, lineWidth: 1.6)
                        .foregroundStyle(DS.text)
                        .frame(width: 44, height: 44)
                        .hoverFill(Circle())
                }
                .buttonStyle(.plain)
                .help("Back 15 seconds")
                .accessibilityLabel("Back 15 seconds")
                Button(action: togglePlayback) {
                    Icon(player.isPlaying ? .pause : .play, size: 22, filled: true)
                        .foregroundStyle(DS.playInk)
                        .frame(width: 48, height: 48)
                        .background(DS.playFill, in: .circle)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(by: 15) } label: {
                    Icon(.forward15, size: 26, lineWidth: 1.6)
                        .foregroundStyle(DS.text)
                        .frame(width: 44, height: 44)
                        .hoverFill(Circle())
                }
                .buttonStyle(.plain)
                .help("Forward 15 seconds")
                .accessibilityLabel("Forward 15 seconds")
            }
            .padding(.horizontal, 6)
            .frame(height: 60)
            .designGlassCapsule(blur: true)
            .disabled(player.unplayableReason != nil)

            if let reason = player.unplayableReason {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Timeline(meeting: meeting, player: player, lyrics: lyrics)
                Text("\(LineSpeaker.clock(player.currentTime)) / \(LineSpeaker.clock(player.duration))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.text2)
                    .fixedSize()
            }
        }
        .frame(height: 60)
        .contextMenu {
            Picker("Playback Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(Self.rates, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            if player.hasVideo {
                Button("Show Screen Recording") { showingVideo = true }
            }
        }
        .sheet(isPresented: $showingVideo) { VideoSheet(player: player) }
    }

    /// Play resumes from the line being browsed, if any.
    private func togglePlayback() {
        if !player.isPlaying, !lyrics.following, lyrics.focus < meeting.segments.count {
            player.play(from: meeting.segments[lyrics.focus].start)
        } else {
            player.toggle()
        }
        lyrics.following = true
    }
}

/// The whole meeting as speech-shaped bars, brightest for the focused line. Drag or click to skip.
private struct Timeline: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let player: PlayerModel
    let lyrics: LyricsState
    private let waveforms = WaveformCache.shared

    private static let count = 150

    var body: some View {
        let duration = max(player.duration, meeting.duration)
        let bars = Self.bars(for: meeting, duration: duration, levels: waveforms.levels[meeting.id])
        let focus = lyrics.focus
        let focusStart = meeting.segments.indices.contains(focus) ? meeting.segments[focus].start : player.currentTime
        let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
        GeometryReader { proxy in
            let width = proxy.size.width
            let gap = (width - CGFloat(Self.count) * 2) / CGFloat(Self.count - 1)
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    for (index, bar) in bars.enumerated() {
                        // The line in focus is darkest, what came before it is dimmed, and what
                        // is still to come is lightest.
                        let opacity: Double = bar.segment == focus && bar.segment != nil ? 1
                            : bar.time < focusStart ? 0.6 : 0.3
                        let x = CGFloat(index) * (2 + gap)
                        let rect = CGRect(x: x, y: (size.height - bar.height) / 2, width: 2, height: bar.height)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(DS.text.opacity(opacity)))
                    }
                }
                Capsule()
                    .fill(DS.accent)
                    .frame(width: 3, height: 36)
                    .shadow(color: DS.accent, radius: 4)
                    .offset(x: max(0, min(width, width * fraction)) - 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let target = max(0, min(1, value.location.x / max(1, width))) * player.duration
                player.seek(to: target)
                lyrics.following = true
            })
        }
        .frame(height: 44)
        .task(id: meeting.id) { await waveforms.load(meeting, paths: model.paths) }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                   .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel("Meeting timeline")
        .accessibilityValue("\(LineSpeaker.clock(player.currentTime)) of \(LineSpeaker.clock(player.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: 15)
            case .decrement: player.skip(by: -15)
            @unknown default: break
            }
        }
    }

    struct Bar {
        let height: CGFloat
        /// The transcript line spoken at this bar, if any.
        let segment: Int?
        let time: Double
    }

    /// One bar per stretch of the recording, as tall as its loudness: silence is a dot. Until the
    /// recording's loudness has been read, or when it can't be, the bars follow the transcript:
    /// speech-shaped bursts where people talk. Seeded per bar so they never shimmer.
    static func bars(for meeting: Meeting, duration: Double, levels: [Float]?) -> [Bar] {
        let segments = meeting.segments
        guard duration > 0 else { return (0..<count).map { _ in Bar(height: 2, segment: nil, time: 0) } }
        func random(_ n: Double) -> Double { abs((sin(n * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)) }
        var bars: [Bar] = []
        var cursor = 0
        for k in 0..<count {
            let time = (Double(k) + 0.5) / Double(count) * duration
            while cursor < segments.count - 1, segments[cursor].end < time { cursor += 1 }
            let inside = cursor < segments.count && segments[cursor].start <= time && time <= segments[cursor].end
            let segment = inside ? cursor : nil
            let amplitude: Double
            if let levels, !levels.isEmpty {
                // Each bar takes the loudest of the stretches it covers, so short words still show.
                let lower = k * levels.count / count, upper = max(lower + 1, (k + 1) * levels.count / count)
                amplitude = pow(Double(levels[lower..<min(upper, levels.count)].max() ?? 0), 0.8)
            } else if inside {
                let line = segments[cursor]
                let local = (time - line.start) / max(0.1, line.end - line.start)
                let envelope = pow(sin(.pi * min(1, max(0, local * 1.1 - 0.03))), 0.6)
                amplitude = envelope * (0.3 + 0.7 * (0.6 * random(Double(k) + Double(cursor) * 7.3) + 0.4 * random(Double(k) * 1.7 + 3.1)))
            } else {
                amplitude = 0
            }
            bars.append(Bar(height: CGFloat(max(2, min(26, (2 + 24 * amplitude).rounded()))), segment: segment, time: time))
        }
        return bars
    }
}

/// Recordings' loudness, read once per meeting while the app runs.
@MainActor
@Observable
final class WaveformCache {
    static let shared = WaveformCache()
    /// Enough resolution to stay accurate when the dock is wide.
    static let resolution = 600

    private(set) var levels: [String: [Float]] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func load(_ meeting: Meeting, paths: Paths) async {
        guard levels[meeting.id] == nil, loading.insert(meeting.id).inserted else { return }
        defer { loading.remove(meeting.id) }
        let url = MediaFile.audioURL(for: meeting, paths: paths)
        let read = Task.detached(priority: .utility) {
            try await AudioEnvelope.read(url, buckets: Self.resolution)
        }
        // A recording that can't be read keeps the transcript-shaped bars.
        guard let envelope = try? await withTaskCancellationHandler(
            operation: { try await read.value }, onCancel: { read.cancel() }
        ) else { return }
        levels[meeting.id] = envelope
    }
}

/// Reports scroll-wheel and trackpad scrolling over this view's area.
struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    @MainActor
    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated {
                    guard let view = self.view, let window = view.window, event.window == window else { return event }
                    let point = view.convert(event.locationInWindow, from: nil)
                    guard view.bounds.contains(point), event.momentumPhase == [] else { return event }
                    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                    self.onScroll(delta)
                    return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Editing sheets

struct SegmentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let segment: Segment

    @State private var text = ""
    @State private var speaker = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit transcript").font(.headline)
            Text("Editing at \(Formatting.timestamp(segment.start)) clears the current summary.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Speaker", selection: $speaker) {
                ForEach(meeting.orderedSpeakerIDs(), id: \.self) { Text(meeting.speakerName($0)).tag($0) }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            text = segment.text
            speaker = segment.speaker
        }
    }

    private func save() {
        dismiss()
        Task {
            await model.editTranscript(meeting.id) { meeting in
                guard let index = meeting.segments.firstIndex(where: { $0.id == segment.id }) else { return }
                meeting.segments[index].text = text
                meeting.segments[index].speaker = speaker
            }
        }
    }
}

/// Re-transcription replaces corrections, so it is confirmed and lets the language and
/// speaker hints be adjusted first.
struct RetranscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    @State private var language = "auto"
    @State private var speakerCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe again").font(.headline)
            Text("Replaces the transcript, corrections, speaker names, and summary. "
                + "Keeps the recording and context.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
            }
            .formStyle(.grouped)
            .frame(height: 100)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Transcribe Again") {
                    dismiss()
                    Task { await model.transcribe(meeting.id, language: language, speakerCount: .some(speakerCount)) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            language = meeting.language.isEmpty ? "auto" : meeting.language
            speakerCount = meeting.speakerCount
        }
    }
}

