import XCTest
@testable import MossTranscribeDiarize

final class BenchmarkRunnerTests: XCTestCase {
    func testManifestRelativeAudioPathResolvesAgainstManifestDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moss-benchmark-\(UUID().uuidString)", isDirectory: true)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let audioURL = audioDir.appendingPathComponent("sample.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())

        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = """
        {
          "samples": [
            {
              "id": "sample",
              "audio": "audio/sample.wav",
              "expected_speakers": 2
            }
          ]
        }
        """
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let samples = try BenchmarkRunner.loadSamples(from: manifestURL)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].audio, audioURL.path)
        XCTAssertEqual(samples[0].expectedSpeakers, 2)
    }
}
