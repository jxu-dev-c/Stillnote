import Foundation
import Observation

public struct RecordingSessionState: Codable, Hashable, Sendable {
    public var id: String
    public var status: CaptureState
    public var elapsed: Double
    public var error: String?
    public var options: CaptureOptions
}

public enum RecordingError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Owns at most one capture session: its files on disk, its live state, and the
/// save/discard transition into a stored meeting. A session that outlives the app is
/// recovered on the next launch so its audio can still be saved.
@MainActor
@Observable
public final class RecordingCoordinator {
    public private(set) var session: RecordingSessionState?
    public private(set) var microphoneLevel: CaptureLevel?
    public private(set) var systemLevel: CaptureLevel?

    private let store: Store
    private let paths: Paths
    private var capture: (any AnyObject)?
    private var eventTask: Task<Void, Never>?

    public init(store: Store, paths: Paths) {
        self.store = store
        self.paths = paths
    }

    public var isRecoveredSession: Bool { session?.status == .stopped && capture == nil }

    // MARK: - Recovery

    /// Adopts an interrupted session whose meeting was never created. Sessions whose
    /// meeting already exists were saved successfully and are removed.
    public func recover() async {
        guard session == nil else { return }
        let manager = FileManager.default
        let directories = (try? manager.contentsOfDirectory(
            at: paths.recordingsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let descriptor = directory.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: descriptor),
                  var state = try? JSONDecoder().decode(RecordingSessionState.self, from: data),
                  state.id == directory.lastPathComponent
            else { continue }
            if await store.exists(state.id) {
                try? manager.removeItem(at: directory)
            } else {
                state.status = .stopped
                state.error = "Recording was interrupted. Save the captured audio or discard it."
                session = state
                microphoneLevel = nil
                systemLevel = nil
                return
            }
        }
    }

    // MARK: - Lifecycle

    public func start(options: CaptureOptions) async throws {
        guard session == nil else {
            throw RecordingError.message("Save or discard the current recording before starting another.")
        }
        guard #available(macOS 15.0, *) else {
            throw RecordingError.message("Native capture requires macOS 15 or newer.")
        }
        let capabilities = CaptureDeviceCatalog.capabilities()
        guard capabilities.available else {
            throw RecordingError.message(capabilities.reason ?? "Recording is unavailable on this Mac.")
        }
        var options = options
        if !options.microphoneID.isEmpty,
           !capabilities.microphones.contains(where: { $0.id == options.microphoneID }) {
            throw RecordingError.message("That microphone is no longer available. Refresh devices and retry.")
        }
        options.displayID = options.displayID ?? capabilities.defaultDisplayID
        guard let displayID = options.displayID,
              capabilities.displays.contains(where: { $0.id == displayID })
        else {
            throw RecordingError.message("That display is no longer available. Refresh devices and retry.")
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = paths.recordingsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var state = RecordingSessionState(
            id: id, status: .starting, elapsed: 0, error: nil, options: options
        )
        session = state
        persist(state)

        let capture = CaptureSession(options: options, directory: directory)
        self.capture = capture
        eventTask = Task { @MainActor [weak self] in
            for await event in capture.events {
                self?.apply(event, sessionID: id)
            }
            self?.captureEnded(sessionID: id)
        }
        do {
            try await capture.start()
        } catch {
            self.capture = nil
            eventTask?.cancel()
            eventTask = nil
            session = nil
            try? FileManager.default.removeItem(at: directory)
            throw RecordingError.message(
                "Capture could not start. Allow Stillnote in System Settings → Privacy & Security → "
                    + "Screen & System Audio Recording and Microphone, then retry. \(error.localizedDescription)"
            )
        }
        state.status = .recording
        session = state
        persist(state)
    }

    public func pause() {
        guard #available(macOS 15.0, *), let capture = capture as? CaptureSession else { return }
        capture.pause()
    }

    public func resume() {
        guard #available(macOS 15.0, *), let capture = capture as? CaptureSession else { return }
        capture.resume()
    }

    /// Stops capture, mixes the sources, muxes optional video, and stores the meeting.
    /// Repeating a successful save returns the same meeting instead of duplicating it.
    public func finish() async throws -> Meeting {
        guard let state = session else { throw RecordingError.message("This recording session was not found.") }
        if let existing = try? await store.get(state.id) { return existing }
        await stopCapture()
        let directory = paths.recordingsDirectory.appendingPathComponent(state.id, isDirectory: true)
        let mixed = directory.appendingPathComponent("mixed.wav")
        try? FileManager.default.removeItem(at: mixed)
        let duration = try AudioMixer.mix(sessionDirectory: directory, to: mixed)

        var warning = session?.error
        var videoName: String?
        if state.options.screenVideo {
            let screen = directory.appendingPathComponent("screen.mp4")
            do {
                try await VideoMuxer.mux(screen: screen, audio: mixed, to: paths.videoURL(state.id))
                videoName = "screen.mp4"
            } catch {
                try? FileManager.default.removeItem(at: paths.videoURL(state.id))
                videoName = nil
                warning = "Screen video could not be recovered. Your audio was saved."
            }
        }
        let audio = paths.audioURL(state.id)
        try? FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: mixed, to: audio)

        let meeting = Meeting(
            id: state.id, title: state.options.title, audioName: "recording.wav",
            language: state.options.language, speakerCount: state.options.speakerCount,
            duration: duration, videoName: videoName, error: warning
        )
        do {
            _ = try await store.insert(meeting)
        } catch {
            // Keep the source session available for a retry if database persistence fails.
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: paths.videoURL(state.id))
            throw error
        }
        session = nil
        microphoneLevel = nil
        systemLevel = nil
        try? FileManager.default.removeItem(at: directory)
        await recover()
        return meeting
    }

    public func discard() async {
        guard let state = session else { return }
        await stopCapture()
        try? FileManager.default.removeItem(
            at: paths.recordingsDirectory.appendingPathComponent(state.id, isDirectory: true)
        )
        session = nil
        microphoneLevel = nil
        systemLevel = nil
        await recover()
    }

    public func shutdown() async {
        await stopCapture()
    }

    // MARK: - Internals

    private func stopCapture() async {
        if #available(macOS 15.0, *), let capture = capture as? CaptureSession {
            await capture.stop()
        }
        eventTask?.cancel()
        eventTask = nil
        capture = nil
        if var state = session, state.status != .stopped {
            state.status = .stopped
            session = state
            persist(state)
        }
        microphoneLevel = nil
        systemLevel = nil
    }

    private func apply(_ event: CaptureEvent, sessionID: String) {
        guard var state = session, state.id == sessionID else { return }
        switch event {
        case .state(let status, let elapsed, let error):
            state.status = status
            state.elapsed = elapsed
            if let error { state.error = error }
            session = state
            persist(state)
        case .levels(let microphone, let system, let elapsed):
            microphoneLevel = microphone
            systemLevel = system
            state.elapsed = elapsed
            session = state
        }
    }

    private func captureEnded(sessionID: String) {
        guard var state = session, state.id == sessionID, capture != nil else { return }
        if state.status != .stopped {
            state.status = .stopped
            state.error = state.error
                ?? "Native capture exited unexpectedly. Save the captured audio or discard it."
        }
        session = state
        microphoneLevel = nil
        systemLevel = nil
        persist(state)
    }

    private func persist(_ state: RecordingSessionState) {
        let directory = paths.recordingsDirectory.appendingPathComponent(state.id, isDirectory: true)
        let target = directory.appendingPathComponent("session.json")
        let temporary = directory.appendingPathComponent("session.tmp")
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: temporary, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: temporary, to: target)
    }
}
