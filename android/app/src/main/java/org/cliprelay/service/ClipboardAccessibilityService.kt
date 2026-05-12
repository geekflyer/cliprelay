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
import android.app.Notification
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Base64
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.cliprelay.settings.ClipboardSettingsStore
import org.cliprelay.settings.NotificationSettingsStore
import java.io.ByteArrayOutputStream

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore
    private lateinit var notificationSettingsStore: NotificationSettingsStore

    // Tracks whether a copy toolbar was recently visible
    @Volatile
    private var copyToolbarVisible = false

    // Dedup: track last notification key to avoid sending duplicates
    private var lastNotifKey = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
        notificationSettingsStore = NotificationSettingsStore(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> handleNotificationEvent(event)
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                if (::settingsStore.isInitialized && settingsStore.isAutoCopyEnabled()) handleClickEvent(event)
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                if (::settingsStore.isInitialized && settingsStore.isAutoCopyEnabled()) handleWindowStateChanged(event)
            }
        }
    }

    // ── TYPE_NOTIFICATION_STATE_CHANGED detection ────────────────────

    private val BLOCKED_PACKAGES = setOf("android", "com.android.systemui", "org.cliprelay")

    private fun handleNotificationEvent(event: AccessibilityEvent) {
        if (!::notificationSettingsStore.isInitialized) return
        if (!notificationSettingsStore.isNotificationSyncEnabled()) return

        val pkg = event.packageName?.toString() ?: return
        if (pkg in BLOCKED_PACKAGES) return

        // Extract notification from parcelableData if available
        val notification = event.parcelableData as? Notification
        val extras = notification?.extras

        val title = extras?.getCharSequence("android.title")?.toString()
            ?: event.text?.firstOrNull()?.toString()
            ?: return

        val text = extras?.getCharSequence("android.text")?.toString()
            ?: event.text?.drop(1)?.joinToString(" ")
            ?: ""

        // Deduplicate: skip if same pkg+title+text as last event
        val key = "$pkg|$title|$text"
        if (key == lastNotifKey) return
        lastNotifKey = key

        val appName = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (_: Exception) { pkg }

        val iconBase64 = getAppIconBase64(pkg)

        Log.d(TAG, "Notification via a11y: $appName / $title")

        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_NOTIFICATION
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_APP, appName)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TITLE, title)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TEXT, text)
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_TIME, System.currentTimeMillis())
            if (iconBase64 != null) putExtra(ClipRelayService.EXTRA_NOTIFICATION_ICON, iconBase64)
        }
        startService(intent)
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

    private fun getAppIconBase64(pkg: String): String? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val size = 64
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
        Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

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
