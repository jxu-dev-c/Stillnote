import Foundation
import MLX

final class PCMSource {
    let count: Int
    private let handle: FileHandle
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        guard size > 0, size % 4 == 0, size <= 5400 * 16000 * 4 else {
            try? handle.close()
            throw MossError.invalidAudio("Invalid PCM audio or recording exceeds 90 minutes.")
        }
        count = Int(size / 4)
    }
    deinit { try? handle.close() }
    func read(_ range: Range<Int>) throws -> MLXArray {
        guard range.lowerBound >= 0, range.upperBound <= count, !range.isEmpty,
              range.count <= 480000 else { throw MossError.invalidAudio("Invalid PCM window.") }
        try handle.seek(toOffset: UInt64(range.lowerBound * 4))
        let data = try handle.read(upToCount: range.count * 4) ?? Data()
        guard data.count == range.count * 4 else { throw MossError.invalidAudio("Truncated PCM audio.") }
        let finite = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                bytes.loadUnaligned(fromByteOffset: $0, as: Float.self).isFinite
            }
        }
        guard finite else { throw MossError.invalidAudio("PCM audio contains non-finite samples.") }
        return MLXArray(data, type: Float.self)
    }
}
