package org.cliprelay.otp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OtpExtractorTest {

    @Test
    fun `plain six digit code`() {
        assertEquals("123456", OtpExtractor.extract("Your verification code is 123456"))
    }

    @Test
    fun `code with trailing period`() {
        assertEquals("482910", OtpExtractor.extract("Your code is 482910."))
    }

    @Test
    fun `google style prefixed code`() {
        assertEquals("482910", OtpExtractor.extract("G-482910 is your Google verification code."))
    }

    @Test
    fun `whatsapp style split code with hyphen`() {
        assertEquals("123456", OtpExtractor.extract("WhatsApp code 123-456"))
    }

    @Test
    fun `split code with space`() {
        assertEquals("123456", OtpExtractor.extract("Ihr Bestätigungscode lautet 123 456"))
    }

    @Test
    fun `german einmalpasswort`() {
        assertEquals("77812", OtpExtractor.extract("Ihr Einmalpasswort: 77812"))
    }

    @Test
    fun `four digit pin style otp`() {
        assertEquals("9081", OtpExtractor.extract("Use OTP 9081 to log in"))
    }

    @Test
    fun `no keyword means no extraction`() {
        assertNull(OtpExtractor.extract("Your parcel 483920 arrives tomorrow"))
    }

    @Test
    fun `no digits means no extraction`() {
        assertNull(OtpExtractor.extract("Your verification code has expired"))
    }

    @Test
    fun `decimal amount is not a code`() {
        assertNull(OtpExtractor.extract("Payment code confirmation: you paid 1234.56 EUR"))
    }

    @Test
    fun `long digit run is not a code`() {
        assertNull(OtpExtractor.extract("Verification for account 1234567890123 pending"))
    }

    @Test
    fun `keyword too far from digits means no extraction`() {
        val filler = "x".repeat(80)
        assertNull(OtpExtractor.extract("Your code expired. $filler ref 483920"))
    }

    @Test
    fun `picks code nearest to keyword`() {
        assertEquals(
            "482910",
            OtpExtractor.extract("Your login code is 482910 or call 5551 0000 for help")
        )
    }

    @Test
    fun `real amex safekey message`() {
        assertEquals(
            "699991",
            OtpExtractor.extract(
                "NEVER share this verification code, Amex will never call to ask " +
                    "for it: 699991. If shared or not requested, call us using Contact " +
                    "Us on the Amex website."
            )
        )
    }

    @Test
    fun `empty text`() {
        assertNull(OtpExtractor.extract(""))
    }
}
