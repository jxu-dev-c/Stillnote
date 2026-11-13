import Foundation
import CoreFoundation

/// Typed predicate questions evaluated by OpenAI’s Decisions API.
public struct OpenAIDecisions: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!

    let apiKey: String
    let session: URLSession
    let timeout: TimeInterval

    public init(apiKey: String, session: URLSession? = nil, timeout: TimeInterval = 60) {
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.timeout = timeout
    }

    /// Evaluates independent predicates against shared meeting evidence.
    public func predicates(model: String, input: String, questions: [[String: String]]) async throws -> [String: Double] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": input, "questions": questions,
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SummaryError(error.code == .timedOut
                ? "OpenAI didn't answer in time. Try again."
                : "Couldn't reach OpenAI: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.parse(data, status: status, expectedNames: Set(questions.compactMap { $0["name"] }))
    }

    /// Reject incomplete or malformed answers before any tags are applied.
    static func parse(_ data: Data, status: Int, expectedNames: Set<String>) throws -> [String: Double] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
                .map { ": " + String($0.prefix(300)) } ?? "."
            switch status {
            case 401: throw SummaryError("OpenAI rejected the API key\(detail)")
            case 429: throw SummaryError("OpenAI is rate limiting requests or the account is out of credit\(detail)")
            default: throw SummaryError("OpenAI returned HTTP \(status)\(detail)")
            }
        }
        guard let object else { throw SummaryError("OpenAI returned a response Stillnote couldn't read.") }
        guard let answers = object["answers"] as? [[String: Any]] else {
            throw SummaryError("OpenAI didn't return decision answers. Try again.")
        }
        var result: [String: Double] = [:]
        for answer in answers {
            guard let name = answer["name"] as? String, expectedNames.contains(name), result[name] == nil else {
                throw SummaryError("OpenAI returned unexpected or duplicate decision answers. Try again.")
            }
            if answer["type"] as? String == "refusal" {
                throw SummaryError("OpenAI declined a tag decision. Try again.")
            }
            guard answer["type"] as? String == "predicate",
                  let number = answer["probability"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (0...1).contains(number.doubleValue) else {
                throw SummaryError("OpenAI returned an invalid decision probability. Try again.")
            }
            result[name] = number.doubleValue
        }
        guard Set(result.keys) == expectedNames else {
            throw SummaryError("OpenAI didn't answer every tag decision. Try again.")
        }
        return result
    }
}
