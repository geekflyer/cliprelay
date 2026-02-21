package com.clipshare.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChunkReassemblerTest {
    @Test
    fun reassemblesInOrder() {
        val payload = ByteArray(1000) { i -> (i % 127).toByte() }
        val totalChunks = ChunkTransfer.totalChunks(payload.size)
        val reassembler = ChunkReassembler()

        assertNull(reassembler.consumeFrame(ChunkTransfer.header("tx", totalChunks, payload.size)))
        var result: AssembledPayload? = null
        for (index in 0 until totalChunks) {
            result = reassembler.consumeFrame(ChunkTransfer.chunk(payload, index))
        }

        requireNotNull(result)
        assertEquals("utf-8", result.encoding)
        assertArrayEquals(payload, result.bytes)
    }

    @Test
    fun reassemblesOutOfOrder() {
        val payload = ByteArray(1200) { i -> (i % 251).toByte() }
        val totalChunks = ChunkTransfer.totalChunks(payload.size)
        val reassembler = ChunkReassembler()

        reassembler.consumeFrame(ChunkTransfer.header("tx", totalChunks, payload.size))
        assertNull(reassembler.consumeFrame(ChunkTransfer.chunk(payload, 2)))
        assertNull(reassembler.consumeFrame(ChunkTransfer.chunk(payload, 0)))
        val assembled = reassembler.consumeFrame(ChunkTransfer.chunk(payload, 1))

        requireNotNull(assembled)
        assertArrayEquals(payload, assembled.bytes)
    }

    @Test
    fun rejectsInvalidChunkIndex() {
        val payload = ByteArray(520) { 0x41 }
        val totalChunks = ChunkTransfer.totalChunks(payload.size)
        val reassembler = ChunkReassembler()

        reassembler.consumeFrame(ChunkTransfer.header("tx", totalChunks, payload.size))
        assertNull(reassembler.consumeFrame(byteArrayOf(0x00, 0x05, 0x11, 0x22)))
    }

    @Test
    fun newHeaderResetsPendingTransfer() {
        val firstPayload = ByteArray(600) { 0x31 }
        val secondPayload = ByteArray(100) { 0x32 }
        val reassembler = ChunkReassembler()

        reassembler.consumeFrame(
            ChunkTransfer.header("first", ChunkTransfer.totalChunks(firstPayload.size), firstPayload.size)
        )
        assertNull(reassembler.consumeFrame(ChunkTransfer.chunk(firstPayload, 0)))

        reassembler.consumeFrame(
            ChunkTransfer.header("second", ChunkTransfer.totalChunks(secondPayload.size), secondPayload.size)
        )

        val assembled = reassembler.consumeFrame(ChunkTransfer.chunk(secondPayload, 0))
        requireNotNull(assembled)
        assertArrayEquals(secondPayload, assembled.bytes)
    }
}
