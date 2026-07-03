package org.cliprelay.review

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.TimeUnit

class ReviewPromptGateTest {

    private val day = TimeUnit.DAYS.toMillis(1)
    private val now = 100 * day

    @Test
    fun `prompts when all gates pass`() {
        assertTrue(ReviewPromptGate.shouldPrompt(now, now - 2 * day, 10, 0L))
    }

    @Test
    fun `too few syncs blocks`() {
        assertFalse(ReviewPromptGate.shouldPrompt(now, now - 2 * day, 9, 0L))
    }

    @Test
    fun `install too recent blocks`() {
        assertFalse(ReviewPromptGate.shouldPrompt(now, now - day / 2, 100, 0L))
    }

    @Test
    fun `install exactly one day old passes`() {
        assertTrue(ReviewPromptGate.shouldPrompt(now, now - day, 10, 0L))
    }

    @Test
    fun `recent prompt blocks re-prompt`() {
        assertFalse(ReviewPromptGate.shouldPrompt(now, now - 90 * day, 100, now - 59 * day))
    }

    @Test
    fun `re-prompts after interval`() {
        assertTrue(ReviewPromptGate.shouldPrompt(now, now - 90 * day, 100, now - 60 * day))
    }
}
