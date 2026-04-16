package org.cliprelay.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardAccessibilityHeuristicsTest {

    @Test
    fun `contains copy text matches common exact labels`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyText(sequenceOf("Copy link")))
        assertTrue(heuristics.containsCopyText(sequenceOf("COPY CODE")))
    }

    @Test
    fun `window text uses broader matching for command style labels`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyWindowText(sequenceOf("Copy permalink")))
        assertTrue(heuristics.containsCopyWindowText(sequenceOf("Copy address")))
    }

    @Test
    fun `contains copy text ignores substring false positives`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertFalse(heuristics.containsCopyText(sequenceOf("Copyright 2026 ClipRelay")))
        assertFalse(heuristics.containsCopyText(sequenceOf("copycat")))
        assertFalse(heuristics.containsCopyText(sequenceOf("Stop copying")))
    }

    @Test
    fun `contains copy command text matches copy actions with app specific suffixes`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyCommandText(sequenceOf("Copy address")))
        assertTrue(heuristics.containsCopyCommandText(sequenceOf("Copy password")))
        assertTrue(heuristics.containsCopyCommandText(sequenceOf("Copy permalink")))
        assertTrue(heuristics.containsCopyCommandText(sequenceOf("Copy post link")))
        assertFalse(heuristics.containsCopyCommandText(sequenceOf("Don't copy")))
        assertFalse(heuristics.containsCopyCommandText(sequenceOf("Copy to folder")))
    }

    @Test
    fun `debug copy candidates only returns copy like labels`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        val candidates = heuristics.debugCopyCandidates(
            sequenceOf("Copy permalink", "Share link", "Copy to folder", "copycat")
        )

        assertTrue(candidates.contains("copy permalink"))
        assertTrue(candidates.contains("copy to folder"))
        assertFalse(candidates.contains("share link"))
        assertFalse(candidates.contains("copycat"))
    }

    @Test
    fun `toolbar close within grace window triggers fallback`() {
        var nowElapsed = 1_000L
        var nowWallClock = 50_000L
        val heuristics = ClipboardAccessibilityHeuristics(
            elapsedRealtimeMs = { nowElapsed },
            wallClockMs = { nowWallClock },
            toolbarGracePeriodMs = 500L
        )

        assertNull(heuristics.onCopyAffordanceChanged(true))

        nowElapsed += 300L
        nowWallClock += 300L
        assertEquals(50_000L, heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `toolbar close after grace window does not trigger fallback`() {
        var nowElapsed = 1_000L
        var nowWallClock = 50_000L
        val heuristics = ClipboardAccessibilityHeuristics(
            elapsedRealtimeMs = { nowElapsed },
            wallClockMs = { nowWallClock },
            toolbarGracePeriodMs = 500L
        )

        assertNull(heuristics.onCopyAffordanceChanged(true))

        nowElapsed += 700L
        nowWallClock += 700L
        assertNull(heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `direct detection resets toolbar fallback state`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertNull(heuristics.onCopyAffordanceChanged(true))
        heuristics.resetAfterDirectDetection()
        assertNull(heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `expired close resets state before next affordance`() {
        var nowElapsed = 1_000L
        var nowWallClock = 50_000L
        val heuristics = ClipboardAccessibilityHeuristics(
            elapsedRealtimeMs = { nowElapsed },
            wallClockMs = { nowWallClock },
            toolbarGracePeriodMs = 500L
        )

        assertNull(heuristics.onCopyAffordanceChanged(true))
        nowElapsed += 700L
        nowWallClock += 700L
        assertNull(heuristics.onCopyAffordanceChanged(false))

        nowElapsed += 100L
        nowWallClock = 90_000L
        assertNull(heuristics.onCopyAffordanceChanged(true))

        nowElapsed += 200L
        nowWallClock += 200L
        assertEquals(90_000L, heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `contains copy text normalizes whitespace and punctuation`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyText(sequenceOf("  Copy   to   clipboard  ")))
        assertTrue(heuristics.containsCopyText(sequenceOf("Copy link!")))
        assertTrue(heuristics.containsCopyText(sequenceOf("📋 Copy")))
        assertTrue(heuristics.containsCopyText(sequenceOf("🔗 Copy link")))
    }

    @Test
    fun `contains copy command text matches icon prefixed commands`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyCommandText(sequenceOf("📋 Copy address")))
        assertTrue(heuristics.containsCopyCommandText(sequenceOf("🔗 Copy permalink")))
    }
}
