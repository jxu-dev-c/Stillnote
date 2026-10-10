import Foundation
import Testing
@testable import StillnoteCore

struct NemotronWorkerRequestTests {
    private func request(
        language: String = "en-US", speakerCount: Int? = nil, hotWords: [String] = [],
        geometry: NemotronWorkerRequest.Geometry = .offline, pcmPath: String? = "/tmp/a.f32"
    ) -> NemotronWorkerRequest {
        NemotronWorkerRequest(
            asrModelPath: "/models/speech/nemotron-asr-0.6b",
            diarizerModelPath: "/models/speech/nemotron-diarize-100m",
            pcmPath: pcmPath, language: language, speakerCount: speakerCount,
            hotWords: hotWords, geometry: geometry
        )
    }

    @Test func roundTripsThroughJSON() throws {
        let original = request(language: "de-DE", speakerCount: 3, hotWords: ["Acme Corp"])
        let decoded = try NemotronWorkerRequest(json: try original.encoded())
        #expect(decoded == original)
    }

    @Test func capsSpeakersAtTheDiarizersChannels() {
        #expect(request(speakerCount: 20).speakerCount == 8)
        #expect(request(speakerCount: 8).speakerCount == 8)
        #expect(request(speakerCount: 2).speakerCount == 2)
        #expect(request(speakerCount: 0).speakerCount == 1)
        #expect(request(speakerCount: nil).speakerCount == nil)
    }

    @Test func normalizesHotWordsLikeTheSettingsDocument() {
        let built = request(hotWords: ["  Acme  ", "", "Acme", "Zephyr"])
        #expect(built.hotWords == ["Acme", "Zephyr"])
    }

    @Test func emptyLanguageMeansAuto() {
        #expect(request(language: "").language == "auto")
        #expect(request(language: "   ").language == "auto")
    }

    /// The bundle ships bare codes for most languages but only locales for Chinese and
    /// Japanese, and the runtime falls back to the auto slot for a tag it does not know.
    @Test func mapsTheLanguagesTheBundleOnlyShipsAsLocales() {
        #expect(request(language: "zh").language == "zh-CN")
        #expect(request(language: "ja").language == "ja-JP")
        #expect(request(language: "ZH").language == "zh-CN")
    }

    @Test func passesThroughTagsTheBundleAlreadyKnows() {
        for tag in ["en", "es", "fr", "de", "it", "pt", "ko", "ar", "hi", "nl", "ru",
                    "en-GB", "zh-TW", "auto"] {
            #expect(request(language: tag).language == tag)
        }
    }

    @Test func geometryCarriesTheDiarizersChunkShape() {
        #expect(NemotronWorkerRequest.Geometry.offline.coreEncoderFrames == 340)
        #expect(NemotronWorkerRequest.Geometry.offline.rightContextEncoderFrames == 40)
        // The live geometry must stay inside the fixed graph's 380-frame pre-encoder input.
        let live = NemotronWorkerRequest.Geometry.live
        #expect(live.coreEncoderFrames + live.rightContextEncoderFrames <= 380)
        #expect(live.coreEncoderFrames < NemotronWorkerRequest.Geometry.offline.coreEncoderFrames)
    }

    @Test func refusesMalformedInput() {
        #expect(throws: SpeechError.self) { try NemotronWorkerRequest(json: "not json") }
        #expect(throws: SpeechError.self) { try NemotronWorkerRequest(json: "{}") }
    }

    @Test func refusesAMissingModelDirectory() throws {
        var broken = request()
        broken.asrModelPath = ""
        #expect(throws: SpeechError.self) { try NemotronWorkerRequest(json: try broken.encoded()) }
    }

    @Test func refusesAnOfflineRequestWithoutAudio() throws {
        let broken = request(pcmPath: nil)
        #expect(throws: SpeechError.self) { try NemotronWorkerRequest(json: try broken.encoded()) }
    }

    @Test func allowsALiveRequestWithoutAudioBecauseItArrivesOnStdin() throws {
        let live = request(geometry: .live, pcmPath: nil)
        let decoded = try NemotronWorkerRequest(json: try live.encoded())
        #expect(decoded.pcmPath == nil)
        #expect(decoded.geometry == .live)
    }

    @Test func refusesASpeakerCountOutsideTheDiarizersRange() throws {
        // The initializer clamps, so a hand-built payload is the only way in — and it is
        // exactly what the worker has to defend against.
        let payload = """
        {"asrModelPath":"/a","diarizerModelPath":"/b","pcmPath":"/c","language":"en",\
        "speakerCount":12,"hotWords":[],"geometry":"offline"}
        """
        #expect(throws: SpeechError.self) { try NemotronWorkerRequest(json: payload) }
    }

    @Test func theServiceBuildsBothModelPathsFromOneModelDirectory() throws {
        let service = TranscriptionService(modelDirectory: URL(fileURLWithPath: "/models"))
        let arguments = try service.nemotronArguments(
            pcmURL: URL(fileURLWithPath: "/tmp/clean.f32"), model: SpeechCatalog.nemotronModel,
            language: "en", speakerCount: 2, hotWords: ["Stillnote"]
        )
        #expect(arguments.first == "nemotron")
        let decoded = try NemotronWorkerRequest(json: arguments[1])
        #expect(decoded.asrModelPath == "/models/speech/nemotron-asr-0.6b")
        #expect(decoded.diarizerModelPath == "/models/speech/nemotron-diarize-100m")
        #expect(decoded.pcmPath == "/tmp/clean.f32")
        #expect(decoded.speakerCount == 2)
        #expect(decoded.hotWords == ["Stillnote"])
        #expect(decoded.geometry == .offline)
    }
}
