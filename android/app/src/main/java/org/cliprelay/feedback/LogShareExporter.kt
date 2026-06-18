package org.cliprelay.feedback

import android.content.Context
import android.content.Intent
import android.os.Process
import org.cliprelay.pairing.PairingStore
import org.cliprelay.settings.ClipboardSettingsStore
import java.time.Instant
import java.time.format.DateTimeFormatter

object LogShareExporter {
    private const val LOG_LINE_LIMIT = "2000"

    // Shared as plain text via the system share sheet (ACTION_SEND + EXTRA_TEXT)
    // rather than a .txt attachment — text is far easier to paste into a chat,
    // email, or issue on Android. The extra travels through a Binder transaction
    // (~1 MB process-wide budget), so cap the body well under that to avoid
    // TransactionTooLargeException.
    private const val MAX_LOG_CHARS = 100_000

    fun createShareIntent(context: Context, bleState: String): Intent {
        val text = buildShareText(
            diagnosticsContext = collectContext(context, bleState),
            generatedAt = Instant.now(),
            logOutput = captureLogcat(),
        )
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "ClipRelay Android logs")
            putExtra(Intent.EXTRA_TEXT, text)
        }
    }

    /** App / device / flag context prepended to every shared log. */
    private fun collectContext(context: Context, bleState: String): List<Pair<String, String>> {
        val settings = ClipboardSettingsStore(context)
        val pairing = PairingStore(context)
        val flags = listOf(
            "autoCopy" to settings.isAutoCopyEnabled(),
            "hideSyncedClipboard" to settings.isHideSyncedClipboardEnabled(),
            "autoClearSyncedClipboard" to settings.isAutoClearSyncedClipboardEnabled(),
            "imageSync" to pairing.isRichMediaEnabled(),
        ).joinToString(", ") { "${it.first}=${it.second}" }
        return SupportLinks.diagnosticsContext(bleState) + listOf(
            "Paired Macs" to pairing.loadPairedMacs().size.toString(),
            "Flags" to flags,
        )
    }

    internal fun buildShareText(
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
        appendLine(trimToBudget(logOutput).ifBlank { "No recent ClipRelay logs were available for this process." })
    }

    /** Keep the most recent lines within [MAX_LOG_CHARS], dropping the partial head line. */
    internal fun trimToBudget(log: String): String {
        if (log.length <= MAX_LOG_CHARS) return log
        val tail = log.substring(log.length - MAX_LOG_CHARS)
        val firstNewline = tail.indexOf('\n')
        val clean = if (firstNewline >= 0) tail.substring(firstNewline + 1) else tail
        return "[… older log lines truncated to fit the share size limit …]\n$clean"
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
