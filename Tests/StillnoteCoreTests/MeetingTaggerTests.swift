import Foundation
import Testing

@testable import StillnoteCore

/// What a tag request sends and how its answer is read, against a stubbed Responses API.
/// `OpenAIIntegrationTests` makes the real request.
@Suite(.serialized) struct MeetingTaggerTests {
    private let tags = [
        MeetingTag(id: "t-sales", name: "Sales", color: .green, position: 1),
        MeetingTag(id: "t-eng", name: "Engineering", color: .blue, position: 0),
        MeetingTag(id: "t-hr", name: "Hiring", color: .pink, position: 2),
    ]

    private func meeting(_ text: String = "We should ship the Q4 launch.") -> Meeting {
        var meeting = Meeting(id: "m1", title: "Launch sync", audioName: "recording.wav", language: "en",
                              speakerCount: nil, duration: 60)
        meeting.speakers = ["speaker_1": "Dana"]
        meeting.segments = [Segment(id: "1", start: 0, end: 1, speaker: "speaker_1", text: text)]
        return meeting
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesStub.self]
        return URLSession(configuration: configuration)
    }

    private static func reply(_ text: String) -> [String: Any] {
        [
            "status": "completed",
            "output": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "content": [["type": "output_text", "text": text]]],
            ],
        ]
    }

    private func suggest(_ meeting: Meeting? = nil) async throws -> [String] {
        try await MeetingTagger.suggestTags(
            meeting: meeting ?? self.meeting(), tags: tags, settings: TaggingSettings(), allowRemote: true,
            apiKey: "sk-test", session: session()
        )
    }

    @Test func sendsAStrictSchemaLimitedToTheTagIDs() async throws {
        ResponsesStub.reset(status: 200, body: Self.reply(#"{"tag_ids":["t-eng"]}"#))
        #expect(try await suggest() == ["t-eng"])

        let request = try #require(ResponsesStub.lastRequest)
        #expect(request.url == OpenAIResponses.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(ResponsesStub.lastBody)
        #expect(body["model"] as? String == TaggingSettings.defaultModel)
        #expect(body["store"] as? Bool == false)
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        let items = ((schema["properties"] as? [String: Any])?["tag_ids"] as? [String: Any])?["items"] as? [String: Any]
        #expect(items?["enum"] as? [String] == ["t-sales", "t-eng", "t-hr"])
        let input = try #require(body["input"] as? String)
        #expect(input.contains(#"{"id":"t-eng","name":"Engineering"}"#))
        #expect(input.contains("Dana: We should ship the Q4 launch."))
    }

    @Test func keepsOnlyKnownTagsInSidebarOrder() async throws {
        ResponsesStub.reset(status: 200, body: Self.reply(#"{"tag_ids":["t-hr","made-up","t-eng","t-hr"]}"#))
        #expect(try await suggest() == ["t-eng", "t-hr"])
        ResponsesStub.reset(status: 200, body: Self.reply(#"{"tag_ids":[]}"#))
        #expect(try await suggest().isEmpty)
    }

    @Test func prefersTheSummaryOverTheTranscript() throws {
        var summarized = meeting("TRANSCRIPT ONLY")
        summarized.summary = MeetingSummary(
            overview: "Hiring plan for Q4.", keyPoints: ["Two roles"], decisions: ["Open both"],
            actionItems: [], provider: "codex", model: "m", generatedAt: Meeting.now()
        )
        let input = try MeetingTagger.input(summarized, tags: tags)
        #expect(input.contains("Hiring plan for Q4."))
        #expect(!input.contains("TRANSCRIPT ONLY"))
        #expect(input.contains("not instructions"))
    }

    @Test func reportsRefusalsErrorsAndIncompleteResponses() async throws {
        ResponsesStub.reset(status: 200, body: [
            "status": "completed",
            "output": [["type": "message", "content": [["type": "refusal", "refusal": "Can't help."]]]],
        ])
        await #expect(throws: SummaryError.self) { try await suggest() }

        ResponsesStub.reset(status: 401, body: ["error": ["message": "Incorrect API key provided."]])
        do {
            _ = try await suggest()
            Issue.record("A rejected key should throw")
        } catch let error as SummaryError {
            #expect(error.message.contains("rejected the API key"))
            #expect(error.message.contains("Incorrect API key provided."))
            #expect(!error.message.contains("sk-test"))
        }

        ResponsesStub.reset(status: 200, body: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]])
        await #expect(throws: SummaryError.self) { try await suggest() }

        ResponsesStub.reset(status: 200, body: Self.reply("not json"))
        await #expect(throws: SummaryError.self) { try await suggest() }
    }

    @Test func needsConsentAndSendsNothingWithoutTags() async throws {
        ResponsesStub.reset(status: 200, body: Self.reply(#"{"tag_ids":["t-eng"]}"#))
        await #expect(throws: SummaryError.self) {
            try await MeetingTagger.suggestTags(
                meeting: meeting(), tags: tags, settings: TaggingSettings(), allowRemote: false,
                apiKey: "sk-test", session: session()
            )
        }
        let none = try await MeetingTagger.suggestTags(
            meeting: meeting(), tags: [], settings: TaggingSettings(), allowRemote: true,
            apiKey: "sk-test", session: session()
        )
        #expect(none.isEmpty)
        #expect(ResponsesStub.lastRequest == nil)
    }

    @Test func modelSettingFallsBackAndRejectsJunk() throws {
        #expect(try TaggingSettings(model: "  ").resolvedModel() == TaggingSettings.defaultModel)
        #expect(try TaggingSettings(model: "gpt-5.4-nano").resolvedModel() == "gpt-5.4-nano")
        #expect(throws: SummaryError.self) { try TaggingSettings(model: "gpt 5").resolvedModel() }
    }

    @Test func settingsWithoutTaggingDecodeWithDefaults() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        )
        object["tagging"] = nil
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.tagging == TaggingSettings())
        #expect(!decoded.tagging.autoTagAfterSummary)
        #expect(AppSettings.migrating(from: object).settings.tagging == TaggingSettings())

        var settings = AppSettings()
        settings.tagging = TaggingSettings(autoTagAfterSummary: true, model: "gpt-5.4-nano")
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).tagging == settings.tagging)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(AppSettings.migrating(from: raw).settings.tagging == settings.tagging)
    }

    @Test func credentialsPreferTheEnvironmentOverNothing() {
        let found = OpenAICredentials.resolve(
            environment: ["OPENAI_API_KEY": "  sk-env  "], useKeychain: false, useShell: false
        )
        #expect(found?.key == "sk-env")
        #expect(found?.source == .environment)
        #expect(OpenAICredentials.resolve(environment: ["OPENAI_API_KEY": ""], useKeychain: false, useShell: false) == nil)
    }
}

/// Answers every request with the configured status and JSON body, and keeps the last request.
private final class ResponsesStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: [String: Any] = [:]
    nonisolated(unsafe) private static var request: URLRequest?
    nonisolated(unsafe) private static var sent: [String: Any]?

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var lastBody: [String: Any]? { lock.withLock { sent } }

    static func reset(status: Int, body: [String: Any]) {
        lock.withLock {
            self.status = status
            self.body = body
            request = nil
            sent = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let (status, body) = Self.lock.withLock {
            Self.request = request
            Self.sent = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (Self.status, Self.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
