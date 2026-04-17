package org.cliprelay.debug

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import org.cliprelay.service.ClipRelayService

internal object DebugSmokeCommands {
    private const val TAG = "DebugSmokeCommands"

    fun handle(context: Context, intent: Intent?): Int {
        Log.i(TAG, "handle action=${intent?.action}")
        return when (intent?.action) {
            DebugSmokeReceiver.ACTION_IMPORT_PAIRING -> importPairing(
                context,
                intent.getStringExtra("token"),
                intent.getStringExtra("device_name")
            )
            DebugSmokeReceiver.ACTION_CLEAR_PAIRING -> clearPairing(context)
            DebugSmokeReceiver.ACTION_RESET_PROBE -> resetProbe(context)
            else -> 0
        }
    }

    fun importPairing(context: Context, token: String?, deviceName: String?): Int {
        if (token.isNullOrBlank() || !isHexToken(token)) {
            Log.w(TAG, "invalid token")
            return 2
        }

        val normalizedToken = token.lowercase()
        Log.i(TAG, "import pairing tokenTail=${normalizedToken.takeLast(8)} device=$deviceName")

        return runCatching {
            DebugSmokeOverrides.clear(context)
            context.openFileOutput("debug-smoke-shared-secret.txt", Context.MODE_PRIVATE).use {
                it.write(normalizedToken.toByteArray(Charsets.UTF_8))
            }
            if (!deviceName.isNullOrBlank()) {
                context.openFileOutput("debug-smoke-device-name.txt", Context.MODE_PRIVATE).use {
                    it.write(deviceName.toByteArray(Charsets.UTF_8))
                }
            }
            if (!deviceName.isNullOrBlank()) {
                context.getSharedPreferences(ClipRelayService.PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(ClipRelayService.KEY_CONNECTED_DEVICE, deviceName)
                    .apply()
            }
            DebugSmokeProbe.onPairingImported(context, normalizedToken, deviceName)
            reloadPairingInService(context)
            Log.i(TAG, "import pairing complete")
            1
        }.getOrElse {
            Log.e(TAG, "import pairing failed", it)
            3
        }
    }

    fun clearPairing(context: Context): Int {
        return runCatching {
            Log.i(TAG, "clear pairing")
            val unpairStarted = unpairInService(context)
            if (!unpairStarted) {
                DebugSmokeOverrides.clear(context)
            }
            context.getSharedPreferences(ClipRelayService.PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .remove(ClipRelayService.KEY_CONNECTED_DEVICE)
                .apply()
            DebugSmokeProbe.reset(context)
            Log.i(TAG, "clear pairing complete")
            1
        }.getOrElse {
            Log.e(TAG, "clear pairing failed", it)
            3
        }
    }

    fun resetProbe(context: Context): Int {
        return runCatching {
            Log.i(TAG, "reset probe")
            DebugSmokeProbe.reset(context)
            1
        }.getOrElse {
            Log.e(TAG, "reset probe failed", it)
            3
        }
    }

    private fun isHexToken(token: String): Boolean {
        if (token.length != 64) return false
        return token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }

    private fun reloadPairingInService(context: Context) {
        val reloadIntent = Intent(context, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_RELOAD_PAIRING
        }

        val startedExistingService = runCatching {
            context.startService(reloadIntent)
        }.getOrNull() != null

        if (!startedExistingService) {
            ContextCompat.startForegroundService(context, reloadIntent)
        }
    }

    private fun unpairInService(context: Context): Boolean {
        val unpairIntent = Intent(context, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_UNPAIR
        }

        val startedExistingService = runCatching {
            context.startService(unpairIntent)
        }.getOrNull() != null

        if (startedExistingService) {
            return true
        }

        return runCatching {
            ContextCompat.startForegroundService(context, unpairIntent)
            true
        }.getOrDefault(false)
    }
}
