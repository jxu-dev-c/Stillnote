import AVFoundation
import AVKit
import Observation
import StillnoteCore
import SwiftUI

/// Playback state shared by the transcript (for seeking and highlighting) and the
/// transport. Video meetings use AVKit's own controls; audio-only meetings get a
/// compact bar built from standard controls.
@MainActor
@Observable
final class PlayerModel {
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1
    let hasVideo: Bool
    /// AVFoundation cannot open every container an older recording may use (WebM/Opus
    /// in particular). Say so instead of showing a transport that will never move.
    private(set) var unplayableReason: String?

    private nonisolated(unsafe) var observer: Any?
    private var statusObserver: NSKeyValueObservation?

    init(meeting: Meeting, paths: Paths) {
        hasVideo = meeting.hasVideo && FileManager.default.fileExists(atPath: paths.videoURL(meeting.id).path)
        duration = meeting.duration
        let url = hasVideo
            ? MediaFile.videoURL(for: meeting, paths: paths)
            : MediaFile.audioURL(for: meeting, paths: paths)
        guard FileManager.default.fileExists(atPath: url.path) else {
            unplayableReason = "The media file is missing from local storage."
            return
        }
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        // Periodic time callbacks stop at the end of a recording. Observe playback
        // status separately so the transport also updates after completion or a stall.
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        Task { [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, !playable else { return }
            unplayableReason = "This recording's format cannot be played on macOS. "
                + "The transcript and exports are unaffected."
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if let item = self.player.currentItem {
                    let length = item.duration.seconds
                    if length.isFinite, length > 0 { self.duration = length }
                }
            }
        }
    }

    deinit {
        // The observer is created once during init and only read here, so removing it
        // off the main actor cannot race with anything.
        if let observer { player.removeTimeObserver(observer) }
    }

    func toggle() {
        if player.rate > 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            player.rate = rate
        }
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        currentTime = max(0, min(seconds, duration))
    }

    func play(from seconds: Double) {
        seek(to: seconds)
        player.play()
        player.rate = rate
        isPlaying = true
    }

    func skipBack() { seek(to: currentTime - 10) }

    func setRate(_ value: Float) {
        rate = value
        if player.timeControlStatus == .playing { player.rate = value }
    }
}

struct PlayerView: View {
    @Bindable var player: PlayerModel

    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 8) {
            if let reason = player.unplayableReason {
                Label(reason, systemImage: "speaker.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if player.hasVideo {
                VideoPlayer(player: player.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(.rect(cornerRadius: StillnoteTheme.cornerRadius))
            } else {
                transport
            }
        }
        .padding(player.hasVideo ? 0 : 16)
        .modifier(AudioPlaybackSurface(enabled: !player.hasVideo))
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause recording" : "Play recording")

            Button { player.skipBack() } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(.borderless)
            .help("Back 10 seconds")
            .accessibilityLabel("Back 10 seconds")

            Text(Formatting.duration(player.currentTime))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.small)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Formatting.duration(player.currentTime)) of \(Formatting.duration(player.duration))")

            Text(Formatting.duration(player.duration))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu("\(player.rate.formatted())×") {
                ForEach(Self.rates, id: \.self) { rate in
                    Button("\(rate.formatted())×") { player.setRate(rate) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback Speed")
            .accessibilityLabel("Playback speed, \(player.rate.formatted()) times")
        }
    }
}

private struct AudioPlaybackSurface: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.playbackSurface()
        } else {
            content
        }
    }
}
