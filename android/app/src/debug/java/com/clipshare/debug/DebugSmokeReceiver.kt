package com.clipshare.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.clipshare.pairing.PairingStore
import com.clipshare.service.ClipShareService

class DebugSmokeReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_IMPORT_PAIRING = "com.clipshare.debug.IMPORT_PAIRING"
        const val ACTION_CLEAR_PAIRING = "com.clipshare.debug.CLEAR_PAIRING"
        const val ACTION_RESET_PROBE = "com.clipshare.debug.RESET_PROBE"
        private const val EXTRA_TOKEN = "token"
        private const val EXTRA_DEVICE_NAME = "device_name"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            ACTION_IMPORT_PAIRING -> {
                val token = intent.getStringExtra(EXTRA_TOKEN)
                if (token.isNullOrBlank() || !isHexToken(token)) {
                    setResultCode(2)
                    return
                }
                val normalizedToken = token.lowercase()
                val deviceName = intent.getStringExtra(EXTRA_DEVICE_NAME)

                runCatching {
                    PairingStore(context).saveToken(normalizedToken)
                    if (!deviceName.isNullOrBlank()) {
                        context.getSharedPreferences(ClipShareService.PREFS_NAME, Context.MODE_PRIVATE)
                            .edit()
                            .putString(ClipShareService.KEY_CONNECTED_DEVICE, deviceName)
                            .apply()
                    }
                    DebugSmokeProbe.onPairingImported(context, normalizedToken, deviceName)
                    reloadPairingInService(context)
                }.onFailure {
                    setResultCode(3)
                    return
                }

                setResultCode(1)
            }

            ACTION_CLEAR_PAIRING -> {
                runCatching {
                    PairingStore(context).clear()
                    context.getSharedPreferences(ClipShareService.PREFS_NAME, Context.MODE_PRIVATE)
                        .edit()
                        .remove(ClipShareService.KEY_CONNECTED_DEVICE)
                        .apply()
                    reloadPairingInService(context)
                    DebugSmokeProbe.reset(context)
                }.onFailure {
                    setResultCode(3)
                    return
                }

                setResultCode(1)
            }

            ACTION_RESET_PROBE -> {
                DebugSmokeProbe.reset(context)
                setResultCode(1)
            }

            else -> {
                setResultCode(0)
            }
        }
    }

    private fun isHexToken(token: String): Boolean {
        if (token.length != 64) return false
        return token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }

    private fun reloadPairingInService(context: Context) {
        val reloadIntent = Intent(context, ClipShareService::class.java).apply {
            action = ClipShareService.ACTION_RELOAD_PAIRING
        }

        val startedExistingService = runCatching {
            context.startService(reloadIntent)
        }.getOrNull() != null

        if (!startedExistingService) {
            ContextCompat.startForegroundService(context, reloadIntent)
        }
    }
}
