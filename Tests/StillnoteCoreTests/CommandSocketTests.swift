import Foundation
import Testing

@testable import StillnoteCore

/// Short directory names on purpose: `sockaddr_un.sun_path` is only 104 bytes, and the system
/// temporary directory already spends some of them.
private func socketPath() -> String {
    let directory = "/tmp/sn-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    return directory + "/cli.sock"
}

/// Answers one request per connection on a background thread, the way the app's server does.
private func serve(
    _ listener: CommandListener, count: Int = 1, handler: @escaping @Sendable (CLIRequest) -> CLIResponse
) {
    Thread.detachNewThread {
        for _ in 0..<count {
            guard let connection = listener.accept() else { return }
            defer { connection.close() }
            guard let line = try? connection.readLine(),
                  let request = try? JSONDecoder().decode(CLIRequest.self, from: Data(line.utf8)),
                  let encoded = try? JSONEncoder().encode(handler(request))
            else { continue }
            try? connection.write(line: String(decoding: encoded, as: UTF8.self))
        }
    }
}

@Suite struct CommandSocketTests {
    @Test func roundTripsARequestAndItsResponse() throws {
        let path = socketPath()
        let listener = try CommandListener(path: path)
        defer { listener.close() }
        serve(listener) { request in
            CLIResponse(code: .ok, message: "saw \(request.command.joined(separator: " "))")
        }
        let response = try CommandClient.send(
            CLIRequest(command: ["record", "status"]), to: path, timeout: 5
        )
        #expect(response.code == .ok)
        #expect(response.message == "saw record status")
    }

    @Test func carriesAPayloadAcrossTheSocket() throws {
        let path = socketPath()
        let listener = try CommandListener(path: path)
        defer { listener.close() }
        serve(listener) { _ in
            (try? CLIResponse.success("listed", ListPayload([])))
                ?? CLIResponse(code: .failed, message: "no")
        }
        let response = try CommandClient.send(CLIRequest(command: ["list"]), to: path, timeout: 5)
        #expect(try response.payload?.decoded(ListPayload.self).count == 0)
    }

    /// A body with newlines in it must not be read as two requests.
    @Test func framingSurvivesEmbeddedNewlines() throws {
        let path = socketPath()
        let listener = try CommandListener(path: path)
        defer { listener.close() }
        serve(listener) { request in
            CLIResponse(code: .ok, message: request.standardInput ?? "")
        }
        let body = "first line\nsecond line\n\nfourth"
        let response = try CommandClient.send(
            CLIRequest(command: ["notes", "set"], standardInput: body), to: path, timeout: 5
        )
        #expect(response.message == body)
    }

    /// Both "no socket at all" and "a socket nothing is serving" have to read as unavailable, so
    /// the CLI can fall back to its read-only path instead of waiting.
    @Test func reportsAClosedAppRatherThanHanging() throws {
        let path = socketPath()
        for stale in [false, true] {
            if stale { FileManager.default.createFile(atPath: path, contents: Data()) }
            do {
                _ = try CommandClient.send(CLIRequest(command: ["list"]), to: path, timeout: 1)
                Issue.record("a socket nobody is serving should not succeed")
            } catch let error as CLIError {
                #expect(error.code == .unavailable)
            }
        }
    }

    /// A socket file a crash left behind is reclaimed; one a live instance is serving is not.
    @Test func reclaimsAStaleSocketButNotALiveOne() throws {
        let path = socketPath()
        let first = try CommandListener(path: path)
        #expect(CommandSocket.isListening(at: path))
        #expect(throws: CLIError.self) { try CommandListener(path: path) }

        first.close()
        #expect(!FileManager.default.fileExists(atPath: path))

        // Leave a plain file where the socket was, as an abrupt termination can.
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(!CommandSocket.isListening(at: path))
        let second = try CommandListener(path: path)
        defer { second.close() }
        #expect(CommandSocket.isListening(at: path))
    }

    @Test func socketIsReadableOnlyByItsOwner() throws {
        let path = socketPath()
        let listener = try CommandListener(path: path)
        defer { listener.close() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    /// Truncating an over-long path would silently point the CLI at a different socket.
    @Test func refusesAPathLongerThanSunPath() {
        let long = "/tmp/" + String(repeating: "x", count: CommandSocket.maximumPathLength) + "/cli.sock"
        #expect(throws: CLIError.self) { try CommandSocket.address(for: long) }
        #expect(throws: CLIError.self) { try CommandListener(path: long) }
        #expect(!CommandSocket.isListening(at: long))
    }

    @Test func acceptsAPathExactlyAtTheLimit() throws {
        let padding = CommandSocket.maximumPathLength - "/tmp/.sock".count
        let path = "/tmp/" + String(repeating: "y", count: padding) + ".sock"
        #expect(path.utf8.count == CommandSocket.maximumPathLength)
        let address = try CommandSocket.address(for: path)
        let recovered = withUnsafeBytes(of: address.sun_path) { buffer in
            String(decoding: buffer.prefix(path.utf8.count), as: UTF8.self)
        }
        #expect(recovered == path)
    }

    @Test func acceptReturnsNilOnceTheListenerCloses() throws {
        let path = socketPath()
        let listener = try CommandListener(path: path)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = listener.accept()
            done.signal()
        }
        // Give the accept call a moment to block before closing under it.
        Thread.sleep(forTimeInterval: 0.1)
        listener.close()
        #expect(done.wait(timeout: .now() + 5) == .success)
    }
}
