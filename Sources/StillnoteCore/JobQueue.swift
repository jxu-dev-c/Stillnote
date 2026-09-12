import Foundation

/// Serializes heavy work so transcription, summaries, and model downloads never
/// compete for memory or the GPU. A queued job that is cancelled before it starts
/// simply observes cancellation and returns.
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
