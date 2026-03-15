package org.cliprelay.service

// AccessibilityService that detects copy actions (ACTION_COPY) on clicked views
// and notifies ClipRelayService to read and forward the clipboard.

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.cliprelay.settings.ClipboardSettingsStore

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_CLICKED) return

        // Only process if auto-copy is enabled
        if (!::settingsStore.isInitialized || !settingsStore.isAutoCopyEnabled()) return

        // Check source node for ACTION_COPY (Tier 1)
        val source = event.source
        if (source != null) {
            try {
                if (hasActionCopy(source)) {
                    Log.d(TAG, "ACTION_COPY detected on clicked node")
                    notifyService()
                    return
                }
            } finally {
                source.recycle()
            }
        }

        // Check event text for "Copy" (Tier 3 — fallback for apps that don't
        // provide a source node, e.g. Chrome's text selection toolbar)
        if (isCopyText(event)) {
            Log.d(TAG, "Copy text detected in click event")
            notifyService()
        }
    }

    private fun hasActionCopy(node: AccessibilityNodeInfo): Boolean {
        return node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_COPY }
    }

    private fun isCopyText(event: AccessibilityEvent): Boolean {
        val text = event.text?.joinToString(" ")?.lowercase()?.trim() ?: return false
        // Filter out "copyright" to avoid false positives
        if (text.contains("copyright")) return false
        return text in COPY_WORDS
    }

    companion object {
        private const val TAG = "ClipboardA11y"

        // "Copy" in common languages — used to detect copy button taps
        // when the source node doesn't provide ACTION_COPY
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
