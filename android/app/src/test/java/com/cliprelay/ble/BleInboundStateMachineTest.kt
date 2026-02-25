package com.cliprelay.ble

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.MessageDigest

class BleInboundStateMachineTest {
    @Test
    fun disconnectDropsPartialTransferAndAllowsCleanReconnect() {
        val machine = BleInboundStateMachine()
        val deviceId = "AA:BB:CC:DD:EE:01"
        val payload = ByteArray(700) { i -> (i % 256).toByte() }
        val txId = "tx-partial"
        val totalChunks = ChunkTransfer.totalChunks(payload.size)

        machine.onAvailableMetadata(deviceId, metadata(hash = sha256Hex(payload), txId = txId, size = payload.size))
        assertNull(machine.onDataFrame(deviceId, ChunkTransfer.header(txId, totalChunks, payload.size)))
        assertNull(machine.onDataFrame(deviceId, ChunkTransfer.chunk(payload, 0)))
        assertEquals(1, machine.activeSlotCount())

        machine.onDisconnected(deviceId)
        assertEquals(0, machine.activeSlotCount())

        // Late frame from old transfer must not complete after disconnect.
        assertNull(machine.onDataFrame(deviceId, ChunkTransfer.chunk(payload, 1)))

        machine.onAvailableMetadata(deviceId, metadata(hash = sha256Hex(payload), txId = txId, size = payload.size))
        assertNull(machine.onDataFrame(deviceId, ChunkTransfer.header(txId, totalChunks, payload.size)))

        var completed: CompletedInboundTransfer? = null
        repeat(totalChunks) { index ->
            completed = machine.onDataFrame(deviceId, ChunkTransfer.chunk(payload, index))
        }

        val result = requireNotNull(completed)
        assertEquals("utf-8", result.encoding)
        assertArrayEquals(payload, result.bytes)
    }

    @Test
    fun transfersAreIsolatedPerDeviceSlot() {
        val machine = BleInboundStateMachine()
        val deviceA = "AA:BB:CC:DD:EE:01"
        val deviceB = "AA:BB:CC:DD:EE:02"

        val payloadA = ByteArray(700) { i -> (i % 127).toByte() }
        val payloadB = ByteArray(120) { i -> (i % 41).toByte() }
        val txA = "tx-a"
        val txB = "tx-b"

        machine.onAvailableMetadata(deviceA, metadata(hash = sha256Hex(payloadA), txId = txA, size = payloadA.size))
        machine.onDataFrame(deviceA, ChunkTransfer.header(txA, ChunkTransfer.totalChunks(payloadA.size), payloadA.size))
        assertNull(machine.onDataFrame(deviceA, ChunkTransfer.chunk(payloadA, 0)))

        machine.onAvailableMetadata(deviceB, metadata(hash = sha256Hex(payloadB), txId = txB, size = payloadB.size))
        machine.onDataFrame(deviceB, ChunkTransfer.header(txB, ChunkTransfer.totalChunks(payloadB.size), payloadB.size))
        val completeB = machine.onDataFrame(deviceB, ChunkTransfer.chunk(payloadB, 0))

        assertArrayEquals(payloadB, requireNotNull(completeB).bytes)

        val completeA = machine.onDataFrame(deviceA, ChunkTransfer.chunk(payloadA, 1))
        assertArrayEquals(payloadA, requireNotNull(completeA).bytes)
    }

    @Test
    fun transferWithoutMetadataIsDiscarded() {
        val machine = BleInboundStateMachine()
        val deviceId = "AA:BB:CC:DD:EE:03"
        val payload = ByteArray(32) { i -> (i + 1).toByte() }
        val txId = "tx-no-meta"
        val totalChunks = ChunkTransfer.totalChunks(payload.size)

        machine.onDataFrame(deviceId, ChunkTransfer.header(txId, totalChunks, payload.size))
        val resultWithoutMetadata = machine.onDataFrame(deviceId, ChunkTransfer.chunk(payload, 0))
        assertNull(resultWithoutMetadata)

        machine.onAvailableMetadata(deviceId, metadata(hash = sha256Hex(payload), txId = txId, size = payload.size))
        machine.onDataFrame(deviceId, ChunkTransfer.header(txId, totalChunks, payload.size))
        val resultWithMetadata = machine.onDataFrame(deviceId, ChunkTransfer.chunk(payload, 0))

        assertArrayEquals(payload, requireNotNull(resultWithMetadata).bytes)
    }

    private fun metadata(hash: String, txId: String, size: Int): ByteArray {
        return JSONObject()
            .put("hash", hash)
            .put("size", size)
            .put("type", "text/plain")
            .put("tx_id", txId)
            .toString()
            .toByteArray(Charsets.UTF_8)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }
}
