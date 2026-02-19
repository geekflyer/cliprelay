import Foundation

struct ChunkHeader: Codable {
    let tx_id: String?
    let total_chunks: Int
    let total_bytes: Int
    let encoding: String
}

final class ChunkAssembler {
    private var expectedChunks = 0
    private var expectedBytes = 0
    private(set) var encoding = "utf-8"
    private var chunks: [Int: Data] = [:]

    func reset(with header: ChunkHeader) {
        expectedChunks = header.total_chunks
        expectedBytes = header.total_bytes
        encoding = header.encoding
        chunks.removeAll(keepingCapacity: true)
    }

    func clear() {
        expectedChunks = 0
        expectedBytes = 0
        encoding = "utf-8"
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

    func assembleData() -> Data? {
        guard isComplete() else { return nil }
        var output = Data(capacity: expectedBytes)
        for i in 0..<expectedChunks {
            guard let chunk = chunks[i] else { return nil }
            output.append(chunk)
        }
        return output
    }
}
