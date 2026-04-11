package org.cliprelay.feedback

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.Process
import androidx.core.content.FileProvider
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

object LogShareExporter {
    private const val LOG_DIR = "shared_logs"
    private const val LOG_FILE_PREFIX = "cliprelay-android-logs"
    private const val LOG_LINE_LIMIT = "2000"
    private val fileTimestampFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss", Locale.US).withZone(ZoneOffset.UTC)

    fun createShareIntent(context: Context, bleState: String): Intent {
        val now = Instant.now()
        val logFile = writeLogFile(context, now, bleState, captureLogcat())
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", logFile)
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "ClipRelay Android logs")
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(context.contentResolver, "ClipRelay Android logs", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    internal fun writeLogFile(
        context: Context,
        now: Instant,
        bleState: String,
        logOutput: String
    ): File {
        val shareDir = File(context.cacheDir, LOG_DIR).apply { mkdirs() }
        val file = File(shareDir, buildFileName(now))
        file.writeText(buildFileContents(SupportLinks.diagnosticsContext(bleState), now, logOutput))
        return file
    }

    internal fun buildFileName(now: Instant): String =
        "$LOG_FILE_PREFIX-${fileTimestampFormatter.format(now)}.txt"

    internal fun buildFileContents(
        diagnosticsContext: List<Pair<String, String>>,
        generatedAt: Instant,
        logOutput: String
    ): String = buildString {
        appendLine("ClipRelay Android diagnostics")
        appendLine("Generated: ${DateTimeFormatter.ISO_INSTANT.format(generatedAt)}")
        appendLine("Included logs: current ClipRelay process logcat snapshot (up to $LOG_LINE_LIMIT lines)")
        appendLine()
        diagnosticsContext.forEach { (label, value) ->
            appendLine("$label: $value")
        }
        appendLine()
        appendLine("---- LOGCAT ----")
        appendLine(logOutput.ifBlank { "No recent ClipRelay logs were available for this process." })
    }

    private fun captureLogcat(): String = runCatching {
        val process = ProcessBuilder(
            "logcat",
            "-d",
            "-v",
            "threadtime",
            "--pid=${Process.myPid()}",
            "-t",
            LOG_LINE_LIMIT
        )
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText().trimEnd() }
        val exitCode = process.waitFor()
        if (exitCode == 0) {
            output
        } else {
            "logcat exited with code $exitCode.\n$output"
        }
    }.getOrElse { error ->
        "Unable to capture logcat: ${error.message ?: error.javaClass.simpleName}"
    }
}
