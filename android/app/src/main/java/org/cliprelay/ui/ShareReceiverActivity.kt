package org.cliprelay.ui

// Handles Android share-sheet intents to send shared text or images to the connected Mac.

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import org.cliprelay.R
import org.cliprelay.service.ClipRelayService

class ShareReceiverActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent?.action == Intent.ACTION_SEND) {
            when {
                intent.type?.startsWith("image/") == true -> handleImageShare()
                intent.type?.startsWith("text/") == true -> handleTextShare()
            }
        }

        finish()
    }

    private fun handleTextShare() {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (!text.isNullOrBlank()) {
            val serviceIntent = Intent(this, ClipRelayService::class.java).apply {
                action = ClipRelayService.ACTION_PUSH_TEXT
                putExtra(ClipRelayService.EXTRA_TEXT, text)
            }
            if (!startServiceSafely(serviceIntent)) return
            showSentToast()
        }
    }

    private fun handleImageShare() {
        @Suppress("DEPRECATION")
        val imageUri: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
        if (imageUri == null) return

        val mimeType = intent.type ?: "image/png"

        // Copy image to a temp file to avoid Binder transaction size limits
        val tempFile = java.io.File(cacheDir, "share_image_tmp")
        try {
            contentResolver.openInputStream(imageUri)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            } ?: return
        } catch (e: Exception) {
            Toast.makeText(this, "Could not read image", Toast.LENGTH_SHORT).show()
            return
        }
        if (!tempFile.exists() || tempFile.length() == 0L) return

        val serviceIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_IMAGE
            putExtra(ClipRelayService.EXTRA_IMAGE_PATH, tempFile.absolutePath)
            putExtra(ClipRelayService.EXTRA_IMAGE_MIME, mimeType)
        }
        if (!startServiceSafely(serviceIntent)) return
        showSentToast()
    }

    private fun startServiceSafely(serviceIntent: Intent): Boolean {
        return runCatching {
            ContextCompat.startForegroundService(this, serviceIntent)
            true
        }.getOrElse {
            Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
            finish()
            false
        }
    }

    private fun showSentToast() {
        val deviceName = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
            .getString(ClipRelayService.KEY_CONNECTED_DEVICE, null)
        val message = if (deviceName != null)
            getString(R.string.toast_sent_to, deviceName)
        else
            getString(R.string.toast_sent)
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }
}
