import Foundation

/// FFmpeg/ffprobe helpers matching Python `app/ffmpeg.py`.
public struct FFmpegAvailability: Sendable, Equatable {
    public var ffmpeg: String?
    public var ffprobe: String?

    public var isAvailable: Bool {
        ffmpeg != nil && ffprobe != nil
    }

    public func asDictionary() -> [String: Any] {
        [
            "available": isAvailable,
            "ffmpeg": ffmpeg as Any,
            "ffprobe": ffprobe as Any,
        ]
    }
}

public enum FFmpegTools {
    public static func detect() -> FFmpegAvailability {
        FFmpegAvailability(
            ffmpeg: which("ffmpeg"),
            ffprobe: which("ffprobe")
        )
    }

    public static func probeMedia(at path: URL) throws -> [String: Any] {
        let tools = detect()
        guard let ffprobe = tools.ffprobe else {
            throw MossError.generationFailed("ffprobe is not available on PATH.")
        }
        let output = try run(
            ffprobe,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_streams",
                "-show_format",
                path.path,
            ]
        )
        guard let data = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MossError.generationFailed("Failed to parse ffprobe JSON.")
        }
        return object
    }

    public static func probeVideoSize(
        at path: URL,
        defaultSize: (width: Int, height: Int) = (1920, 1080)
    ) -> (width: Int, height: Int) {
        do {
            let media = try probeMedia(at: path)
            if let streams = media["streams"] as? [[String: Any]] {
                for stream in streams where (stream["codec_type"] as? String) == "video" {
                    let width = stream["width"] as? Int ?? defaultSize.width
                    let height = stream["height"] as? Int ?? defaultSize.height
                    return (width, height)
                }
            }
        } catch {
            return defaultSize
        }
        return defaultSize
    }

    /// Burn ASS subtitles into an MP4 via ffmpeg (same flags as Python).
    @discardableResult
    public static func burnASSSubtitles(
        inputMedia: URL,
        assURL: URL,
        outputURL: URL,
        overwrite: Bool = true
    ) throws -> URL {
        let tools = detect()
        guard tools.isAvailable, let ffmpeg = tools.ffmpeg else {
            throw MossError.generationFailed("ffmpeg and ffprobe are required for video rendering.")
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Match Python: run with cwd = ASS parent so `subtitles=filename` resolves.
        _ = try run(
            ffmpeg,
            arguments: [
                overwrite ? "-y" : "-n",
                "-i", inputMedia.path,
                "-vf", "subtitles=\(assURL.lastPathComponent)",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "18",
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputURL.path,
            ],
            currentDirectory: assURL.deletingLastPathComponent()
        )
        return outputURL
    }

    // MARK: - Process helpers

    private static func which(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    @discardableResult
    private static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw MossError.generationFailed(
                "Command failed (\(process.terminationStatus)): \(executable) \(arguments.joined(separator: " "))\n\(err)"
            )
        }
        return out
    }
}
