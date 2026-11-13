import Foundation
import Testing

@testable import StillnoteCore

/// What a tag request sends and how its answer is read, against a stubbed Decisions API.
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
        configuration.protocolClasses = [DecisionsStub.self]
        return URLSession(configuration: configuration)
    }

    private static func reply(_ selected: [String] = []) -> [String: Any] {
        ["answers": ["t-sales", "t-eng", "t-hr"].reversed().map {
            ["type": "predicate", "name": $0, "probability": selected.contains($0) ? 0.95 : 0.1] as [String: Any]
        }]
    }

    private func suggest(_ meeting: Meeting? = nil) async throws -> [String] {
        try await MeetingTagger.suggestTags(
            meeting: meeting ?? self.meeting(), tags: tags, settings: TaggingSettings(), allowRemote: true,
            apiKey: "sk-test", session: session()
        )
    }

    @Test func sendsIndependentTagPredicatesToDecisions() async throws {
        DecisionsStub.reset(status: 200, body: Self.reply(["t-eng"]))
        #expect(try await suggest() == ["t-eng"])
        let request = try #require(DecisionsStub.lastRequest)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/decisions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(DecisionsStub.lastBody)
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["store"] == nil)
        #expect(body["text"] == nil)
        #expect(body["reasoning"] == nil)
        let questions = try #require(body["questions"] as? [[String: String]])
        #expect(questions.map { $0["name"] } == ["t-eng", "t-sales", "t-hr"])
        #expect(questions.allSatisfy { $0["type"] == "predicate" })
        #expect(questions[0]["instructions"]?.contains("Engineering") == true)
        let input = try #require(body["input"] as? String)
        #expect(input.contains("Dana: We should ship the Q4 launch."))
    }

    @Test func supportsMultipleTagsOrNoneInSidebarOrder() async throws {
        DecisionsStub.reset(status: 200, body: Self.reply(["t-hr", "t-eng"]))
        #expect(try await suggest() == ["t-eng", "t-hr"])
        DecisionsStub.reset(status: 200, body: Self.reply())
        #expect(try await suggest().isEmpty)
    }

    @Test func capsStrongestMatchesAndUsesProbabilityThreshold() async throws {
        let catalog = (0..<8).map { MeetingTag(id: "t-\($0)", name: "Topic \($0)", color: .blue, position: $0) }
        let scores = [0.79, 0.8, 0.81, 0.82, 0.83, 0.84, 0.85, 0.86]
        DecisionsStub.reset(status: 200, body: ["answers": catalog.enumerated().map {
            ["type": "predicate", "name": $0.element.id, "probability": scores[$0.offset]] as [String: Any]
        }])
        let chosen = try await MeetingTagger.suggestTags(
            meeting: meeting(), tags: catalog, settings: TaggingSettings(), allowRemote: true,
            apiKey: "sk-test", session: session()
        )
        #expect(chosen == ["t-3", "t-4", "t-5", "t-6", "t-7"])
    }

    @Test func splitsLargeCatalogsAtTheAPIQuestionLimit() async throws {
        let catalog = (0..<401).map { MeetingTag(id: "t-\($0)", name: "Topic \($0)", color: .blue, position: $0) }
        DecisionsStub.reset(status: 200, body: [:], answerQuestions: true)
        let chosen = try await MeetingTagger.suggestTags(
            meeting: meeting(), tags: catalog, settings: TaggingSettings(), allowRemote: true,
            apiKey: "sk-test", session: session()
        )
        #expect(chosen == ["t-0", "t-1", "t-2", "t-3", "t-4"])
        #expect(DecisionsStub.questionCounts == [400, 1])
    }

    @Test func migratesPersistedPreviousDefault() throws {
        let data = Data(#"{"model":"gpt-5.4-mini","auto_tag_after_summary":true}"#.utf8)
        let settings = try JSONDecoder().decode(TaggingSettings.self, from: data)
        #expect(settings.model == "gpt-6-luna")
        #expect(settings.autoTagAfterSummary)
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

    @Test func reportsErrorsAndRejectsInvalidAnswers() async throws {
        DecisionsStub.reset(status: 401, body: ["error": ["message": "Incorrect API key provided."]])
        do {
            _ = try await suggest()
            Issue.record("A rejected key should throw")
        } catch let error as SummaryError {
            #expect(error.message.contains("rejected the API key"))
        }
        let invalid: [[String: Any]] = [
            [:], ["answers": []],
            ["answers": [["type": "refusal", "name": "t-eng"]]],
            ["answers": [["type": "predicate", "name": "made-up", "probability": 0.9]]],
            ["answers": [["type": "predicate", "name": "t-eng", "probability": 1.1]]],
            ["answers": [["type": "predicate", "name": "t-eng", "probability": true]]],
            ["answers": [["type": "predicate", "name": "t-eng", "probability": "0.9"]]],
            ["answers": [
                ["type": "predicate", "name": "t-eng", "probability": 0.9],
                ["type": "predicate", "name": "t-eng", "probability": 0.9],
            ]],
        ]
        for body in invalid {
            DecisionsStub.reset(status: 200, body: body)
            await #expect(throws: SummaryError.self) { try await suggest() }
        }
    }

    @Test func needsConsentAndSendsNothingWithoutTags() async throws {
        DecisionsStub.reset(status: 200, body: Self.reply(["t-eng"]))
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
        #expect(DecisionsStub.lastRequest == nil)
    }

    @Test func modelSettingFallsBackAndRejectsJunk() throws {
        #expect(try TaggingSettings(model: "  ").resolvedModel() == TaggingSettings.defaultModel)
        #expect(try TaggingSettings(model: "gpt-5.4-mini").resolvedModel() == "gpt-6-luna")
        #expect(throws: SummaryError.self) { try TaggingSettings(model: "gpt-5.4-nano").resolvedModel() }
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
private final class DecisionsStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: [String: Any] = [:]
    nonisolated(unsafe) private static var request: URLRequest?
    nonisolated(unsafe) private static var sent: [String: Any]?

    nonisolated(unsafe) private static var answerQuestions = false
    nonisolated(unsafe) private static var counts: [Int] = []
    static var questionCounts: [Int] { lock.withLock { counts } }

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var lastBody: [String: Any]? { lock.withLock { sent } }

    static func reset(status: Int, body: [String: Any], answerQuestions: Bool = false) {
        lock.withLock {
            self.answerQuestions = answerQuestions
            counts = []
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
            let questions = Self.sent?["questions"] as? [[String: String]] ?? []
            Self.counts.append(questions.count)
            if Self.answerQuestions {
                return (Self.status, ["answers": questions.map {
                    ["type": "predicate", "name": $0["name"]!, "probability": 0.9] as [String: Any]
                }] as [String: Any])
            }
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
