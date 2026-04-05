package org.cliprelay.service

// Starts the ClipRelay foreground service automatically after device boot.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import org.cliprelay.permissions.BlePermissions

class BootCompletedReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootCompletedReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED) {
            return
        }

        if (!BlePermissions.hasRequiredRuntimePermissions(context)) {
            return
        }

        val serviceIntent = Intent(context, ClipRelayService::class.java)
        runCatching {
            ContextCompat.startForegroundService(context, serviceIntent)
        }.onFailure { error ->
            Log.w(TAG, "Could not start service from boot receiver: ${error.message}")
        }
    }
}
