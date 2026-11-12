import AVFoundation
import AVKit
import Observation
import StillnoteCore
import SwiftUI

/// Playback state shared by the transcript (for seeking and following) and the dock.
/// Screen video opens on request in a sheet that drives the same player.
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

    /// Where a voice preview stops playing.
    private var previewEnd: Double?
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
                if let end = self.previewEnd, time.seconds >= end {
                    self.previewEnd = nil
                    self.player.pause()
                }
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
        previewEnd = nil
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
        previewEnd = nil
        seek(to: seconds)
        player.play()
        player.rate = rate
        isPlaying = true
    }

    func skipBack() { seek(to: currentTime - 10) }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    /// Plays a stretch of the recording, such as one speaker's line, and stops at its end.
    func preview(from start: Double, to end: Double) {
        play(from: start)
        previewEnd = max(start + 1, min(end, start + 12))
    }

    func setRate(_ value: Float) {
        rate = value
        if player.timeControlStatus == .playing { player.rate = value }
    }
}

/// Shows the screen recording with AVKit's own controls. It shares the bar's player, so
/// position, speed, and transcript highlighting stay in step while it is open and after.
struct VideoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let player: PlayerModel

    var body: some View {
        VideoPlayer(player: player.player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: StillnoteTheme.cornerRadius))
            // AVKit keeps its own buttons on the leading edge and along the bottom.
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .modifier(CloseButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close video")
                .padding(12)
            }
            .padding(20)
            .frame(minWidth: 720, idealWidth: 960, minHeight: 420, idealHeight: 580)
    }
}

private struct CloseButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}
