import Foundation
import Testing

@testable import StillnoteCore

struct WorkerOutputTests {
    @Test func deliversProgressBeforeWorkerClosesOutput() async throws {
        let pipe = Pipe()
        let stages = Mutex<[String]>([])
        let collector = WorkerOutput { _, detail in
            stages.withLock { $0.append(detail) }
        }
        let reading = Task { await collector.read(from: pipe.fileHandleForReading) }
        try pipe.fileHandleForWriting.write(contentsOf: Data(
            "STILLNOTE_EVENT {\"type\":\"progress\",\"progress\":40,\"detail\":\"Encoding audio\"}\n".utf8
        ))
        // Keep stdout open, as it is throughout a real transcription. Progress
        // must arrive without waiting for a full buffer or the worker's exit.
        for _ in 0..<100 {
            if stages.withLock({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let deliveredWhileOpen = stages.withLock { $0 == ["Encoding audio"] }
        try pipe.fileHandleForWriting.close()
        await reading.value
        try pipe.fileHandleForReading.close()
        #expect(deliveredWhileOpen)
    }
}

struct WorkerFailureTests {
    @Test func ignoresDiagnosticsAndPreservesSplitUnicode() async throws {
        let pipe = Pipe()
        let collector = WorkerOutput { _, _ in }
        let read = Task { await collector.read(from: pipe.fileHandleForReading) }
        let event = #"STILLNOTE_EVENT {"type":"transcript","transcript":{"language":"zh-CN","#
            + #""words":[{"text":"示例","start":0.5,"end":1.0}],"activity":[{"speaker":0,"start":0,"end":1.5}]}}"#
        let bytes = Data("untrusted library diagnostic\nSTILLNOTE_EVENT invalid\n\(event)".utf8)
        for byte in bytes { try pipe.fileHandleForWriting.write(contentsOf: Data([byte])) }
        try pipe.fileHandleForWriting.close()
        await read.value
        let transcript = await collector.transcript
        #expect(transcript?.words.map(\.text) == ["示例"])
        #expect(transcript?.activity.map(\.speaker) == [0])
        #expect(await collector.error == nil)
    }

    @Test func abnormalExitIsNotASuccessfulTranscript() async throws {
        for _ in 0..<20 {
            await #expect(throws: Error.self) {
                try await SpeechWorkerProcess.run(
                    worker: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
                    failureMessage: "failed"
                ) { _, _ in }
            }
        }
    }

    /// A clean exit that never emitted a transcript leaves nothing to save; the service turns
    /// that into a failure rather than an empty transcript.
    @Test func cleanExitWithoutATranscriptCarriesNone() async throws {
        let collector = try await SpeechWorkerProcess.run(
            worker: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], failureMessage: "failed"
        ) { _, _ in }
        #expect(await collector.transcript == nil)
    }
}
