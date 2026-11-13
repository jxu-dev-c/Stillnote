import Foundation

/// One structured-output request to OpenAI's Responses API. Stillnote's other provider work
/// goes through the user's own agent CLIs; meeting tags are a small classification that a direct
/// API call answers faster and more cheaply.
public struct OpenAIResponses: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    let apiKey: String
    let session: URLSession
    let timeout: TimeInterval

    public init(apiKey: String, session: URLSession? = nil, timeout: TimeInterval = 60) {
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.timeout = timeout
    }

    /// The request body. `store: false` keeps the exchange out of OpenAI's stored responses.
    static func body(
        model: String, instructions: String, input: String, schemaName: String, schema: [String: Any],
        reasoningEffort: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "text": [
                "format": [
                    "type": "json_schema", "name": schemaName, "strict": true, "schema": schema,
                ] as [String: Any],
            ],
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }
        return body
    }

    /// Sends the request and returns the decoded JSON object the schema describes.
    public func requestJSON(
        model: String, instructions: String, input: String, schemaName: String, schema: [String: Any],
        reasoningEffort: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(
            model: model, instructions: instructions, input: input, schemaName: schemaName, schema: schema,
            reasoningEffort: reasoningEffort
        ))
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
        return try Self.parse(data, status: status)
    }

    /// Reads the first `output_text` of the response's message. A refusal, an incomplete
    /// response, or an HTTP error becomes a `SummaryError` carrying OpenAI's own explanation.
    static func parse(_ data: Data, status: Int) throws -> [String: Any] {
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
        if let state = object["status"] as? String, state != "completed" {
            let reason = ((object["incomplete_details"] as? [String: Any])?["reason"] as? String).map { " (\($0))" } ?? ""
            throw SummaryError("OpenAI didn't finish the response\(reason). Try again.")
        }
        let content = (object["output"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        if let refusal = content.first(where: { $0["type"] as? String == "refusal" })?["refusal"] as? String {
            throw SummaryError("OpenAI declined the request: \(refusal.prefix(300))")
        }
        guard let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String,
              let result = Summarizer.jsonObject(text)
        else {
            throw SummaryError("OpenAI didn't return the expected JSON. Retry or choose another model.")
        }
        return result
    }
}
