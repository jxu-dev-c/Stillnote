import Foundation

/// Serializes heavy local work so transcription, voice recognition, and model downloads never
/// compete for memory or the GPU. A queued job that is cancelled before it starts simply
/// observes cancellation and returns. Agent jobs (summaries, Name Meeting) use
/// `AgentJobLimiter` instead, so they never wait behind a transcription.
public actor JobQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}

/// Bounds how many agent CLI jobs run at once. An agent job hands meeting text to the provider's
/// CLI and waits for its answer; it uses neither the GPU nor much memory, so it runs alongside
/// local work rather than on `JobQueue`. Jobs past the limit wait and start in arrival order.
public actor AgentJobLimiter {
    public static let defaultLimit = 3
    public static let limits = 1...8

    public private(set) var limit: Int
    public private(set) var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = AgentJobLimiter.defaultLimit) {
        self.limit = Self.clamp(limit)
    }

    public static func clamp(_ value: Int) -> Int {
        min(max(value, limits.lowerBound), limits.upperBound)
    }

    public var waiting: Int { waiters.count }

    /// Takes effect at once: raising it starts waiting jobs; lowering it lets running jobs finish.
    public func setLimit(_ value: Int) {
        limit = Self.clamp(value)
        startWaiters()
    }

    /// Runs `operation` once a slot is free, and frees the slot when it returns or throws.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The slot is taken on the waiter's behalf by whoever resumes it.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        running -= 1
        startWaiters()
    }

    private func startWaiters() {
        while running < limit, !waiters.isEmpty {
            running += 1
            waiters.removeFirst().resume()
        }
    }
}
