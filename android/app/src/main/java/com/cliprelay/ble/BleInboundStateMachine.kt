package com.cliprelay.ble

import org.json.JSONObject
import java.security.MessageDigest

data class CompletedInboundTransfer(
    val encoding: String,
    val bytes: ByteArray
)

class BleInboundStateMachine(
    private val maxClipboardBytes: Int = 102_400
) {
    private data class Slot(
        val reassembler: ChunkReassembler = ChunkReassembler(),
        var pendingMetadataHash: String? = null
    )

    private val slotByDeviceId = mutableMapOf<String, Slot>()

    fun onAvailableMetadata(deviceId: String, metadata: ByteArray) {
        val json = runCatching {
            JSONObject(metadata.toString(Charsets.UTF_8))
        }.getOrNull() ?: return

        val hash = json.optString("hash").takeIf { it.isNotBlank() }
        slotFor(deviceId).pendingMetadataHash = hash
    }

    fun onDataFrame(deviceId: String, frame: ByteArray): CompletedInboundTransfer? {
        val slot = slotFor(deviceId)
        val assembled = slot.reassembler.consumeFrame(frame) ?: return null
        val assembledBytes = assembled.bytes

        if (assembledBytes.isEmpty() || assembledBytes.size > maxClipboardBytes + 1024) {
            slot.pendingMetadataHash = null
            return null
        }

        val metadataHash = slot.pendingMetadataHash ?: return null
        val assembledHash = sha256Hex(assembledBytes)
        if (metadataHash != assembledHash) {
            slot.pendingMetadataHash = null
            return null
        }

        slot.pendingMetadataHash = null
        return CompletedInboundTransfer(encoding = assembled.encoding, bytes = assembledBytes)
    }

    fun onDisconnected(deviceId: String) {
        slotByDeviceId.remove(deviceId)
    }

    fun resetAll() {
        slotByDeviceId.clear()
    }

    internal fun activeSlotCount(): Int = slotByDeviceId.size

    private fun slotFor(deviceId: String): Slot {
        return slotByDeviceId.getOrPut(deviceId) { Slot() }
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }
}
