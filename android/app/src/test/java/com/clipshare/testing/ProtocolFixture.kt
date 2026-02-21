package com.clipshare.testing

import org.json.JSONObject
import java.io.File
import java.util.Base64

data class ProtocolFixture(
    val txId: String,
    val tokenHex: String,
    val plaintext: ByteArray,
    val plaintextSha256Hex: String,
    val encryptedBlob: ByteArray,
    val encryptedSha256Hex: String,
    val totalChunks: Int,
    val chunkFrames: List<ByteArray>
)

object ProtocolFixtureLoader {
    fun loadV1(): ProtocolFixture {
        val path = "test-fixtures/protocol/v1/interop_fixture_v1.json"
        val file = findUpwards(path)
            ?: error("Could not locate fixture file: $path from ${System.getProperty("user.dir")}")
        val json = JSONObject(file.readText())

        val framesJson = json.getJSONArray("chunk_frames_hex")
        val frames = ArrayList<ByteArray>(framesJson.length())
        for (i in 0 until framesJson.length()) {
            frames.add(hexToBytes(framesJson.getString(i)))
        }

        return ProtocolFixture(
            txId = json.getString("tx_id"),
            tokenHex = json.getString("token_hex"),
            plaintext = Base64.getDecoder().decode(json.getString("plaintext_base64")),
            plaintextSha256Hex = json.getString("plaintext_sha256_hex"),
            encryptedBlob = hexToBytes(json.getString("encrypted_blob_hex")),
            encryptedSha256Hex = json.getString("encrypted_sha256_hex"),
            totalChunks = json.getInt("total_chunks"),
            chunkFrames = frames
        )
    }

    private fun findUpwards(relativePath: String): File? {
        var current = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (true) {
            val candidate = File(current, relativePath)
            if (candidate.exists()) return candidate
            val parent = current.parentFile ?: return null
            if (parent == current) return null
            current = parent
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "Invalid hex length" }
        val bytes = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val high = Character.digit(hex[i], 16)
            val low = Character.digit(hex[i + 1], 16)
            require(high >= 0 && low >= 0) { "Invalid hex character" }
            bytes[i / 2] = ((high shl 4) + low).toByte()
            i += 2
        }
        return bytes
    }
}
