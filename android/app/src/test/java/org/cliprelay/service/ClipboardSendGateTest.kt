package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSendGateTest {

    @Test
    fun `toolbar close timestamp allows small platform skew`() {
        val service = ClipRelayService()

        assertTrue(
            service.toolbarCloseHasFreshClipboardTimestamp(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                clipboardTimestampMs = 9_500L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertFalse(
            service.toolbarCloseHasFreshClipboardTimestamp(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                clipboardTimestampMs = 8_500L,
                minClipboardTimestampMs = 10_000L
            )
        )
        assertTrue(
            service.toolbarCloseHasFreshClipboardTimestamp(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_DIRECT,
                clipboardTimestampMs = null,
                minClipboardTimestampMs = null
            )
        )
    }

    @Test
    fun `toolbar close replay only skips when timestamp matches previous send`() {
        val service = ClipRelayService()

        assertTrue(
            service.shouldSkipToolbarCloseReplay(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                textHash = "abc",
                clipboardTimestampMs = 123L,
                lastSentTextHash = "abc",
                lastSentClipboardTimestampMs = 123L
            )
        )
        assertFalse(
            service.shouldSkipToolbarCloseReplay(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE,
                textHash = "abc",
                clipboardTimestampMs = 456L,
                lastSentTextHash = "abc",
                lastSentClipboardTimestampMs = 123L
            )
        )
        assertFalse(
            service.shouldSkipToolbarCloseReplay(
                triggerSource = ClipRelayService.CLIPBOARD_TRIGGER_DIRECT,
                textHash = "abc",
                clipboardTimestampMs = 123L,
                lastSentTextHash = "abc",
                lastSentClipboardTimestampMs = 123L
            )
        )
    }

    @Test
    fun `first send is allowed`() {
        val gate = ClipboardSendGate()

        assertTrue(gate.shouldSend("abc"))
    }

    @Test
    fun `duplicate send inside suppression window is blocked`() {
        var now = 1_000L
        val gate = ClipboardSendGate(nowMs = { now }, suppressionWindowMs = 500L)

        assertTrue(gate.shouldSend("abc"))
        now += 300L
        assertFalse(gate.shouldSend("abc"))
    }

    @Test
    fun `duplicate send after suppression window is allowed`() {
        var now = 1_000L
        val gate = ClipboardSendGate(nowMs = { now }, suppressionWindowMs = 500L)

        assertTrue(gate.shouldSend("abc"))
        now += 700L
        assertTrue(gate.shouldSend("abc"))
    }

    @Test
    fun `different hash inside suppression window is allowed`() {
        var now = 1_000L
        val gate = ClipboardSendGate(nowMs = { now }, suppressionWindowMs = 500L)

        assertTrue(gate.shouldSend("abc"))
        now += 100L
        assertTrue(gate.shouldSend("def"))
    }

    @Test
    fun `reset clears duplicate suppression`() {
        val gate = ClipboardSendGate(nowMs = { 1_000L }, suppressionWindowMs = 500L)

        assertTrue(gate.shouldSend("abc"))
        gate.reset()
        assertTrue(gate.shouldSend("abc"))
    }
}
