package com.cliprelay.ui

// Handles Android share-sheet intents to send shared text to the connected Mac.

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.cliprelay.R
import com.cliprelay.service.ClipRelayService

class ShareReceiverActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                val serviceIntent = Intent(this, ClipRelayService::class.java).apply {
                    action = ClipRelayService.ACTION_PUSH_TEXT
                    putExtra(ClipRelayService.EXTRA_TEXT, text)
                }
                runCatching {
                    ContextCompat.startForegroundService(this, serviceIntent)
                }.onFailure {
                    Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
                    finish()
                    return
                }

                val deviceName = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
                    .getString(ClipRelayService.KEY_CONNECTED_DEVICE, null)
                val message = if (deviceName != null)
                    getString(R.string.toast_sent_to, deviceName)
                else
                    getString(R.string.toast_sent)
                Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
            }
        }

        finish()
    }
}
