package org.cliprelay.service

// AccessibilityService that detects copy actions and notifies
// ClipRelayService to read and forward the clipboard.
//
// Detection strategy:
//   1. TYPE_VIEW_CLICKED with ACTION_COPY or "Copy" text — works for most apps.
//   2. TYPE_WINDOW_STATE_CHANGED toolbar tracking — catches apps like Chrome
//      that don't fire TYPE_VIEW_CLICKED for their toolbar buttons.
//      When a text action toolbar containing "Copy" appears, we set a flag.
//      When the toolbar closes (next window state change without copy text),
//      we launch the ghost activity to check if the clipboard was updated.
//      This avoids stealing focus while the toolbar is still visible.

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.cliprelay.settings.ClipboardSettingsStore

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore
    private val heuristics = ClipboardAccessibilityHeuristics()

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        // Only process if auto-copy is enabled
        if (!::settingsStore.isInitialized || !settingsStore.isAutoCopyEnabled()) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> handleClickEvent(event)
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> handleWindowStateChanged(event)
        }
    }

    // ── TYPE_VIEW_CLICKED detection (most apps) ──────────────────────

    private fun handleClickEvent(event: AccessibilityEvent) {
        if (eventMatchesCopy(event)) {
            triggerCopyDetected("click")
        }
    }

    // ── TYPE_WINDOW_STATE_CHANGED detection (Chrome, etc.) ───────────

    private fun handleWindowStateChanged(event: AccessibilityEvent) {
        val hasCopyAffordance = heuristics.containsCopyText(eventSignals(event))
        if (heuristics.onCopyAffordanceChanged(hasCopyAffordance)) {
            triggerCopyDetected("window state changed close")
        } else if (hasCopyAffordance) {
            Log.d(TAG, "Copy affordance visible via window state changed")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun eventMatchesCopy(event: AccessibilityEvent): Boolean {
        val source = event.source
        if (source != null) {
            try {
                if (hasActionCopy(source)) {
                    return true
                }
            } finally {
                source.recycle()
            }
        }
        return heuristics.containsCopyText(eventSignals(event))
    }

    private fun hasActionCopy(node: AccessibilityNodeInfo): Boolean {
        return node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }
    }

    private fun eventSignals(event: AccessibilityEvent): Sequence<String> {
        val eventText = event.text.asSequence().map { it.toString() }
        val contentDescription = sequenceOf(event.contentDescription?.toString()).filterNotNull()
        return eventText + contentDescription
    }

    companion object {
        private const val TAG = "ClipboardA11y"
    }

    private fun triggerCopyDetected(reason: String) {
        heuristics.resetAfterDirectDetection()
        Log.d(TAG, "Copy detected via $reason")
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_ACCESSIBILITY_COPY_DETECTED
        }
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }
}
