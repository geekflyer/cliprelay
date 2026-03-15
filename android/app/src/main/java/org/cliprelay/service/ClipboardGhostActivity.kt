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
        private const val SAFETY_TIMEOUT_MS = 2000L
    }

    private val safetyHandler = Handler(Looper.getMainLooper())
    private var finished = false

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
        if (!hasFocus || finished) return

        // Post one extra frame after gaining focus to ensure clipboard access is ready
        window.decorView.post {
            if (finished) return@post
            Log.d(TAG, "Reading clipboard after focus gained")
            readClipboardAndForward()
            finishGhost()
        }
    }

    private fun readClipboardAndForward() {
        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        if (clipboardManager == null) {
            Log.w(TAG, "ClipboardManager unavailable")
            return
        }

        val clip = try {
            clipboardManager.primaryClip
        } catch (e: SecurityException) {
            Log.w(TAG, "Clipboard access denied: ${e.message}")
            return
        }
        if (clip == null || clip.itemCount == 0) {
            Log.d(TAG, "Clipboard empty")
            return
        }

        val text = clip.getItemAt(0).coerceToText(this)?.toString()
        if (text.isNullOrBlank()) {
            Log.d(TAG, "Clipboard text empty")
            return
        }

        // Forward to service via the same path as the share sheet
        val pushIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, text)
        }
        startService(pushIntent)
        Log.d(TAG, "Forwarded clipboard text to service (${text.length} chars)")
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
