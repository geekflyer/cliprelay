package org.cliprelay.service

import org.junit.Assert.assertFalse
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
        assertFalse(heuristics.containsCopyCommandText(sequenceOf("Don't copy")))
        assertFalse(heuristics.containsCopyCommandText(sequenceOf("Copy to folder")))
    }

    @Test
    fun `toolbar close within grace window triggers fallback`() {
        var now = 1_000L
        val heuristics = ClipboardAccessibilityHeuristics(nowMs = { now }, toolbarGracePeriodMs = 500L)

        assertFalse(heuristics.onCopyAffordanceChanged(true))

        now += 300L
        assertTrue(heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `toolbar close after grace window does not trigger fallback`() {
        var now = 1_000L
        val heuristics = ClipboardAccessibilityHeuristics(nowMs = { now }, toolbarGracePeriodMs = 500L)

        assertFalse(heuristics.onCopyAffordanceChanged(true))

        now += 700L
        assertFalse(heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `direct detection resets toolbar fallback state`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertFalse(heuristics.onCopyAffordanceChanged(true))
        heuristics.resetAfterDirectDetection()
        assertFalse(heuristics.onCopyAffordanceChanged(false))
    }

    @Test
    fun `contains copy text normalizes whitespace and punctuation`() {
        val heuristics = ClipboardAccessibilityHeuristics()

        assertTrue(heuristics.containsCopyText(sequenceOf("  Copy   to   clipboard  ")))
        assertTrue(heuristics.containsCopyText(sequenceOf("Copy link!")))
    }
}
