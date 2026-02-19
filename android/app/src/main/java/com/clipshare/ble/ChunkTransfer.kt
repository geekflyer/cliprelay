package com.clipshare.ble

import org.json.JSONObject

object ChunkTransfer {
    private const val MAX_CHUNK_PAYLOAD = 509

    fun header(totalChunks: Int, totalBytes: Int): ByteArray {
        val json = JSONObject()
            .put("total_chunks", totalChunks)
            .put("total_bytes", totalBytes)
            .put("encoding", "utf-8")
            .toString()
        return json.toByteArray()
    }

    fun chunk(data: ByteArray, index: Int): ByteArray {
        val start = index * MAX_CHUNK_PAYLOAD
        val end = minOf(start + MAX_CHUNK_PAYLOAD, data.size)
        val payload = data.copyOfRange(start, end)
        val prefix = byteArrayOf(((index shr 8) and 0xFF).toByte(), (index and 0xFF).toByte())
        return prefix + payload
    }

    fun totalChunks(totalBytes: Int): Int = (totalBytes + MAX_CHUNK_PAYLOAD - 1) / MAX_CHUNK_PAYLOAD
}
