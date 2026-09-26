import Foundation
import StillnoteCore

/// `stillnote` — read and correct your meetings, and drive recording, from a terminal or an agent.
///
/// The running app owns the library: it is the only writer, and the only process that can record
/// (capture permissions are granted to the signed app bundle, not to whatever launched this).
/// So this is a thin client over the app's command socket. When the app is closed, read-only
/// commands still work by opening the SQLite library directly.
@main
struct StillnoteCLI {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        if argv.first == "--version" || argv.first == "-v" {
            print(version())
            exit(0)
        }
        if argv.isEmpty || argv.first == "--help" || argv.first == "-h" {
            print(CommandCatalog.help())
            exit(argv.isEmpty ? 2 : 0)
        }

        var wantsJSON = false
        do {
            let invocation = try CommandCatalog.parse(argv, standardInput: readStandardInput())
            wantsJSON = invocation.wantsJSON
            let response = await run(invocation)
            emit(response, json: invocation.wantsJSON)
            exit(exitCode(response.code))
        } catch {
            emit(CLIResponse.failure(error), json: wantsJSON)
            exit(exitCode((error as? CLIError)?.code ?? .failed))
        }
    }

    static func run(_ invocation: CLIInvocation) async -> CLIResponse {
        if invocation.spec.path == ["help"] { return CommandRunner.help(invocation.request) }
        let paths = Paths.resolve()
        do {
            return try CommandClient.send(
                invocation.request, to: paths.commandSocketURL.path, timeout: invocation.timeout
            )
        } catch let error as CLIError where error.code == .unavailable {
            return await offline(invocation, paths: paths, reason: error.message)
        } catch {
            return CLIResponse.failure(error)
        }
    }

    /// The app is closed. Answer what can be answered from the library itself, and say plainly
    /// why anything else cannot be done.
    static func offline(_ invocation: CLIInvocation, paths: Paths, reason: String) async -> CLIResponse {
        guard !invocation.spec.requiresApp else {
            return CLIResponse(
                code: .requiresApp,
                message: "\(reason) '\(invocation.spec.name)' changes data or drives recording, "
                    + "which only the running app can do. Open Stillnote and try again."
            )
        }
        do {
            let store = try Store(paths: paths, readOnly: true)
            if invocation.spec.path == ["status"] {
                return try CommandRunner.offlineStatus(
                    paths: paths, meetings: try await store.list().count
                )
            }
            guard let response = try await CommandRunner.read(invocation.request, store: store) else {
                return CLIResponse(
                    code: .requiresApp,
                    message: "\(reason) Open Stillnote to run '\(invocation.spec.name)'."
                )
            }
            return response
        } catch let error as StoreError {
            // No library at all is a different problem from a closed app, and says so.
            if invocation.spec.path == ["status"] {
                return (try? CommandRunner.offlineStatus(paths: paths, meetings: nil))
                    ?? CLIResponse.failure(error)
            }
            return CLIResponse(code: .unavailable, message: error.localizedDescription)
        } catch {
            return CLIResponse.failure(error)
        }
    }

    // MARK: - Presentation

    static func emit(_ response: CLIResponse, json: Bool) {
        if json {
            print(jsonLine(response))
        } else if response.isSuccess {
            print(response.message)
        } else {
            FileHandle.standardError.write(Data((response.message + "\n").utf8))
        }
    }

    /// `--json` prints one object: the envelope, with the payload spliced in unescaped so a
    /// consumer reads real JSON rather than a string holding JSON.
    static func jsonLine(_ response: CLIResponse) -> String {
        var fields = [
            "\"code\": \(quoted(response.code.rawValue))",
            "\"ok\": \(response.isSuccess)",
            "\"message\": \(quoted(response.message))",
        ]
        if let payload = response.payload {
            // The payload arrives already pretty-printed; re-indent it so the whole object reads
            // as one document rather than two nested ones.
            let indented = payload.text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { $0.offset == 0 ? String($0.element) : "  " + $0.element }
                .joined(separator: "\n")
            fields.append("\"result\": \(indented)")
        }
        return "{\n  " + fields.joined(separator: ",\n  ") + "\n}"
    }

    static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    static func exitCode(_ code: CLICode) -> Int32 {
        switch code {
        case .ok: return 0
        case .usage: return 2
        case .unavailable, .requiresApp, .notReady: return 3
        case .notFound, .ambiguous: return 4
        case .busy: return 5
        case .failed: return 1
        }
    }

    /// The CLI ships at `<App>.app/Contents/Helpers/stillnote`, so `Bundle.main` is not the app
    /// bundle. Read the bundle's Info.plist relative to this executable instead, resolving
    /// symlinks first because Homebrew links the command onto PATH.
    static func version() -> String {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let version = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            .flatMap { ($0 as? [String: Any])?["CFBundleShortVersionString"] as? String }
        return "stillnote \(version ?? "development build")"
    }

    /// Only the commands that declare `--stdin` or `--json-stdin` drain the pipe, so an
    /// interactive invocation never blocks waiting for input that is not coming.
    static func readStandardInput() -> String? {
        guard let data = try? FileHandle.standardInput.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
