import Darwin
import Foundation

/// The environment the user's terminal would give a CLI. An app opened from Finder gets a
/// minimal PATH and none of the exports in shell startup files, so it is read from a fresh
/// interactive login shell, which also picks up changes without restarting Stillnote.
enum AgentEnvironment {
    static func resolve(
        shell: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        let accountShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        let shell = shell ?? accountShell ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw SummaryError("Your login shell \(shell) is not executable.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-environment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("environment")
        // The marker separates shell startup chatter from NUL-delimited environment values.
        let result = try PosixProcess.run(
            executable: shell,
            arguments: ["-ilc", "/usr/bin/printf '\\000STILLNOTE_ENV\\000'; /usr/bin/env -0"],
            workingDirectory: NSHomeDirectory(), input: Data(), stdoutURL: output,
            timeout: 10, environment: environment
        )
        guard !result.timedOut, result.exitCode == 0 else {
            throw SummaryError("Could not load your shell environment. Check your shell startup files "
                + "for errors or interactive prompts.")
        }
        let data = (try? Data(contentsOf: output)) ?? Data()
        let marker = Data("\0STILLNOTE_ENV\0".utf8)
        guard data.count <= 1_048_576, let range = data.range(of: marker) else {
            throw SummaryError("Your shell returned invalid environment data.")
        }
        var resolved: [String: String] = [:]
        for item in data[range.upperBound...].split(separator: 0) {
            let entry = String(decoding: item, as: UTF8.self)
            guard let separator = entry.firstIndex(of: "=") else { continue }
            resolved[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        guard !resolved.isEmpty else { throw SummaryError("Your shell returned an empty environment.") }
        return resolved
    }
}
