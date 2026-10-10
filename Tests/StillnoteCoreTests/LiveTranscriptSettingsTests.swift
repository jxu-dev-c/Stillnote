import Foundation
import Testing
@testable import StillnoteCore

struct LiveTranscriptSettingsTests {
    private func decode(_ json: String) throws -> TranscriptionSettings {
        try JSONDecoder().decode(TranscriptionSettings.self, from: Data(json.utf8))
    }

    /// Settings documents written before the live transcript existed must decode, and they
    /// must opt in: the feature is the reason the engine was replaced.
    @Test func olderSettingsDefaultToShowingALiveTranscript() throws {
        let settings = try decode(#"{"model":"nemotron-asr-0.6b","language":"auto"}"#)
        #expect(settings.liveTranscript)
    }

    @Test func roundTripsThroughItsSnakeCaseKey() throws {
        var settings = TranscriptionSettings()
        settings.liveTranscript = false
        let encoded = try JSONEncoder().encode(settings)
        #expect(String(decoding: encoded, as: UTF8.self).contains("live_transcript"))
        #expect(try JSONDecoder().decode(
            TranscriptionSettings.self, from: encoded
        ).liveTranscript == false)
    }

    @Test func honoursAnExplicitFalse() throws {
        let settings = try decode(
            #"{"model":"nemotron-asr-0.6b","language":"auto","live_transcript":false}"#
        )
        #expect(!settings.liveTranscript)
    }

    @Test func newSettingsSelectTheNemotronEngine() {
        #expect(TranscriptionSettings().model == SpeechCatalog.nemotronModel)
        #expect(SpeechCatalog.requiresDiarizer(TranscriptionSettings().model))
    }

    /// Every MOSS user moves to the Nemotron pair on first launch, and the retired Mode
    /// setting in their document is ignored rather than failing the decode.
    @Test func mossSettingsMigrateToNemotronAndDropTheRetiredMode() throws {
        let (settings, changed) = AppSettings.migrating(from: [
            "transcription": ["model": "moss-0.9b", "language": "en", "mode": "low-memory"],
        ])
        #expect(settings.transcription.model == SpeechCatalog.nemotronModel)
        #expect(settings.transcription.language == "en")
        #expect(changed)
        let decoded = try decode(#"{"model":"moss-0.9b","language":"auto","mode":"balanced"}"#)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"mode\""))
    }
}
