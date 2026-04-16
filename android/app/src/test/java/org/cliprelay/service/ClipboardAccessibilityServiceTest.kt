package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardAccessibilityServiceTest {

    @Test
    fun `toolbar close read requires a fresh clipboard timestamp`() {
        assertFalse(
            ClipboardAccessibilityService.shouldPreflightToolbarRead(
                strategy = WindowProbeStrategy.NONE,
                clipboardTimestampMs = null,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.shouldPreflightToolbarRead(
                strategy = WindowProbeStrategy.AGGRESSIVE,
                clipboardTimestampMs = null,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertFalse(
            ClipboardAccessibilityService.shouldPreflightToolbarRead(
                strategy = WindowProbeStrategy.AGGRESSIVE,
                clipboardTimestampMs = 8_900L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.shouldPreflightToolbarRead(
                strategy = WindowProbeStrategy.NONE,
                clipboardTimestampMs = 9_100L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            ClipboardAccessibilityService.shouldPreflightToolbarRead(
                strategy = WindowProbeStrategy.NONE,
                clipboardTimestampMs = 10_200L,
                minClipboardTimestampMs = 10_000L
            )
        )
    }
}
