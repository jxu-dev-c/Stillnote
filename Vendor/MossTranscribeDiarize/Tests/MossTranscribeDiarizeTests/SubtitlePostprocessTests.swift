import XCTest
@testable import MossTranscribeDiarize

final class SubtitlePostprocessTests: XCTestCase {
    func testFromTranscriptWithoutPostprocess() {
        let text = "[0.0][S01] Hello.[1.0][1.2][S02] World.[2.0]"
        let cues = SubtitlePostprocess.subtitleSegments(from: text, postprocess: false)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].speaker, "S01")
        XCTAssertEqual(cues[1].text, "World.")
    }

    func testMergeAdjacentSameSpeaker() {
        let segments = [
            SubtitleSegment(id: "1", start: 0, end: 1.0, speaker: "S01", text: "Hello"),
            SubtitleSegment(id: "2", start: 1.1, end: 2.0, speaker: "S01", text: "world"),
        ]
        let normalized = SubtitlePostprocess.normalize(
            segments,
            minDuration: 0.2,
            maxDuration: 10,
            maxChars: 40,
            mergeGap: 0.3,
            regenerateIDs: true
        )
        XCTAssertEqual(normalized.count, 1)
        XCTAssertTrue(normalized[0].text.lowercased().contains("hello"))
        XCTAssertTrue(normalized[0].text.lowercased().contains("world"))
    }

    func testPromptHotwords() {
        let prompt = PromptBuilder.make(hotwords: ["OpenMOSS", "MLX"])
        XCTAssertTrue(prompt.contains("热词提示"))
        XCTAssertTrue(prompt.contains("OpenMOSS"))
        XCTAssertTrue(prompt.contains("MLX"))
    }
}
