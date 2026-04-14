package org.cliprelay.ble

/**
 * BLE advertisements and scan responses have a hard 31-byte payload limit.
 *
 * Android's `AdvertiseData.Builder.setIncludeDeviceName(true)` includes the full local Bluetooth
 * name (Complete Local Name AD type 0x09) which can exceed the remaining budget and cause
 * `ADVERTISE_FAILED_DATA_TOO_LARGE`, preventing advertising from starting.
 *
 * This helper provides deterministic sizing math so callers can omit optional fields up-front.
 */
object BleAdvertiseSizing {
    private const val MAX_PAYLOAD_BYTES = 31

    // AD structure size = 1 (len) + 1 (type) + dataLen
    private fun adStructureSize(dataLen: Int): Int = 2 + dataLen

    // Manufacturer data payload = companyId(2) + payloadLen
    private fun manufacturerAdSize(payloadLen: Int): Int = adStructureSize(2 + payloadLen)

    private fun deviceNameAdSize(nameUtf8Bytes: Int): Int = adStructureSize(nameUtf8Bytes)

    /**
     * Returns whether a device name (UTF-8 bytes) can fit in the scan response given an optional
     * manufacturer payload.
     */
    fun canIncludeDeviceName(
        nameUtf8Bytes: Int,
        manufacturerPayloadLen: Int?
    ): Boolean {
        val mfgSize = manufacturerPayloadLen?.let { manufacturerAdSize(it) } ?: 0
        val nameSize = deviceNameAdSize(nameUtf8Bytes)
        return (mfgSize + nameSize) <= MAX_PAYLOAD_BYTES
    }

    /**
     * Computes the maximum UTF-8 byte length that a device name may have if it is to be included
     * alongside the given manufacturer payload. Returns 0 if no bytes are available.
     */
    fun maxDeviceNameUtf8Bytes(manufacturerPayloadLen: Int?): Int {
        val mfgSize = manufacturerPayloadLen?.let { manufacturerAdSize(it) } ?: 0
        val remaining = MAX_PAYLOAD_BYTES - mfgSize
        // Name AD needs 2 bytes of overhead (len + type).
        return (remaining - 2).coerceAtLeast(0)
    }
}

