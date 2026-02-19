package com.clipshare.ble

import org.json.JSONObject

data class AssembledPayload(
    val encoding: String,
    val bytes: ByteArray
)

class ChunkReassembler {
    private var totalChunks: Int = 0
    private var totalBytes: Int = 0
    private var encoding: String = "utf-8"
    private val chunks = mutableMapOf<Int, ByteArray>()

    fun consumeFrame(frame: ByteArray): AssembledPayload? {
        val header = parseHeader(frame)
        if (header != null) {
            reset(header)
            return null
        }

        if (totalChunks <= 0 || frame.size < 2) {
            return null
        }

        val index = ((frame[0].toInt() and 0xFF) shl 8) or (frame[1].toInt() and 0xFF)
        if (index !in 0 until totalChunks) {
            return null
        }

        chunks[index] = frame.copyOfRange(2, frame.size)
        if (chunks.size != totalChunks) {
            return null
        }

        val assembled = ByteArray(totalBytes)
        var cursor = 0
        for (chunkIndex in 0 until totalChunks) {
            val chunk = chunks[chunkIndex] ?: return null
            if (cursor + chunk.size > assembled.size) {
                return null
            }
            System.arraycopy(chunk, 0, assembled, cursor, chunk.size)
            cursor += chunk.size
        }

        if (cursor != totalBytes) {
            return null
        }

        val payload = AssembledPayload(encoding = encoding, bytes = assembled)
        clear()
        return payload
    }

    private fun reset(header: JSONObject) {
        totalChunks = header.optInt("total_chunks", 0)
        totalBytes = header.optInt("total_bytes", 0)
        encoding = header.optString("encoding", "utf-8")
        chunks.clear()
    }

    private fun clear() {
        totalChunks = 0
        totalBytes = 0
        encoding = "utf-8"
        chunks.clear()
    }

    fun reset() {
        clear()
    }

    private fun parseHeader(frame: ByteArray): JSONObject? {
        if (frame.isEmpty() || frame[0] != '{'.code.toByte()) {
            return null
        }

        val text = frame.toString(Charsets.UTF_8)
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (!json.has("total_chunks") || !json.has("total_bytes")) {
            return null
        }
        return json
    }
}
