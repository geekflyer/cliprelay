package org.cliprelay.feedback

// Builds pre-filled support URLs with device context.

import android.net.Uri
import android.os.Build
import org.cliprelay.BuildConfig

object SupportLinks {
    private fun deviceContext(): List<Pair<String, String>> = listOf(
        "App Version" to "${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_HASH})",
        "OS" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
        "Device" to "${Build.MANUFACTURER} ${Build.MODEL}",
    )

    fun gitHubIssueUrl(bleState: String): String {
        val lines = (deviceContext() + ("BLE State" to bleState))
            .joinToString("\n") { "- **${it.first}:** ${it.second}" }
        val body = "\n\n---\n$lines"
        return Uri.parse("https://github.com/geekflyer/cliprelay/issues/new").buildUpon()
            .appendQueryParameter("body", body)
            .appendQueryParameter("labels", "from-app")
            .build()
            .toString()
    }

    fun emailUrl(bleState: String): String {
        val lines = (deviceContext() + ("BLE State" to bleState))
            .joinToString("\n") { "${it.first}: ${it.second}" }
        val body = "\n\n---\n$lines"
        return "mailto:info@cliprelay.org" +
            "?subject=${Uri.encode("ClipRelay Feedback")}" +
            "&body=${Uri.encode(body)}"
    }

    const val DISCUSSIONS_URL = "https://github.com/geekflyer/cliprelay/discussions"
}
