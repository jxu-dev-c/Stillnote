import Foundation

/// The app always uses its own signed native worker; source builds use a sibling.
public enum SpeechWorkerLocator {
    public static func workerURL() -> URL? {
        firstExecutable(in: candidates(executableURL: Bundle.main.executableURL,
            command: CommandLine.arguments.first))
    }

    static func candidates(executableURL: URL?, command: String?) -> [URL] {
        var result: [URL] = []
        if let executableURL {
            result.append(executableURL.deletingLastPathComponent().appendingPathComponent("StillnoteSpeechWorker"))
        }
        if let command {
            result.append(URL(fileURLWithPath: command).deletingLastPathComponent().appendingPathComponent("StillnoteSpeechWorker"))
        }
        return result
    }

    static func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func runtimeReady() -> Bool {
        runtimeReady(worker: workerURL())
    }

    static func runtimeReady(worker: URL?) -> Bool {
        guard let worker, FileManager.default.isExecutableFile(atPath: worker.path) else { return false }
        let directory = worker.deletingLastPathComponent()
        return ["mlx.metallib", "Resources/mlx.metallib"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    public static let repairMessage = "The bundled speech engine is missing or incomplete. Reinstall Stillnote to repair it. Your recordings are saved."
}
