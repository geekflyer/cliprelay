package org.cliprelay.service

// Shared clipboard read-and-forward logic for the two focus holders that can
// read the clipboard on Android 10+: the accessibility overlay window
// (ClipboardOverlayReader, primary) and the invisible activity
// (ClipboardGhostActivity, fallback).

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log

internal object ClipboardReadFlow {

    /**
     * Reads the clipboard and forwards fresh text to ClipRelayService.
     * Returns true when done; false when a retry might still find the copied
     * text (empty clipboard or a clip that predates the detected copy — some
     * apps write the clipboard a beat after the copy signal fires).
     */
    fun readAndForward(context: Context, tag: String): Boolean {
        val clipboardManager =
            context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        if (clipboardManager == null) {
            Log.w(tag, "ClipboardManager unavailable")
            return true
        }

        // Check freshness via metadata BEFORE reading the clip data: a stale
        // clip means the detection was a false positive (dismissed toolbar,
        // stray System UI window) or the app hasn't written the new clip yet —
        // never forward it; a retry may pick up a late write. Metadata reads
        // don't trigger the system's "app pasted from your clipboard" banner,
        // so discarded false positives stay invisible to the user.
        val description = try {
            clipboardManager.primaryClipDescription
        } catch (e: SecurityException) {
            Log.w(tag, "Clipboard metadata access denied: ${e.message}")
            null
        }
        if (description != null &&
            !AutoCopyHeuristics.isClipFresh(description.timestamp, System.currentTimeMillis())
        ) {
            Log.d(tag, "Clipboard content is stale — not forwarding")
            return false
        }

        val clip = try {
            clipboardManager.primaryClip
        } catch (e: SecurityException) {
            Log.w(tag, "Clipboard access denied: ${e.message}")
            return false
        }
        if (clip == null || clip.itemCount == 0) {
            Log.d(tag, "Clipboard empty")
            return false
        }

        val text = clip.getItemAt(0).coerceToText(context)?.toString()
        if (text.isNullOrBlank()) {
            Log.d(tag, "Clipboard text empty")
            return false
        }

        // Forward to service via the same path as the share sheet
        val pushIntent = Intent(context, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, text)
        }
        context.startService(pushIntent)
        Log.d(tag, "Forwarded clipboard text to service (${text.length} chars)")
        return true
    }
}
