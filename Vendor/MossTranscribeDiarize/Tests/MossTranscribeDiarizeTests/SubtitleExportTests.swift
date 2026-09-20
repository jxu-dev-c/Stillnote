import XCTest
@testable import MossTranscribeDiarize

final class SubtitleExportTests: XCTestCase {
    private let sampleSegments = [
        SubtitleSegment(id: "1", start: 0.5, end: 2.25, speaker: "S01", text: "Hello"),
        SubtitleSegment(id: "2", start: 2.5, end: 4.0, speaker: "S02", text: "World"),
    ]

    func testSRTFormat() {
        let srt = SubtitleExport.exportSRT(sampleSegments)
        XCTAssertTrue(srt.contains("00:00:00,500 --> 00:00:02,250"))
        XCTAssertTrue(srt.contains("S01: Hello"))
        XCTAssertTrue(srt.contains("S02: World"))
    }

    func testASSFormat() {
        let ass = SubtitleExport.exportASS(sampleSegments)
        XCTAssertTrue(ass.contains("[Script Info]"))
        XCTAssertTrue(ass.contains("Dialogue:"))
        XCTAssertTrue(ass.contains("0:00:00.50"))
        XCTAssertTrue(ass.contains("Speaker_S01") || ass.contains("S01: Hello"))
    }

    func testJSONRoundTripShape() throws {
        let json = try SubtitleExport.exportJSON(sampleSegments)
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode([SubtitleSegment].self, from: data)
        XCTAssertEqual(decoded, sampleSegments)
    }

    func testSRTTimeFormatting() {
        XCTAssertEqual(SubtitleExport.formatSRTTime(0), "00:00:00,000")
        XCTAssertEqual(SubtitleExport.formatSRTTime(3661.5), "01:01:01,500")
    }

    func testASSTimeFormatting() {
        XCTAssertEqual(SubtitleExport.formatASSTime(0), "0:00:00.00")
        XCTAssertEqual(SubtitleExport.formatASSTime(65.2), "0:01:05.20")
    }
}
