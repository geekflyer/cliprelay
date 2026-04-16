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

    @Test
    fun `scheduled probe respects current auto copy settings`() {
        assertFalse(
            ClipboardAccessibilityService.shouldAllowScheduledProbe(
                strategy = WindowProbeStrategy.NONE,
                autoCopyEnabled = false,
                aggressiveModeEnabled = true
            )
        )
        assertTrue(
            ClipboardAccessibilityService.shouldAllowScheduledProbe(
                strategy = WindowProbeStrategy.NONE,
                autoCopyEnabled = true,
                aggressiveModeEnabled = false
            )
        )
        assertFalse(
            ClipboardAccessibilityService.shouldAllowScheduledProbe(
                strategy = WindowProbeStrategy.AGGRESSIVE,
                autoCopyEnabled = true,
                aggressiveModeEnabled = false
            )
        )
        assertTrue(
            ClipboardAccessibilityService.shouldAllowScheduledProbe(
                strategy = WindowProbeStrategy.AGGRESSIVE,
                autoCopyEnabled = true,
                aggressiveModeEnabled = true
            )
        )
    }
}
