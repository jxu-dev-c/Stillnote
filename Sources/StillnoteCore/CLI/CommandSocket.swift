import Darwin
import Foundation

/// A Unix domain socket carrying one newline-delimited JSON request and one response.
///
/// It is a filesystem object under the library directory, not a network port: nothing binds an
/// address, and only this macOS user can reach it. The app is the single writer to the store,
/// so every change the CLI makes arrives through here and the open window updates with it.
public enum CommandSocket {
    /// `sockaddr_un.sun_path` is a fixed 104-byte field on Darwin. A long `STILLNOTE_DATA_DIR`
    /// can overflow it, and silently truncating would point at a different path.
    public static let maximumPathLength = 103

    public static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else {
            throw CLIError.failed(
                "The command socket path is \(bytes.count) bytes, over the \(maximumPathLength)-byte "
                    + "limit macOS allows. Point STILLNOTE_DATA_DIR at a shorter path."
            )
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func withAddress<Result>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        var address = try self.address(for: path)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                try body(rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setTimeout(_ descriptor: Int32, _ seconds: Double) {
        var value = timeval(
            tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// True when something is accepting connections at `path`. Used to tell a socket left behind
    /// by a crash from one a second app instance is still serving.
    public static func isListening(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        setTimeout(descriptor, 1)
        return (try? withAddress(path) { pointer, length in
            Darwin.connect(descriptor, pointer, length) == 0
        }) ?? false
    }
}

/// One accepted connection. Reads and writes block, so callers use it off the main actor.
public final class CommandConnection: @unchecked Sendable {
    private var descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32, timeout: Double) {
        self.descriptor = descriptor
        CommandSocket.setTimeout(descriptor, timeout)
    }

    deinit { close() }

    public func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Reads up to the next newline. Returns nil when the peer closed without sending one.
    public func readLine(limit: Int = 8 * 1024 * 1024) throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= limit else { throw CLIError.failed("The command was too large to read.") }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let read = Darwin.read(descriptor, &chunk, chunk.count)
            if read > 0 {
                buffer.append(contentsOf: chunk[0..<read])
                continue
            }
            if read == 0 { return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self) }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw CLIError.failed("Stillnote did not answer in time.")
            }
            throw CLIError.failed("The command connection failed: \(String(cString: strerror(errno))).")
        }
    }

    public func write(line: String) throws {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if errno == EINTR { continue }
            throw CLIError.failed("The command reply could not be sent: \(String(cString: strerror(errno))).")
        }
    }
}

/// The app's end of the socket. Binding is exclusive, so a second app instance finds the socket
/// already served and leaves it alone rather than stealing the name.
public final class CommandListener: @unchecked Sendable {
    public let path: String
    private var descriptor: Int32 = -1

    public init(path: String) throws {
        self.path = path
        if FileManager.default.fileExists(atPath: path) {
            guard !CommandSocket.isListening(at: path) else {
                throw CLIError.failed("Another Stillnote instance is already serving \(path).")
            }
            // Nothing is listening, so this is a socket a crash left behind.
            try? FileManager.default.removeItem(atPath: path)
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIError.failed("A command socket could not be created: \(String(cString: strerror(errno))).")
        }
        do {
            try CommandSocket.withAddress(path) { pointer, length in
                guard Darwin.bind(descriptor, pointer, length) == 0 else {
                    throw CLIError.failed("The command socket could not be bound: \(String(cString: strerror(errno))).")
                }
            }
            guard Darwin.listen(descriptor, 8) == 0 else {
                throw CLIError.failed("The command socket could not listen: \(String(cString: strerror(errno))).")
            }
        } catch {
            close()
            throw error
        }
        // The enclosing directory is already 0700; narrow the socket itself as well.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    deinit { close() }

    /// Blocks until a client connects. Returns nil once the listener is closed.
    public func accept(timeout: Double = 30) -> CommandConnection? {
        while descriptor >= 0 {
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted >= 0 { return CommandConnection(descriptor: accepted, timeout: timeout) }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
        return nil
    }

    public func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// The CLI's end. One connection, one request, one response.
public enum CommandClient {
    public static func send(_ request: CLIRequest, to path: String, timeout: Double) throws -> CLIResponse {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.unavailable("Stillnote is not running.")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIError.failed("A command socket could not be created: \(String(cString: strerror(errno))).")
        }
        var connected = false
        defer { if !connected { close(descriptor) } }
        try CommandSocket.withAddress(path) { pointer, length in
            // Connecting must not inherit the command's timeout: a stale socket should fail fast.
            CommandSocket.setTimeout(descriptor, min(timeout, 5))
            guard Darwin.connect(descriptor, pointer, length) == 0 else {
                throw CLIError.unavailable("Stillnote is not running.")
            }
        }
        connected = true
        let connection = CommandConnection(descriptor: descriptor, timeout: timeout)
        defer { connection.close() }
        let encoder = JSONEncoder()
        let encoded = String(decoding: try encoder.encode(request), as: UTF8.self)
        try connection.write(line: encoded)
        guard let reply = try connection.readLine() else {
            throw CLIError.failed("Stillnote closed the connection without replying.")
        }
        do {
            return try JSONDecoder().decode(CLIResponse.self, from: Data(reply.utf8))
        } catch {
            throw CLIError.failed("Stillnote sent a reply this version does not understand.")
        }
    }
}
