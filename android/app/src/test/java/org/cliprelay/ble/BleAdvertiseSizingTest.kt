package org.cliprelay.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BleAdvertiseSizingTest {
    @Test
    fun `device name fits alongside manufacturer data at boundary`() {
        // ClipRelay uses manufacturer payload [device_tag:8][psm:2] => 10 bytes.
        val manufacturerPayloadLen = 10
        val maxNameBytes = BleAdvertiseSizing.maxDeviceNameUtf8Bytes(manufacturerPayloadLen)
        assertTrue(maxNameBytes > 0)

        assertTrue(
            BleAdvertiseSizing.canIncludeDeviceName(
                nameUtf8Bytes = maxNameBytes,
                manufacturerPayloadLen = manufacturerPayloadLen
            )
        )
        assertFalse(
            BleAdvertiseSizing.canIncludeDeviceName(
                nameUtf8Bytes = maxNameBytes + 1,
                manufacturerPayloadLen = manufacturerPayloadLen
            )
        )
    }

    @Test
    fun `reported long device name does not fit with manufacturer data`() {
        val name = "Galaxy S23 Ultra de Alan"
        val nameBytes = name.toByteArray(Charsets.UTF_8).size
        val manufacturerPayloadLen = 10

        assertFalse(
            "Expected '$name' ($nameBytes bytes) to exceed scan response budget",
            BleAdvertiseSizing.canIncludeDeviceName(
                nameUtf8Bytes = nameBytes,
                manufacturerPayloadLen = manufacturerPayloadLen
            )
        )
    }
}

