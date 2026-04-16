package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardAccessibilityServiceTest {

    @Test
    fun `delayed probe requires a fresh clipboard timestamp`() {
        assertFalse(
            ClipboardAccessibilityService.delayedProbeHasFreshClipboardTimestamp(
                clipboardTimestampMs = null,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertFalse(
            ClipboardAccessibilityService.delayedProbeHasFreshClipboardTimestamp(
                clipboardTimestampMs = 9_600L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.delayedProbeHasFreshClipboardTimestamp(
                clipboardTimestampMs = 9_800L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.delayedProbeHasFreshClipboardTimestamp(
                clipboardTimestampMs = 10_200L,
                minClipboardTimestampMs = 10_000L
            )
        )
    }
}
