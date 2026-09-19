import Darwin
import Foundation

/// Spawns a child in its own session so a timeout can kill the whole process group.
/// Foundation's Process cannot do this, and a coding-agent CLI that keeps running
/// after its temporary workspace is deleted is exactly the failure that matters here.
enum PosixProcess {
    enum SpawnError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    struct Result {
        let exitCode: Int32
        let timedOut: Bool
    }

    /// Runs `executable`, feeding `input` on stdin and writing stdout to `stdoutURL`.
    /// stderr is discarded because agent CLIs echo the prompt into it.
    static func run(
        executable: String, arguments: [String], workingDirectory: String, input: Data,
        stdoutURL: URL, timeout: TimeInterval
    ) throws -> Result {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw SpawnError.message("Could not open a pipe for the agent.") }
        let (readEnd, writeEnd) = (descriptors[0], descriptors[1])

        posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600
        )
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argv: [String] = [executable] + arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        // npm entry points use /usr/bin/env node. Include the selected CLI's bin
        // directory so Finder launches use the runtime installed alongside it.
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        childEnvironment["PATH"] = executableDirectory + ":"
            + (childEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let environment = childEnvironment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(environment) { envPointers in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointers, envPointers)
            }
        }
        close(readEnd)
        guard status == 0 else {
            close(writeEnd)
            throw SpawnError.message("Could not start the agent process.")
        }

        // Feed stdin from another thread: a large transcript would otherwise deadlock
        // against a child that has not started reading yet.
        DispatchQueue.global().async {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(writeEnd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(writeEnd)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var exitStatus: Int32 = 0
        while true {
            let result = waitpid(pid, &exitStatus, WNOHANG)
            if result == pid { break }
            if result == -1 && errno != EINTR {
                return Result(exitCode: -1, timedOut: false)
            }
            if Date() >= deadline {
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &exitStatus, 0)
                return Result(exitCode: -1, timedOut: true)
            }
            usleep(50_000)
        }
        let code = (exitStatus & 0x7F) == 0 ? (exitStatus >> 8) & 0xFF : -1
        return Result(exitCode: code, timedOut: false)
    }

    private static func withCStrings<T>(
        _ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = values.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
