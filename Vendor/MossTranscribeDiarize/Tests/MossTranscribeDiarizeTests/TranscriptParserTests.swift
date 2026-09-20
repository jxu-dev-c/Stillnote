import XCTest
@testable import MossTranscribeDiarize

final class TranscriptParserTests: XCTestCase {
    func testParseSingleSegment() {
        let text = "[0.06][S01] Hello world.[3.12]"
        let segments = parseTranscript(text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0.06, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 3.12, accuracy: 1e-9)
        XCTAssertEqual(segments[0].speaker, "S01")
        XCTAssertEqual(segments[0].text, "Hello world.")
    }

    func testParseMultipleSegments() {
        let text = """
        [0.10][S01] First turn.[1.20]
        [1.30][S02] Second turn.[2.50]
        """
        let segments = parseTranscript(text)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "S01")
        XCTAssertEqual(segments[1].speaker, "S02")
        XCTAssertEqual(segments[1].text, "Second turn.")
    }

    func testStreamingChunks() {
        let parser = TranscriptStreamParser()
        var segments: [TranscriptSegment] = []
        segments += parser.feed("[0.00][S01] Hel")
        segments += parser.feed("lo[1.00]")
        segments += parser.feed("[1.10][S02]Bye[2.00]")
        segments += parser.close()

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[1].text, "Bye")
        XCTAssertEqual(segments[1].speaker, "S02")
    }

    func testInvalidEndLessThanStartIsTreatedAsText() {
        // end (1.00) < start (5.00) → brackets stay in body until a valid end.
        let text = "[5.00][S01] bad end[1.00][6.00]"
        let segments = parseTranscript(text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 5.00, accuracy: 1e-9)
        XCTAssertEqual(segments[0].end, 6.00, accuracy: 1e-9)
        XCTAssertTrue(segments[0].text.contains("bad end"))
        XCTAssertTrue(segments[0].text.contains("1.00"))
        XCTAssertLessThanOrEqual(segments[0].start, segments[0].end)
    }
}
