import Foundation

/// Finds the Python interpreter that hosts MOSS inference. Inference is the only part
/// of Stillnote that is not Swift, and it lives in its own virtual environment with the
/// `moss_worker` package installed into it.
///
/// The environment lives in Homebrew or Application Support rather than a source checkout:
/// a bundled app reading the Documents folder needs permission that macOS cannot grant
/// while the app is still launching, and the read blocks until it can.
public enum SidecarLocator {
    public static func pythonURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        firstExecutable(in: candidates(environment: environment))
    }

    static func firstExecutable(in candidates: [URL]) -> URL? {
        candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func candidates(environment: [String: String]) -> [URL] {
        var candidates: [URL] = []
        if let override = environment["STILLNOTE_MOSS_PYTHON"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/opt/stillnote-runtime/libexec/bin/python"))
        if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            candidates.append(support.appendingPathComponent("Stillnote/venv-moss/bin/python"))
        }
        return candidates
    }

    /// Ready means the interpreter exists and its environment holds the worker package
    /// alongside the pinned MLX and Transformers runtime.
    public static func runtimeReady(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let python = pythonURL(environment: environment) else { return false }
        let root = python.deletingLastPathComponent().deletingLastPathComponent()
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("lib", isDirectory: true), includingPropertiesForKeys: nil
        )) ?? []
        return versions.contains { version in
            let site = version.appendingPathComponent("site-packages", isDirectory: true)
            let contents = Set((try? FileManager.default.contentsOfDirectory(atPath: site.path)) ?? [])
            return contents.contains { $0.hasPrefix("transformers-5") }
                && ["mlx", "mlx_audio", "numpy", "moss_worker"].allSatisfy(contents.contains)
        }
    }
}
