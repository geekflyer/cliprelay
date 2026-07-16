package org.cliprelay.service

// Invisible activity that briefly gains foreground focus to read the clipboard on Android 10+.
// FALLBACK ONLY: activity starts collapse the notification shade, heads-up notifications, and
// Live Update chips (issue #109), so ClipRelayService prefers the accessibility overlay reader
// (ClipboardOverlayReader) and only launches this when the overlay is unavailable.

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
        return ClipboardReadFlow.readAndForward(this, TAG)
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
