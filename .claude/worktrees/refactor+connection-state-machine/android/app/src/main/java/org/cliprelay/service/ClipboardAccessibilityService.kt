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
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.cliprelay.settings.ClipboardSettingsStore

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore

    // Tracks whether a copy toolbar was recently visible
    @Volatile
    private var copyToolbarVisible = false

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
        // Check source node for ACTION_COPY (Tier 1)
        val source = event.source
        if (source != null) {
            try {
                if (hasActionCopy(source)) {
                    Log.d(TAG, "ACTION_COPY detected on clicked node")
                    copyToolbarVisible = false
                    notifyService()
                    return
                }
            } finally {
                source.recycle()
            }
        }

        // Check event text for "Copy" (Tier 3)
        if (isCopyText(event)) {
            Log.d(TAG, "Copy text detected in click event")
            copyToolbarVisible = false
            notifyService()
        }
    }

    // ── TYPE_WINDOW_STATE_CHANGED detection (Chrome, etc.) ───────────

    private fun handleWindowStateChanged(event: AccessibilityEvent) {
        val text = event.text?.joinToString(" ")?.lowercase() ?: ""

        val hasCopyOption = COPY_WORDS.any { text.contains(it) }

        if (hasCopyOption) {
            // Toolbar with "Copy" option appeared — just note it, don't act yet
            if (!copyToolbarVisible) {
                Log.d(TAG, "Copy toolbar appeared")
            }
            copyToolbarVisible = true
        } else if (copyToolbarVisible) {
            // Toolbar was visible but this window state change doesn't have copy text
            // → toolbar closed (user tapped an option or dismissed it)
            copyToolbarVisible = false
            Log.d(TAG, "Copy toolbar closed → checking clipboard")
            notifyService()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun hasActionCopy(node: AccessibilityNodeInfo): Boolean {
        return node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }
    }

    private fun isCopyText(event: AccessibilityEvent): Boolean {
        val text = event.text?.joinToString(" ")?.lowercase()?.trim() ?: return false
        if (text.contains("copyright")) return false
        return text in COPY_WORDS
    }

    companion object {
        private const val TAG = "ClipboardA11y"

        private val COPY_WORDS = setOf(
            "copy", "copy text",           // English
            "copiar", "copiar texto",       // Spanish, Portuguese
            "copier",                       // French
            "kopieren",                     // German
            "kopiëren",                     // Dutch
            "copia", "copiare",             // Italian
            "コピー",                        // Japanese
            "복사",                          // Korean
            "复制",                          // Chinese (Simplified)
            "複製",                          // Chinese (Traditional)
            "копировать", "скопировать",     // Russian
            "kopyala",                      // Turkish
            "คัดลอก",                       // Thai
            "sao chép",                     // Vietnamese
            "salin",                        // Filipino/Malay
            "kopiuj", "skopiuj",            // Polish
            "kopírovat",                    // Czech
            "kopiera",                      // Swedish
            "kopioi",                       // Finnish
            "αντιγραφή",                    // Greek
            "העתק",                         // Hebrew
            "نسخ",                          // Arabic
            "कॉपी करें",                     // Hindi
        )
    }

    private fun notifyService() {
        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_ACCESSIBILITY_COPY_DETECTED
        }
        startService(intent)
    }

    override fun onInterrupt() {
        Log.d(TAG, "Accessibility service interrupted")
    }
}
