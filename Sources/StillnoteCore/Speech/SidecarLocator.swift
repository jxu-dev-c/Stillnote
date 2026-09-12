import Foundation

/// Finds the Python interpreter that hosts MOSS inference. Inference is the only part
/// of Stillnote that is not Swift, and it lives in its own virtual environment.
public enum SidecarLocator {
    public static let relativeVenv = ".venv-moss"

    public static func pythonURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["STILLNOTE_MOSS_PYTHON"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            candidates.append(
                support.appendingPathComponent("Stillnote/venv-moss/bin/python", isDirectory: false)
            )
        }
        if let checkout = Paths.enclosingCheckout() {
            candidates.append(checkout.appendingPathComponent("\(relativeVenv)/bin/python"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The worker package lives beside the interpreter's environment in a deployed
    /// install, and in the checkout during development.
    public static func workerRoot(pythonURL: URL) -> URL? {
        let candidates = [
            pythonURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("sidecar", isDirectory: true),
            Paths.enclosingCheckout()?.appendingPathComponent("sidecar", isDirectory: true),
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("moss_worker/__main__.py").path)
        }
    }

    public static func runtimeReady(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let python = pythonURL(environment: environment), workerRoot(pythonURL: python) != nil else {
            return false
        }
        let root = python.deletingLastPathComponent().deletingLastPathComponent()
        let sites = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("lib", isDirectory: true), includingPropertiesForKeys: nil
        ))?.map { $0.appendingPathComponent("site-packages", isDirectory: true) } ?? []
        return sites.contains { site in
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: site.path)) ?? []
            let hasTransformers5 = contents.contains { $0.hasPrefix("transformers-5") }
            let modules = ["mlx", "mlx_audio", "numpy"]
            return hasTransformers5 && modules.allSatisfy { contents.contains($0) }
        }
    }
}
