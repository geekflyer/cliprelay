package org.cliprelay.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingUriParserTest {
    @Test
    fun parsesValidUri_andNormalizesToken() {
        val info = PairingUriParser.parse(
            "cliprelay://pair?k=AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899&n=Mac%20Mini"
        )

        requireNotNull(info)
        assertEquals("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", info.publicKeyHex)
        assertEquals("Mac Mini", info.deviceName)
    }

    @Test
    fun rejectsInvalidSchemeHostAndToken() {
        assertNull(PairingUriParser.parse("https://pair?k=abcd"))
        assertNull(PairingUriParser.parse("cliprelay://wrong?k=abcd"))
        assertNull(PairingUriParser.parse("cliprelay://pair?k=abcd"))
        assertNull(
            PairingUriParser.parse(
                "cliprelay://pair?k=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
            )
        )
    }

    @Test
    fun blankDeviceNameBecomesNull() {
        val info = PairingUriParser.parse(
            "cliprelay://pair?k=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff&n="
        )

        requireNotNull(info)
        assertNull(info.deviceName)
    }

    @Test
    fun malformedQueryEncoding_returnsNullWithoutCrashing() {
        val info = PairingUriParser.parse(
            "cliprelay://pair?k=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff&n=%"
        )

        assertNull(info)
    }

    @Test
    fun rejectsNonCanonicalUriFormsAndLegacyParamNames() {
        assertNull(
            PairingUriParser.parse(
                "cliprelay:/pair?token=ffeeddccbbaa00998877665544332211ffeeddccbbaa00998877665544332211&name=Mac Book"
            )
        )

        assertNull(
            PairingUriParser.parse(
                "cliprelay://pair?token=ffeeddccbbaa00998877665544332211ffeeddccbbaa00998877665544332211&name=Mac Book"
            )
        )
    }

    @Test
    fun rejectsOldTokenFormat() {
        val uri = "cliprelay://pair?t=${"ab".repeat(32)}"
        assertNull(PairingUriParser.parse(uri))
    }
}
