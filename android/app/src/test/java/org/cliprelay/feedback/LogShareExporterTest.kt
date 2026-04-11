package org.cliprelay.feedback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class LogShareExporterTest {

    @Test
    fun `build file name uses utc timestamp`() {
        val name = LogShareExporter.buildFileName(Instant.parse("2026-04-11T15:42:05Z"))

        assertEquals("cliprelay-android-logs-20260411-154205.txt", name)
    }

    @Test
    fun `build file contents includes diagnostics and logs`() {
        val contents = LogShareExporter.buildFileContents(
            diagnosticsContext = listOf(
                "App Version" to "1.2.3 (abc123)",
                "BLE State" to "connected"
            ),
            generatedAt = Instant.parse("2026-04-11T15:42:05Z"),
            logOutput = "04-11 15:42:05.000 ClipRelayService: ready"
        )

        assertTrue(contents.contains("ClipRelay Android diagnostics"))
        assertTrue(contents.contains("Generated: 2026-04-11T15:42:05Z"))
        assertTrue(contents.contains("App Version: 1.2.3 (abc123)"))
        assertTrue(contents.contains("BLE State: connected"))
        assertTrue(contents.contains("---- LOGCAT ----"))
        assertTrue(contents.contains("ClipRelayService: ready"))
    }
}
