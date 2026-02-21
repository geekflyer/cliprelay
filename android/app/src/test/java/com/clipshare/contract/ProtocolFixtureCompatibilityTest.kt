package com.clipshare.contract

import com.clipshare.ble.ChunkReassembler
import com.clipshare.ble.ChunkTransfer
import com.clipshare.crypto.E2ECrypto
import com.clipshare.testing.ProtocolFixtureLoader
import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

class ProtocolFixtureCompatibilityTest {
    @Test
    fun fixtureBlobDecryptsWithDerivedKey() {
        val fixture = ProtocolFixtureLoader.loadV1()
        val key = E2ECrypto.deriveKey(fixture.tokenHex)

        val decrypted = E2ECrypto.open(fixture.encryptedBlob, key)

        assertEquals(1280, decrypted.size)
        assertEquals(fixture.plaintextSha256Hex, sha256Hex(decrypted))
        assertEquals(fixture.encryptedSha256Hex, sha256Hex(fixture.encryptedBlob))
    }

    @Test
    fun fixtureFramesMatchChunkTransferAndReassemble() {
        val fixture = ProtocolFixtureLoader.loadV1()
        val reassembler = ChunkReassembler()

        val header = ChunkTransfer.header(
            txId = fixture.txId,
            totalChunks = fixture.totalChunks,
            totalBytes = fixture.encryptedBlob.size,
            encoding = "utf-8"
        )

        val generatedFrames = (0 until fixture.totalChunks).map { index ->
            ChunkTransfer.chunk(fixture.encryptedBlob, index)
        }

        assertEquals(fixture.chunkFrames.size, generatedFrames.size)
        generatedFrames.zip(fixture.chunkFrames).forEach { (generated, expected) ->
            assertEquals(sha256Hex(expected), sha256Hex(generated))
        }

        reassembler.consumeFrame(header)
        var assembled: ByteArray? = null
        fixture.chunkFrames.forEach { frame ->
            assembled = reassembler.consumeFrame(frame)?.bytes
        }

        val assembledBytes = requireNotNull(assembled)
        assertEquals(sha256Hex(fixture.encryptedBlob), sha256Hex(assembledBytes))
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }
}
