import Foundation

/// A bounded hand-off from the capture queue to the live worker.
///
/// Capture runs on one serial queue that also writes the WAVs the recording is made of. If a
/// pipe write blocked there, a worker falling behind would stall the recording itself, so this
/// buffer is capped and drops the oldest audio when it overflows. A dropped preview block is
/// acceptable; a stalled recording is not.
final class LiveAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var closed = false
    private var dropped = 0
    private let capacity: Int

    /// Default capacity is 30 seconds at 16 kHz: far more slack than a worker running at
    /// several times real time needs, and still a bounded amount of memory.
    init(capacity: Int = 16_000 * 30) {
        self.capacity = capacity
    }

    var droppedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.append(contentsOf: samples)
        if pending.count > capacity {
            let excess = pending.count - capacity
            pending.removeFirst(excess)
            dropped += excess
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }

    /// Takes everything buffered. `nil` means the buffer is closed and drained, which is the
    /// writer's signal to close the worker's stdin.
    func drain() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if pending.isEmpty { return closed ? nil : [] }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

/// Accumulates the live worker's incremental partials into a transcript.
///
/// Partials carry only the words added since the last one, because the trailing word is still
/// being assembled and a 90-minute meeting would otherwise re-send its whole transcript twice
/// a second. The speaker timeline arrives whole each time, since it stays small.
public struct LiveTranscriptAccumulator: Sendable {
    public private(set) var words: [TranscribedWord] = []
    public private(set) var activity: [SpeakerActivity] = []
    public private(set) var language = "auto"
    public private(set) var isFinal = false

    public init() {}

    public mutating func apply(_ partial: NemotronWorkerPartial) {
        words.append(contentsOf: partial.words)
        activity = partial.activity
        language = partial.language
        isFinal = isFinal || partial.final
    }

    /// The preview to show. Speaker labels trail the words by about a second, because that is
    /// how far behind the diarizer's low-latency geometry confirms; words with no speaker yet
    /// inherit the last confirmed one rather than flickering between speakers.
    public func preview(
        duration: Double, speakerLimit: Int? = nil
    ) throws -> TranscriptionResult {
        try NemotronTranscript.build(
            words: words, activity: activity, duration: max(duration, lastWordEnd),
            language: language,
            options: SpeakerAttribution.Options(speakerLimit: speakerLimit)
        )
    }

    var lastWordEnd: Double { words.last?.end ?? 0 }
}

/// One incremental update from the live worker.
public struct NemotronWorkerPartial: Codable, Hashable, Sendable {
    public var language: String
    public var words: [TranscribedWord]
    public var activity: [SpeakerActivity]
    /// The last partial of a session, sent once stdin closed and both models finalized.
    public var final: Bool

    public init(
        language: String, words: [TranscribedWord], activity: [SpeakerActivity], final: Bool
    ) {
        self.language = language
        self.words = words
        self.activity = activity
        self.final = final
    }
}

/// Drives the live worker for the length of a recording.
///
/// Unlike `SpeechWorkerProcess`, which runs a worker to completion and collects one result,
/// this keeps a process alive while audio arrives, so it owns its own pipes and reader. The
/// two share the environment hardening and the terminate-then-SIGKILL escalation, which are
/// the parts that matter for correctness.
public final class LiveTranscriptionSession: @unchecked Sendable {
    private let process: Process
    private let buffer = LiveAudioBuffer()
    private let input: FileHandle
    private var writer: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    /// Samples dropped because the worker could not keep up. Surfaced so a preview that
    /// skipped audio can say so instead of looking like a recognition failure.
    public var droppedSamples: Int { buffer.droppedSamples }

    private init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    public static func start(
        modelDirectory: URL, worker: URL, model: String, language: String, speakerCount: Int?,
        hotWords: [String], onUpdate: @escaping @Sendable (NemotronWorkerPartial) -> Void
    ) throws -> LiveTranscriptionSession {
        let request = NemotronWorkerRequest(
            asrModelPath: SpeechCatalog.directory(
                modelDirectory: modelDirectory, model: model
            ).path,
            diarizerModelPath: SpeechCatalog.directory(
                modelDirectory: modelDirectory, model: SpeechCatalog.diarizationModel
            ).path,
            pcmPath: nil, language: language, speakerCount: speakerCount, hotWords: hotWords,
            geometry: .live
        )

        let process = Process()
        process.executableURL = worker
        process.arguments = ["nemotron", try request.encoded()]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A worker that exits early must not take the app with it: a write to the closed
        // pipe has to fail locally rather than raise SIGPIPE, the same way PosixProcess
        // handles the summary providers' stdin.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try process.run()
        let session = LiveTranscriptionSession(
            process: process, input: stdin.fileHandleForWriting
        )
        session.writer = Task.detached { [buffer = session.buffer, input = stdin.fileHandleForWriting] in
            while !Task.isCancelled {
                guard let samples = buffer.drain() else { break }
                if samples.isEmpty {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let data = samples.withUnsafeBytes { Data($0) }
                do { try input.write(contentsOf: data) } catch { break }
            }
            try? input.close()
        }
        session.reader = Task.detached { [handle = stdout.fileHandleForReading] in
            await Self.read(from: handle, onUpdate: onUpdate)
        }
        return session
    }

    /// Called from the capture queue. Never blocks and never throws.
    public func append(_ samples: [Float]) {
        buffer.append(samples)
    }

    /// Closes the input and waits for the worker to finish its last partial.
    ///
    /// The live worker must be gone before the final transcription job starts, so the two
    /// never hold their models at the same time. A worker that will not exit is killed:
    /// the preview is disposable, and the recording has already been saved.
    public func finish(timeout: Duration = .seconds(20)) async {
        buffer.close()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        cancel()
        _ = await reader?.result
    }

    /// Stops the worker without waiting for a result.
    public func cancel() {
        buffer.close()
        writer?.cancel()
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Parses the worker's event stream. Only `partial` is of interest; diagnostics printed
    /// on the same pipe by native libraries are ignored, exactly as the batch reader does.
    static func read(
        from handle: FileHandle, onUpdate: @escaping @Sendable (NemotronWorkerPartial) -> Void
    ) async {
        let prefix = "STILLNOTE_EVENT "
        var pending = Data()
        while true {
            let chunk = await Task.detached { handle.availableData }.value
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                guard line.hasPrefix(prefix),
                      let data = line.dropFirst(prefix.count).data(using: .utf8),
                      let partial = try? JSONDecoder().decode(
                          NemotronWorkerPartial.self, from: data
                      )
                else { continue }
                onUpdate(partial)
            }
        }
    }
}
