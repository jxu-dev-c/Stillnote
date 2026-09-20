/// Minimal box for moving non-Sendable values across task boundaries.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
