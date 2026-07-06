package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoCopyHeuristicsTest {

    // ── isCopyLabel (exact match on click labels) ─────────────────────

    @Test
    fun `copy labels match exactly across languages`() {
        assertTrue(AutoCopyHeuristics.isCopyLabel("Copy"))
        assertTrue(AutoCopyHeuristics.isCopyLabel(" copy text "))
        assertTrue(AutoCopyHeuristics.isCopyLabel("コピー"))
        assertTrue(AutoCopyHeuristics.isCopyLabel("कॉपी करें"))
        assertTrue(AutoCopyHeuristics.isCopyLabel("Kopieren"))
    }

    @Test
    fun `copy-prefixed action labels match`() {
        // Icon buttons often carry these as contentDescription
        assertTrue(AutoCopyHeuristics.isCopyLabel("Copy to clipboard"))
        assertTrue(AutoCopyHeuristics.isCopyLabel("Copy message text"))
        assertTrue(AutoCopyHeuristics.isCopyLabel("Copy link address"))
    }

    @Test
    fun `copy label rejects sentences, noun phrases and copyright`() {
        assertFalse(AutoCopyHeuristics.isCopyLabel("How to copy files"))
        assertFalse(AutoCopyHeuristics.isCopyLabel("Copy of Report.docx"))
        assertFalse(AutoCopyHeuristics.isCopyLabel("Copyright 2026"))
        assertFalse(AutoCopyHeuristics.isCopyLabel("Paste"))
    }

    // ── isCopiedConfirmation (contains match on toasts) ───────────────

    @Test
    fun `copied toasts match across languages`() {
        assertTrue(AutoCopyHeuristics.isCopiedConfirmation("Copied to clipboard"))
        assertTrue(AutoCopyHeuristics.isCopiedConfirmation("Text copied"))
        assertTrue(AutoCopyHeuristics.isCopiedConfirmation("In Zwischenablage kopiert"))
        assertTrue(AutoCopyHeuristics.isCopiedConfirmation("已复制"))
        assertTrue(AutoCopyHeuristics.isCopiedConfirmation("क्लिपबोर्ड पर कॉपी किया गया"))
    }

    @Test
    fun `copied confirmation rejects copy buttons and copyright`() {
        assertFalse(AutoCopyHeuristics.isCopiedConfirmation("Copy"))
        assertFalse(AutoCopyHeuristics.isCopiedConfirmation("Copy to clipboard"))
        assertFalse(AutoCopyHeuristics.isCopiedConfirmation("© 2026 Acme — copied works reserved"))
        assertFalse(AutoCopyHeuristics.isCopiedConfirmation("Message sent"))
    }

    // ── containsCopyWord (toolbar text) ────────────────────────────────

    @Test
    fun `toolbar text with copy option matches`() {
        assertTrue(AutoCopyHeuristics.containsCopyWord("Cut Copy Paste Share"))
        assertFalse(AutoCopyHeuristics.containsCopyWord("Cut Paste Share"))
    }

    @Test
    fun `copied is not mistaken for a copy toolbar word`() {
        // "copied" must not contain-match the imperative "copy"
        assertFalse(AutoCopyHeuristics.containsCopyWord("copied to clipboard"))
    }

    // ── isClipFresh ────────────────────────────────────────────────────

    @Test
    fun `fresh clip passes, stale clip fails`() {
        val now = 1_000_000L
        assertTrue(AutoCopyHeuristics.isClipFresh(now - 1_000L, now))
        assertFalse(AutoCopyHeuristics.isClipFresh(now - AutoCopyHeuristics.MAX_CLIP_AGE_MS - 1, now))
    }

    @Test
    fun `unknown timestamp counts as fresh`() {
        assertTrue(AutoCopyHeuristics.isClipFresh(null, 1_000_000L))
        assertTrue(AutoCopyHeuristics.isClipFresh(0L, 1_000_000L))
    }
}
