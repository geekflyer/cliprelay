package org.cliprelay.service

// Invisible activity that briefly gains foreground focus to read the clipboard on Android 10+.
// Launched by ClipRelayService when the clipboard listener fires and the app is backgrounded.

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.ComponentActivity

class ClipboardGhostActivity : ComponentActivity() {

    companion object {
        private const val TAG = "ClipboardGhost"
        private const val SAFETY_TIMEOUT_MS = 2500L
        // Some apps write the clipboard a beat after the tap's accessibility
        // event fires (Android 14 can lag 200-300ms) — retry once before giving up.
        private const val RETRY_DELAY_MS = 500L
        private const val MAX_READ_ATTEMPTS = 2
    }

    private val safetyHandler = Handler(Looper.getMainLooper())
    private var finished = false
    private var readAttempts = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Safety timeout — always finish even if clipboard read fails
        safetyHandler.postDelayed({
            if (!finished) {
                Log.w(TAG, "Safety timeout — finishing ghost activity")
                finishGhost()
            }
        }, SAFETY_TIMEOUT_MS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Log.d(TAG, "onWindowFocusChanged: hasFocus=$hasFocus, finished=$finished")
        if (!hasFocus || finished || readAttempts > 0) return

        // Post one extra frame after gaining focus to ensure clipboard access is ready
        window.decorView.post {
            if (finished) return@post
            attemptClipboardRead()
        }
    }

    private fun attemptClipboardRead() {
        if (finished) return
        readAttempts += 1
        Log.d(TAG, "Reading clipboard (attempt $readAttempts)")
        if (readClipboardAndForward() || readAttempts >= MAX_READ_ATTEMPTS) {
            finishGhost()
        } else {
            safetyHandler.postDelayed({ attemptClipboardRead() }, RETRY_DELAY_MS)
        }
    }

    /**
     * Reads the clipboard and forwards fresh text to the service.
     * Returns true when done; false when a retry might still find the copied
     * text (empty clipboard or a clip that predates the detected copy).
     */
    private fun readClipboardAndForward(): Boolean {
        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        if (clipboardManager == null) {
            Log.w(TAG, "ClipboardManager unavailable")
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
            Log.w(TAG, "Clipboard metadata access denied: ${e.message}")
            null
        }
        if (description != null &&
            !AutoCopyHeuristics.isClipFresh(description.timestamp, System.currentTimeMillis())
        ) {
            Log.d(TAG, "Clipboard content is stale — not forwarding")
            return false
        }

        val clip = try {
            clipboardManager.primaryClip
        } catch (e: SecurityException) {
            Log.w(TAG, "Clipboard access denied: ${e.message}")
            return false
        }
        if (clip == null || clip.itemCount == 0) {
            Log.d(TAG, "Clipboard empty")
            return false
        }

        val text = clip.getItemAt(0).coerceToText(this)?.toString()
        if (text.isNullOrBlank()) {
            Log.d(TAG, "Clipboard text empty")
            return false
        }

        // Forward to service via the same path as the share sheet
        val pushIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, text)
        }
        startService(pushIntent)
        Log.d(TAG, "Forwarded clipboard text to service (${text.length} chars)")
        return true
    }

    private fun finishGhost() {
        if (finished) return
        finished = true
        safetyHandler.removeCallbacksAndMessages(null)

        // Always notify service to clear ghostActivityInFlight flag
        val clearIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_GHOST_FINISHED
        }
        startService(clearIntent)

        finish()
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun onDestroy() {
        safetyHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
