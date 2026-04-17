package org.cliprelay.crypto

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceTagFormatTest {
    @Test
    fun formatDeviceTag_handlesHighBitBytesAsTwoDigitHex() {
        val token = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

        assertEquals("9A93 227C", E2ECrypto.formatDeviceTag(token))
    }
}
