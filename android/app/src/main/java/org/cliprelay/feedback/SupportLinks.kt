package org.cliprelay.feedback

// Builds pre-filled support URLs with device context.

import android.content.Context
import android.net.Uri
import android.os.Build
import org.cliprelay.BuildConfig
import org.cliprelay.pairing.PairingStore
import org.cliprelay.settings.ClipboardSettingsStore

object SupportLinks {
    private fun deviceContext(): List<Pair<String, String>> = listOf(
        "App Version" to "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}, ${BuildConfig.GIT_HASH})" +
            if (BuildConfig.DEBUG) " [debug]" else "",
        "OS" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
        "Device" to "${Build.MANUFACTURER} ${Build.MODEL}",
    )

    /** App / device / flag context shared by GitHub issues, support emails, and log shares. */
    fun diagnosticsContext(context: Context, bleState: String): List<Pair<String, String>> {
        val settings = ClipboardSettingsStore(context)
        val pairing = PairingStore(context)
        val flags = listOf(
            "autoCopy" to settings.isAutoCopyEnabled(),
            "otpRelay" to settings.isOtpRelayEnabled(),
            "hideSyncedClipboard" to settings.isHideSyncedClipboardEnabled(),
            "autoClearSyncedClipboard" to settings.isAutoClearSyncedClipboardEnabled(),
            "imageSync" to pairing.isRichMediaEnabled(),
        ).joinToString(", ") { "${it.first}=${it.second}" }
        return deviceContext() + listOf(
            "BLE State" to bleState,
            "Paired Macs" to pairing.loadPairedMacs().size.toString(),
            "Flags" to flags,
        )
    }

    fun gitHubIssueUrl(context: Context, bleState: String): String {
        val lines = diagnosticsContext(context, bleState)
            .joinToString("\n") { "- **${it.first}:** ${it.second}" }
        val body = "\n\n---\n$lines"
        return Uri.parse("https://github.com/geekflyer/cliprelay/issues/new").buildUpon()
            .appendQueryParameter("body", body)
            .appendQueryParameter("labels", "from-app")
            .build()
            .toString()
    }

    fun emailUrl(context: Context, bleState: String): String {
        val lines = diagnosticsContext(context, bleState)
            .joinToString("\n") { "${it.first}: ${it.second}" }
        val body = "\n\n---\n$lines"
        return "mailto:info@cliprelay.org" +
            "?subject=${Uri.encode("ClipRelay Feedback")}" +
            "&body=${Uri.encode(body)}"
    }

    const val DISCUSSIONS_URL = "https://github.com/geekflyer/cliprelay/discussions"

    const val PLAY_STORE_URL =
        "https://play.google.com/store/apps/details?id=${BuildConfig.APPLICATION_ID}"
}
