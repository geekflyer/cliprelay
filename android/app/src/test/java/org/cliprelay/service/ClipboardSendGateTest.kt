package org.cliprelay.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardSendGateTest {

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
    fun `reset clears duplicate suppression`() {
        val gate = ClipboardSendGate(nowMs = { 1_000L }, suppressionWindowMs = 500L)

        assertTrue(gate.shouldSend("abc"))
        gate.reset()
        assertTrue(gate.shouldSend("abc"))
    }
}
