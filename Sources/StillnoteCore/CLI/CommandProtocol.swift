import Foundation

/// One `stillnote` invocation, as the CLI parsed it. The running app is the only writer, so
/// the CLI sends this and renders whatever comes back rather than deciding anything itself.
public struct CLIRequest: Codable, Hashable, Sendable {
    /// The matched command path, for example `["transcript", "replace"]`.
    public var command: [String]
    public var positionals: [String]
    public var values: [String: String]
    public var flags: Set<String>
    /// Piped payload, for the commands that read a body from stdin.
    public var standardInput: String?

    enum CodingKeys: String, CodingKey {
        case command, positionals, values, flags
        case standardInput = "standard_input"
    }

    public init(
        command: [String], positionals: [String] = [], values: [String: String] = [:],
        flags: Set<String> = [], standardInput: String? = nil
    ) {
        self.command = command
        self.positionals = positionals
        self.values = values
        self.flags = flags
        self.standardInput = standardInput
    }

    public func value(_ name: String) -> String? { values[name] }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func integer(_ name: String) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let value = Int(raw) else { throw CLIError.usage("--\(name) needs a whole number.") }
        return value
    }
}

/// Pre-encoded JSON. The result shapes belong to the commands, not to the envelope, so the
/// payload travels as encoded text and `--json` prints it back verbatim. That keeps one
/// renderer for both transports: the app over the socket, and the CLI's own read-only path.
public struct CLIJSON: Codable, Hashable, Sendable {
    public let text: String

    public init(text: String) { self.text = text }

    public init<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.text = String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public func decoded<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    public init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Machine-readable outcome, so an agent can branch without parsing prose.
public enum CLICode: String, Codable, Sendable {
    case ok
    /// The app is not running, or its command interface is switched off.
    case unavailable
    /// The app is still opening its library.
    case notReady = "not_ready"
    /// This command changes data or drives capture, which only the running app can do.
    case requiresApp = "requires_app"
    case notFound = "not_found"
    case ambiguous
    case busy
    case usage
    case failed
}

public struct CLIResponse: Codable, Hashable, Sendable {
    public var code: CLICode
    /// What a person reads when `--json` was not passed.
    public var message: String
    public var payload: CLIJSON?

    public var isSuccess: Bool { code == .ok }

    public init(code: CLICode = .ok, message: String, payload: CLIJSON? = nil) {
        self.code = code
        self.message = message
        self.payload = payload
    }

    public static func success<Value: Encodable>(_ message: String, _ payload: Value) throws -> CLIResponse {
        CLIResponse(code: .ok, message: message, payload: try CLIJSON(payload))
    }

    /// Renders an error the same way whichever side produced it.
    public static func failure(_ error: Error) -> CLIResponse {
        if let error = error as? CLIError { return error.response }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return CLIResponse(code: .failed, message: message)
    }
}

public enum CLIError: LocalizedError {
    case usage(String)
    case notFound(String)
    case ambiguous(String)
    case busy(String)
    case unavailable(String)
    case notReady(String)
    case requiresApp(String)
    case failed(String)

    public var message: String {
        switch self {
        case .usage(let text), .notFound(let text), .ambiguous(let text), .busy(let text),
             .unavailable(let text), .notReady(let text), .requiresApp(let text), .failed(let text):
            return text
        }
    }

    public var code: CLICode {
        switch self {
        case .usage: return .usage
        case .notFound: return .notFound
        case .ambiguous: return .ambiguous
        case .busy: return .busy
        case .unavailable: return .unavailable
        case .notReady: return .notReady
        case .requiresApp: return .requiresApp
        case .failed: return .failed
        }
    }

    public var errorDescription: String? { message }
    public var response: CLIResponse { CLIResponse(code: code, message: message) }
}
