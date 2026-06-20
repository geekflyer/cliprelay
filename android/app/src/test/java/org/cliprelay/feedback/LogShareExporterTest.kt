package org.cliprelay.feedback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class LogShareExporterTest {

    @Test
    fun `share text includes diagnostics context and logs`() {
        val text = LogShareExporter.buildShareText(
            diagnosticsContext = listOf(
                "App Version" to "0.7.0 (1, abc123) [debug]",
                "BLE State" to "connected",
                "Paired Macs" to "1",
                "Flags" to "autoCopy=true, imageSync=false",
            ),
            generatedAt = Instant.parse("2026-04-11T15:42:05Z"),
            logOutput = "04-11 15:42:05.000 ClipRelayService: ready"
        )

        assertTrue(text.contains("ClipRelay Android diagnostics"))
        assertTrue(text.contains("Generated: 2026-04-11T15:42:05Z"))
        assertTrue(text.contains("App Version: 0.7.0 (1, abc123) [debug]"))
        assertTrue(text.contains("Paired Macs: 1"))
        assertTrue(text.contains("Flags: autoCopy=true, imageSync=false"))
        assertTrue(text.contains("---- LOGCAT ----"))
        assertTrue(text.contains("ClipRelayService: ready"))
    }

    @Test
    fun `share text notes when no logs are available`() {
        val text = LogShareExporter.buildShareText(
            diagnosticsContext = emptyList(),
            generatedAt = Instant.parse("2026-04-11T15:42:05Z"),
            logOutput = ""
        )
        assertTrue(text.contains("No recent ClipRelay logs were available for this process."))
    }

    @Test
    fun `trimToBudget keeps recent lines and drops the oldest`() {
        val big = "OLDEST_LINE\n" + ("x".repeat(100) + "\n").repeat(2000) // ~202k chars
        val trimmed = LogShareExporter.trimToBudget(big)

        assertTrue("should be bounded", trimmed.length <= 100_080)
        assertTrue("marks truncation", trimmed.startsWith("[… older log lines truncated"))
        assertFalse("drops the oldest line", trimmed.contains("OLDEST_LINE"))
    }

    @Test
    fun `trimToBudget returns input unchanged when within budget`() {
        val small = "04-11 15:42:05.000 line one\n04-11 15:42:06.000 line two"
        assertEquals(small, LogShareExporter.trimToBudget(small))
    }
}
