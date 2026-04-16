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
            triggerCopyDetected("click", ClipRelayService.CLIPBOARD_TRIGGER_DIRECT)
        }
    }

    // ── TYPE_WINDOW_STATE_CHANGED detection (Chrome, etc.) ───────────

    private fun handleWindowStateChanged(event: AccessibilityEvent) {
        val hasCopyAffordance = heuristics.containsCopyText(eventSignals(event))
        if (heuristics.onCopyAffordanceChanged(hasCopyAffordance)) {
            triggerCopyDetected(
                "window state changed close",
                ClipRelayService.CLIPBOARD_TRIGGER_TOOLBAR_CLOSE
            )
        } else if (hasCopyAffordance) {
            Log.d(TAG, "Copy affordance visible via window state changed")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun eventMatchesCopy(event: AccessibilityEvent): Boolean {
        val source = event.source
        if (source != null) {
            try {
                if (nodeMatchesCopy(source)) {
                    return true
                }
            } finally {
                source.recycle()
            }
        }
        return heuristics.containsCopyCommandText(eventSignals(event))
    }

    private fun nodeMatchesCopy(node: AccessibilityNodeInfo): Boolean {
        if (node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }) {
            return true
        }

        return heuristics.containsCopyCommandText(nodeSignals(node))
    }

    private fun eventSignals(event: AccessibilityEvent): Sequence<String> {
        val eventText = event.text.asSequence().map { it.toString() }
        val contentDescription = sequenceOf(event.contentDescription?.toString()).filterNotNull()
        return eventText + contentDescription
    }

    private fun nodeSignals(node: AccessibilityNodeInfo): Sequence<String> {
        val nodeText = sequenceOf(node.text?.toString()).filterNotNull()
        val contentDescription = sequenceOf(node.contentDescription?.toString()).filterNotNull()
        val actionLabels = node.actionList.asSequence().mapNotNull { it.label?.toString() }
        return nodeText + contentDescription + actionLabels
    }

    companion object {
        private const val TAG = "ClipboardA11y"
    }

    private fun triggerCopyDetected(reason: String, triggerSource: String) {
        heuristics.resetAfterDirectDetection()
        Log.d(TAG, "Copy detected via $reason")
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_ACCESSIBILITY_COPY_DETECTED
            putExtra(ClipRelayService.EXTRA_CLIPBOARD_TRIGGER_SOURCE, triggerSource)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }
}
