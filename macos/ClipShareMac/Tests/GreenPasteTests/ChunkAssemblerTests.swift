import Foundation
import XCTest
@testable import GreenPaste

final class ChunkAssemblerTests: XCTestCase {
    func testAssemblesInOrder() {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        let frames = makeChunkFrames(payload: payload)
        let header = ChunkHeader(tx_id: "tx", total_chunks: frames.count, total_bytes: payload.count, encoding: "utf-8")
        let assembler = ChunkAssembler()

        assembler.reset(with: header)
        frames.forEach { assembler.appendChunkFrame($0) }

        XCTAssertTrue(assembler.isComplete())
        XCTAssertEqual(payload, assembler.assembleData())
    }

    func testAssemblesOutOfOrder() {
        let payload = Data((0..<1200).map { UInt8($0 % 255) })
        let frames = makeChunkFrames(payload: payload)
        let header = ChunkHeader(tx_id: "tx", total_chunks: frames.count, total_bytes: payload.count, encoding: "utf-8")
        let assembler = ChunkAssembler()

        assembler.reset(with: header)
        assembler.appendChunkFrame(frames[2])
        assembler.appendChunkFrame(frames[0])
        assembler.appendChunkFrame(frames[1])

        XCTAssertTrue(assembler.isComplete())
        XCTAssertEqual(payload, assembler.assembleData())
    }

    func testIncompleteFramesReturnNil() {
        let payload = Data((0..<1200).map { UInt8($0 % 251) })
        let frames = makeChunkFrames(payload: payload)
        let header = ChunkHeader(tx_id: "tx", total_chunks: frames.count, total_bytes: payload.count, encoding: "utf-8")
        let assembler = ChunkAssembler()

        assembler.reset(with: header)
        assembler.appendChunkFrame(frames[0])
        assembler.appendChunkFrame(frames[1])

        XCTAssertFalse(assembler.isComplete())
        XCTAssertNil(assembler.assembleData())
    }

    private func makeChunkFrames(payload: Data, chunkPayloadSize: Int = 509) -> [Data] {
        guard !payload.isEmpty else { return [] }
        let total = Int(ceil(Double(payload.count) / Double(chunkPayloadSize)))
        return (0..<total).map { index in
            let start = index * chunkPayloadSize
            let end = min(start + chunkPayloadSize, payload.count)
            var frame = Data()
            frame.append(UInt8((index >> 8) & 0xFF))
            frame.append(UInt8(index & 0xFF))
            frame.append(payload[start..<end])
            return frame
        }
    }
}
