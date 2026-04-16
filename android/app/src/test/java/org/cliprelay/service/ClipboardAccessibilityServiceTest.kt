package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardAccessibilityServiceTest {

    @Test
    fun `toolbar close read requires a fresh clipboard timestamp`() {
        assertFalse(
            ClipboardAccessibilityService.toolbarCloseShouldTriggerRead(
                clipboardTimestampMs = null,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertFalse(
            ClipboardAccessibilityService.toolbarCloseShouldTriggerRead(
                clipboardTimestampMs = 8_900L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.toolbarCloseShouldTriggerRead(
                clipboardTimestampMs = 9_100L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.toolbarCloseShouldTriggerRead(
                clipboardTimestampMs = 10_200L,
                minClipboardTimestampMs = 10_000L
            )
        )
    }
}
