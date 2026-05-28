package org.cliprelay.service

import android.app.Notification
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import org.cliprelay.settings.NotificationSettingsStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class NotificationRelayService : NotificationListenerService() {

    companion object {
        private const val TAG = "NotiSync.Relay"
        private const val ICON_SIZE_PX = 64

        /**
         * Stores Notification.Action objects keyed by StatusBarNotification.key so that
         * ClipRelayService can fire them when the Mac sends a NOTIFICATION_ACTION message.
         * Entries are cleaned up in onNotificationRemoved.
         */
        val pendingActions = ConcurrentHashMap<String, Array<out Notification.Action>>()
    }

    private lateinit var settingsStore: NotificationSettingsStore

    override fun onCreate() {
        super.onCreate()
        settingsStore = NotificationSettingsStore(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!settingsStore.isNotificationSyncEnabled()) return
        if (sbn.packageName == packageName) return
        if (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (sbn.isOngoing) return

        val extras = sbn.notification.extras
        val rawTitle = extras.getCharSequence("android.title")?.toString()?.takeIf { it.isNotBlank() }
            ?: return
        val text = extractFullText(extras)
        val appName = resolveAppLabel(sbn.packageName)

        // Some apps (e.g. Outlook) set android.title = app name and put the
        // real subject/sender in android.subText. Use subText as title in that case.
        val subText = extras.getCharSequence("android.subText")?.toString()?.trim()
        val title = if (rawTitle.equals(appName, ignoreCase = true) && !subText.isNullOrBlank()) {
            subText
        } else {
            rawTitle
        }

        Log.d(TAG, "Relaying: app=$appName title=$title")

        val json = JSONObject().apply {
            put("appName", appName)
            put("title", title)
            put("text", text)
            put("time", sbn.postTime)
            put("notificationKey", sbn.key)
            val icon = renderIconBase64(sbn.packageName)
            if (icon != null) put("iconPng", icon)
        }

        // Serialize and store notification actions for later firing from Mac
        val actions = sbn.notification.actions
        if (!actions.isNullOrEmpty()) {
            pendingActions[sbn.key] = actions
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

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        pendingActions.remove(sbn.key)
    }

    /**
     * Extracts the richest available text from notification extras.
     *
     * Priority:
     *  1. android.messages    – MessagingStyle (WhatsApp, Telegram, Signal…)
     *  2. android.textLines  – InboxStyle (Outlook, Gmail multi-email…)
     *                           Each line is typically "Sender  Subject".
     *  3. android.bigText     – BigTextStyle (Gmail single email, news…)
     *  4. android.subText     – Account/context line many apps set
     *  5. android.text        – Basic one-line fallback
     */
    private fun extractFullText(extras: android.os.Bundle): String {
        // 1. MessagingStyle: individual chat messages with sender names
        @Suppress("DEPRECATION")
        val msgArray = extras.getParcelableArray("android.messages")
        if (msgArray != null && msgArray.isNotEmpty()) {
            val lines = msgArray.takeLast(10).mapNotNull { msg ->
                val bundle = msg as? Bundle ?: return@mapNotNull null
                val sender = bundle.getCharSequence("sender")?.toString()?.takeIf { it.isNotBlank() }
                val msgText = bundle.getCharSequence("text")?.toString()?.takeIf { it.isNotBlank() }
                    ?: return@mapNotNull null
                if (sender != null) "$sender: $msgText" else msgText
            }
            if (lines.isNotEmpty()) return lines.joinToString("\n")
        }

        // 2. InboxStyle: array of lines (Outlook shows "Sender  Subject" per line)
        val inboxLines = extras.getCharSequenceArray("android.textLines")
        if (!inboxLines.isNullOrEmpty()) {
            val text = inboxLines.mapNotNull { it?.toString()?.trim()?.takeIf { s -> s.isNotBlank() } }
                .joinToString("\n")
            if (text.isNotBlank()) return text
        }

        // 3. BigTextStyle: full expanded body
        val bigText = extras.getCharSequence("android.bigText")?.toString()?.trim()
        if (!bigText.isNullOrBlank()) return bigText

        // 4. Combine subText + basic text (some apps put context in subText)
        val subText = extras.getCharSequence("android.subText")?.toString()?.trim()
        val basicText = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
        return when {
            !subText.isNullOrBlank() && basicText.isNotBlank() && subText != basicText ->
                "$basicText\n$subText"
            !subText.isNullOrBlank() -> subText
            else -> basicText
        }
    }

    private fun resolveAppLabel(pkg: String): String = try {
        val info = packageManager.getApplicationInfo(pkg, 0)
        packageManager.getApplicationLabel(info).toString()
    } catch (_: Exception) { pkg }

    private fun renderIconBase64(pkg: String): String? = try {
        val drawable = packageManager.getApplicationIcon(pkg)
        val bitmap = Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, ICON_SIZE_PX, ICON_SIZE_PX)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
        Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }
}
