package org.cliprelay.debug

import android.content.Context
import org.cliprelay.BuildConfig
import java.io.File

object DebugSmokeOverrides {
    private const val SHARED_SECRET_FILE = "debug-smoke-shared-secret.txt"
    private const val DEVICE_NAME_FILE = "debug-smoke-device-name.txt"

    fun sharedSecret(context: Context): String? =
        readOverride(context, SHARED_SECRET_FILE)

    fun connectedDeviceName(context: Context): String? =
        readOverride(context, DEVICE_NAME_FILE)

    fun clear(context: Context) {
        if (!BuildConfig.DEBUG) return
        File(context.filesDir, SHARED_SECRET_FILE).delete()
        File(context.filesDir, DEVICE_NAME_FILE).delete()
    }

    private fun readOverride(context: Context, fileName: String): String? {
        if (!BuildConfig.DEBUG) return null
        val file = File(context.filesDir, fileName)
        if (!file.exists()) return null
        return runCatching { file.readText(Charsets.UTF_8).trim() }
            .getOrNull()
            ?.takeIf { it.isNotEmpty() }
    }
}
