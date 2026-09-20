import Darwin
import Foundation

/// Resolves exported credentials and PATH without placing them in settings or logs.
/// A fresh login shell also picks up provider switches without restarting Stillnote.
enum AgentEnvironment {
    static func resolve(
        inheritShell: Bool, shellPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        guard inheritShell else { return environment }
        let configured = shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let shell = configured.isEmpty ? (accountShell ?? "/bin/zsh") : configured
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
            throw SummaryError("The summary shell is not executable. Choose its full path in Settings → Summaries.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-environment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("environment")
        // The marker separates shell startup chatter from NUL-delimited environment
        // values. No user content or paths are interpolated into shell source.
        let result = try PosixProcess.run(
            executable: shell,
            arguments: ["-ilc", "/usr/bin/printf '\\000STILLNOTE_ENV\\000'; /usr/bin/env -0"],
            workingDirectory: NSHomeDirectory(), input: Data(), stdoutURL: output,
            timeout: 10, environment: environment
        )
        guard !result.timedOut, result.exitCode == 0 else {
            throw SummaryError("Could not load the summary shell environment. Check your shell startup files "
                + "for errors or interactive prompts, or turn off shell inheritance in Settings → Summaries.")
        }
        guard let handle = try? FileHandle(forReadingFrom: output) else {
            throw SummaryError("Could not read the summary shell environment.")
        }
        defer { try? handle.close() }
        let data = (try handle.read(upToCount: 1_048_577)) ?? Data()
        let marker = Data("\0STILLNOTE_ENV\0".utf8)
        guard data.count <= 1_048_576, let range = data.range(of: marker) else {
            throw SummaryError("The summary shell returned invalid environment data. Check the shell in Settings → Summaries.")
        }
        var resolved: [String: String] = [:]
        for item in data[range.upperBound...].split(separator: 0) {
            let entry = String(decoding: item, as: UTF8.self)
            guard let separator = entry.firstIndex(of: "=") else { continue }
            resolved[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        guard !resolved.isEmpty else { throw SummaryError("The summary shell returned an empty environment.") }
        return resolved
    }
}
