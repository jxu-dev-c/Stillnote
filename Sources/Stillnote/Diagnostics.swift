import Foundation
import StillnoteCore

/// A one-shot report of everything the app resolves at startup, so a broken install can
/// be diagnosed without opening the window.
enum Diagnostics {
    static func report() -> String {
        var lines = ["Stillnote diagnostics"]
        if let checkout = Paths.enclosingCheckout() {
            lines.append("Checkout:        \(checkout.path)")
        } else {
            lines.append("Checkout:        not found (running outside a source checkout)")
        }
        guard let paths = try? Paths.standard() else {
            lines.append("Data:            unavailable — could not open Application Support")
            return lines.joined(separator: "\n")
        }
        lines.append("Data:            \(paths.dataDirectory.path)")
        lines.append("Models:          \(paths.modelDirectory.path)")

        lines.append("MOSS worker:     \(SpeechWorkerLocator.workerURL()?.path ?? "not found")")
        lines.append("MOSS runtime:    \(SpeechWorkerLocator.runtimeReady() ? "ready" : "missing dependencies")")

        let speech = SpeechStatus.current(modelDirectory: paths.modelDirectory)
        lines.append("Speech model:    \(speech.modelInstalled ? "installed" : "not installed")")
        lines.append("Transcription:   \(speech.ready ? "ready" : "unavailable — \(speech.detail)")")

        for agent in AgentRunner.availability() {
            lines.append(
                "\(agent.provider.label.padding(toLength: 16, withPad: " ", startingAt: 0))"
                    + (agent.installed ? "installed" : "not on PATH")
            )
        }
        let capabilities = CaptureDeviceCatalog.capabilities()
        lines.append("Capture:         \(capabilities.available ? "available" : capabilities.reason ?? "unavailable")")
        lines.append("Microphones:     \(capabilities.microphones.count)")
        lines.append("Displays:        \(capabilities.displays.count)")
        return lines.joined(separator: "\n")
    }
}
