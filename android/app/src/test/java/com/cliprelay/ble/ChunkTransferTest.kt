package com.cliprelay.ble

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class ChunkTransferTest {
    @Test
    fun totalChunks_handlesBoundaries() {
        assertEquals(0, ChunkTransfer.totalChunks(0))
        assertEquals(1, ChunkTransfer.totalChunks(1))
        assertEquals(1, ChunkTransfer.totalChunks(509))
        assertEquals(2, ChunkTransfer.totalChunks(510))
        assertEquals(3, ChunkTransfer.totalChunks(1020))
    }

    @Test
    fun chunk_prefixesBigEndianIndex() {
        val data = ByteArray(700) { i -> (i % 256).toByte() }

        val chunk0 = ChunkTransfer.chunk(data, 0)
        val chunk1 = ChunkTransfer.chunk(data, 1)

        assertEquals(0x00, chunk0[0].toInt() and 0xFF)
        assertEquals(0x00, chunk0[1].toInt() and 0xFF)
        assertEquals(0x00, chunk1[0].toInt() and 0xFF)
        assertEquals(0x01, chunk1[1].toInt() and 0xFF)
        assertEquals(511, chunk0.size)
        assertEquals(193, chunk1.size)
        assertArrayEquals(data.copyOfRange(509, 700), chunk1.copyOfRange(2, chunk1.size))
    }

    @Test
    fun header_containsExpectedFields() {
        val headerBytes = ChunkTransfer.header(
            txId = "11111111-2222-3333-4444-555555555555",
            totalChunks = 3,
            totalBytes = 1308,
            encoding = "utf-8"
        )

        val json = JSONObject(headerBytes.toString(Charsets.UTF_8))
        assertEquals("11111111-2222-3333-4444-555555555555", json.getString("tx_id"))
        assertEquals(3, json.getInt("total_chunks"))
        assertEquals(1308, json.getInt("total_bytes"))
        assertEquals("utf-8", json.getString("encoding"))
    }
}
