import Foundation

struct ChunkHeader: Codable {
    let total_chunks: Int
    let total_bytes: Int
    let encoding: String
}

final class ChunkAssembler {
    private var expectedChunks = 0
    private var expectedBytes = 0
    private var chunks: [Int: Data] = [:]

    func reset(with header: ChunkHeader) {
        expectedChunks = header.total_chunks
        expectedBytes = header.total_bytes
        chunks.removeAll(keepingCapacity: true)
    }

    func appendChunkFrame(_ frame: Data) {
        guard frame.count >= 2 else { return }
        let index = Int(frame[frame.startIndex]) << 8 | Int(frame[frame.startIndex + 1])
        let payload = frame.dropFirst(2)
        chunks[index] = Data(payload)
    }

    func isComplete() -> Bool {
        guard expectedChunks > 0 else { return false }
        guard chunks.count == expectedChunks else { return false }
        let total = chunks.values.reduce(0) { $0 + $1.count }
        return total == expectedBytes
    }

    func assembleString() -> String? {
        guard isComplete() else { return nil }
        var output = Data(capacity: expectedBytes)
        for i in 0..<expectedChunks {
            guard let chunk = chunks[i] else { return nil }
            output.append(chunk)
        }
        return String(data: output, encoding: .utf8)
    }
}
