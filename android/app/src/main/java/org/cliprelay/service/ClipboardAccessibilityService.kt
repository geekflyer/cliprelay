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
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var settingsStore: ClipboardSettingsStore
    private lateinit var notificationSettingsStore: NotificationSettingsStore

    // Tracks whether a copy toolbar was recently visible
    @Volatile
    private var copyToolbarVisible = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        settingsStore = ClipboardSettingsStore(this)
        notificationSettingsStore = NotificationSettingsStore(this)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> {
                if (::notificationSettingsStore.isInitialized && notificationSettingsStore.isNotificationSyncEnabled()) {
                    handleNotificationEvent(event)
                }
            }
            else -> {
                if (!::settingsStore.isInitialized || !settingsStore.isAutoCopyEnabled()) return
                when (event.eventType) {
                    AccessibilityEvent.TYPE_VIEW_CLICKED -> handleClickEvent(event)
                    AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> handleWindowStateChanged(event)
                }
            }
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

    // ── TYPE_NOTIFICATION_STATE_CHANGED (Samsung workaround) ─────────

    private fun handleNotificationEvent(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        if (pkg == packageName || pkg == "android" || pkg == "com.android.systemui") return

        @Suppress("DEPRECATION")
        val notification = event.parcelableData as? Notification ?: return
        if ((notification.flags and Notification.FLAG_ONGOING_EVENT) != 0) return

        val isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0

        // Email apps (e.g. Outlook) send all useful content in the GROUP_SUMMARY using
        // InboxStyle (android.textLines). Individual child notifications are delivered
        // with only the privacy-redacted public version, making them useless.
        // Allow GROUP_SUMMARY through for email category; skip it for everything else.
        val isEmail = notification.category == Notification.CATEGORY_EMAIL
        if (isGroupSummary && !isEmail) return

        val extras = notification.extras ?: return
        val rawTitle = extras.getCharSequence("android.title")?.toString()?.takeIf { it.isNotBlank() } ?: return
        val text = extractFullText(extras)

        val appName = try {
            val info = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(info).toString()
        } catch (_: Exception) { pkg }

        // Samsung delivers the privacy-redacted public version of VISIBILITY_PRIVATE
        // notifications to the AccessibilityService. Detect this by checking whether
        // the title is just the app name AND the text is suspiciously short.
        // These carry no useful content so we skip them.
        if (rawTitle.equals(appName, ignoreCase = true) && text.length < 20) return

        // Use subText as title when the title equals the app name (Outlook pattern)
        val subText = extras.getCharSequence("android.subText")?.toString()?.trim()
        val title = if (rawTitle.equals(appName, ignoreCase = true) && !subText.isNullOrBlank()) {
            subText
        } else {
            rawTitle
        }

        // Generate a synthetic key — AccessibilityService doesn't have sbn.key
        val notifKey = "${pkg}-${event.eventTime}"

        val json = JSONObject().apply {
            put("appName", appName)
            put("title", title)
            put("text", text)
            put("time", event.eventTime)
            put("notificationKey", notifKey)
            renderIconBase64(pkg)?.let { put("iconPng", it) }
        }

        // Serialize and store notification actions for later firing from Mac
        val actions = notification.actions
        if (!actions.isNullOrEmpty()) {
            pendingActions[notifKey] = actions
            val actionsJson = JSONArray()
            actions.forEachIndexed { index, action ->
                val hasReply = action.remoteInputs?.any { it.allowFreeFormInput } == true
                actionsJson.put(JSONObject().apply {
                    put("index", index)
                    put("title", action.title?.toString() ?: "")
                    put("hasReply", hasReply)
                })
            }
            json.put("actions", actionsJson)
        }

        val intent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_NOTIFICATION
            putExtra(ClipRelayService.EXTRA_NOTIFICATION_PAYLOAD, json.toString().toByteArray(Charsets.UTF_8))
        }
        startService(intent)
    }

    private fun extractFullText(extras: android.os.Bundle): String {
        // 1. MessagingStyle: individual chat messages (WhatsApp, Telegram, Signal…)
        @Suppress("DEPRECATION")
        val msgArray = extras.getParcelableArray("android.messages")
        if (msgArray != null && msgArray.isNotEmpty()) {
            val lines = msgArray.takeLast(10).mapNotNull { msg ->
                val bundle = msg as? android.os.Bundle ?: return@mapNotNull null
                val sender = bundle.getCharSequence("sender")?.toString()?.takeIf { it.isNotBlank() }
                val msgText = bundle.getCharSequence("text")?.toString()?.takeIf { it.isNotBlank() }
                    ?: return@mapNotNull null
                if (sender != null) "$sender: $msgText" else msgText
            }
            if (lines.isNotEmpty()) return lines.joinToString("\n")
        }
        // 2. InboxStyle lines (Outlook, Gmail multi-email — "Sender  Subject" per line)
        val inboxLines = extras.getCharSequenceArray("android.textLines")
        if (!inboxLines.isNullOrEmpty()) {
            val text = inboxLines.mapNotNull { it?.toString()?.trim()?.takeIf { s -> s.isNotBlank() } }
                .joinToString("\n")
            if (text.isNotBlank()) return text
        }
        // 3. BigTextStyle full body
        val bigText = extras.getCharSequence("android.bigText")?.toString()?.trim()
        if (!bigText.isNullOrBlank()) return bigText
        // 4. Combine subText + basic text
        val subText = extras.getCharSequence("android.subText")?.toString()?.trim()
        val basicText = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
        return when {
            !subText.isNullOrBlank() && basicText.isNotBlank() && subText != basicText ->
                "$basicText\n$subText"
            !subText.isNullOrBlank() -> subText
            else -> basicText
        }
    }

    private fun renderIconBase64(pkg: String): String? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, 64, 64)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
        Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

    companion object {
        private const val TAG = "ClipboardA11y"

        /**
         * Stores Notification.Action objects keyed by a synthetic key ("pkg-eventTime") so that
         * ClipRelayService can fire them when the Mac sends a NOTIFICATION_ACTION message.
         * This is the Samsung fallback path — NotificationListenerService is not used.
         */
        val pendingActions = ConcurrentHashMap<String, Array<out Notification.Action>>()

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
