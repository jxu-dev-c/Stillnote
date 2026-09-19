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
