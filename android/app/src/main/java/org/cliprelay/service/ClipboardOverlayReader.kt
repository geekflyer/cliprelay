package org.cliprelay.service

// Reads the clipboard from the background WITHOUT launching an activity.
//
// Android 10+ only lets the app holding input focus read the clipboard. The
// original workaround (ClipboardGhostActivity) gained focus by starting an
// invisible activity — but every activity start makes the system close
// "system dialogs": the notification shade, heads-up notifications, and
// Android 16 Live Update chips all collapse (issue #109). No heuristic can
// fix that; even a correctly detected copy collapsed whatever the user had
// open.
//
// An accessibility service may instead add a focusable
// TYPE_ACCESSIBILITY_OVERLAY window: it receives input focus (which satisfies
// the clipboard-read check) while closing nothing, and FLAG_ALT_FOCUSABLE_IM
// keeps the IME target on the app beneath so the keyboard stays open. The
// overlay is 1x1 px, transparent, and untouchable — invisible to the user.
//
// If the overlay never gains window focus (OEM quirk), we tear it down and
// fall back to the ghost activity so auto-copy keeps working at the old cost.

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager

internal class ClipboardOverlayReader(private val service: AccessibilityService) {

    companion object {
        private const val TAG = "ClipboardOverlay"

        /** Overlay focus normally lands within a frame or two; past this, the
         *  device isn't granting it — fall back to the ghost activity. */
        private const val FOCUS_TIMEOUT_MS = 500L

        // Same retry cadence as the ghost activity: some apps write the
        // clipboard 200-300ms after the copy signal fires.
        private const val RETRY_DELAY_MS = 500L
        private const val MAX_READ_ATTEMPTS = 2
        private const val SAFETY_TIMEOUT_MS = 2500L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var overlayView: View? = null
    private var focusListener: ViewTreeObserver.OnWindowFocusChangeListener? = null
    private var readAttempts = 0
    private var gotFocus = false

    val inFlight: Boolean
        get() = overlayView != null

    /**
     * Adds the overlay and reads the clipboard once it gains focus.
     * Returns false if the overlay could not be added at all (caller should
     * fall back to the ghost activity immediately). [onNeedsGhostFallback]
     * fires later if the overlay was added but never granted focus.
     */
    fun start(onNeedsGhostFallback: () -> Unit): Boolean {
        if (inFlight) {
            Log.d(TAG, "Overlay read already in flight")
            return true
        }
        val windowManager =
            service.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return false

        val view = View(service)
        val params = WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        val listener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
            Log.d(TAG, "Overlay focus changed: hasFocus=$hasFocus")
            if (hasFocus && !gotFocus) {
                gotFocus = true
                // One extra frame after gaining focus so the clipboard
                // service sees us as the focused uid.
                view.post { attemptRead() }
            }
        }
        view.viewTreeObserver.addOnWindowFocusChangeListener(listener)

        try {
            windowManager.addView(view, params)
        } catch (t: Throwable) {
            Log.w(TAG, "Could not add clipboard overlay", t)
            view.viewTreeObserver.removeOnWindowFocusChangeListener(listener)
            return false
        }

        overlayView = view
        focusListener = listener
        readAttempts = 0
        gotFocus = false

        handler.postDelayed({
            if (inFlight && !gotFocus) {
                Log.w(TAG, "Overlay never gained focus — falling back to ghost activity")
                tearDown(notifyFinished = false)
                onNeedsGhostFallback()
            }
        }, FOCUS_TIMEOUT_MS)
        handler.postDelayed({
            if (inFlight) {
                Log.w(TAG, "Safety timeout — removing clipboard overlay")
                tearDown(notifyFinished = true)
            }
        }, SAFETY_TIMEOUT_MS)
        return true
    }

    private fun attemptRead() {
        if (!inFlight) return
        readAttempts += 1
        Log.d(TAG, "Reading clipboard via overlay (attempt $readAttempts)")
        if (ClipboardReadFlow.readAndForward(service, TAG) || readAttempts >= MAX_READ_ATTEMPTS) {
            tearDown(notifyFinished = true)
        } else {
            handler.postDelayed({ attemptRead() }, RETRY_DELAY_MS)
        }
    }

    private fun tearDown(notifyFinished: Boolean) {
        val view = overlayView ?: return
        overlayView = null
        handler.removeCallbacksAndMessages(null)
        focusListener?.let { view.viewTreeObserver.removeOnWindowFocusChangeListener(it) }
        focusListener = null
        runCatching {
            (service.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)?.removeView(view)
        }.onFailure { Log.w(TAG, "Could not remove clipboard overlay", it) }

        if (notifyFinished) {
            // Same contract as the ghost activity: always clear the service's
            // in-flight flag, even when nothing was forwarded.
            val clearIntent = Intent(service, ClipRelayService::class.java).apply {
                action = ClipRelayService.ACTION_GHOST_FINISHED
            }
            runCatching { service.startService(clearIntent) }
                .onFailure { Log.w(TAG, "Could not notify ClipRelayService", it) }
        }
    }

    /** Called when the accessibility service is going away. */
    fun cancel() {
        tearDown(notifyFinished = true)
    }
}
