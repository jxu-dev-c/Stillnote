import Foundation

public enum Formatting {
    /// m:ss, or h:mm:ss for recordings an hour or longer.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// hh:mm:ss, with milliseconds for SRT cues.
    public static func timestamp(_ seconds: Double, srt: Bool = false) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        let (hours, rest) = (milliseconds / 3_600_000, milliseconds % 3_600_000)
        let (minutes, tail) = (rest / 60_000, rest % 60_000)
        let base = String(format: "%02d:%02d:%02d", hours, minutes, tail / 1000)
        return srt ? base + String(format: ",%03d", tail % 1000) : base
    }
}
