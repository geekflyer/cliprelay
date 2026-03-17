package org.cliprelay.ui

// Handles Android share-sheet intents to send shared text or images to the connected Mac.

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import org.cliprelay.R
import org.cliprelay.service.ClipRelayService
import java.io.File

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
            runCatching {
                ContextCompat.startForegroundService(this, serviceIntent)
            }.onFailure {
                Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
                return
            }
            showSentToast()
        }
    }

    private fun handleImageShare() {
        val imageUri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

        if (imageUri == null) {
            Toast.makeText(this, "No image to send", Toast.LENGTH_SHORT).show()
            return
        }

        // Check size via OpenableColumns
        val maxSize = 10_485_760L // 10 MB
        val size = getUriSize(imageUri)
        if (size != null && size > maxSize) {
            Toast.makeText(this, "Image too large to send (max 10 MB)", Toast.LENGTH_SHORT).show()
            return
        }

        // Copy to cache file
        val mimeType = intent.type ?: contentResolver.getType(imageUri) ?: "image/png"
        val extension = when {
            mimeType.contains("jpeg") || mimeType.contains("jpg") -> "jpg"
            else -> "png"
        }
        val cacheDir = File(cacheDir, "shared_images")
        cacheDir.mkdirs()
        val cacheFile = File(cacheDir, "share_image_${System.currentTimeMillis()}.$extension")

        try {
            contentResolver.openInputStream(imageUri)?.use { input ->
                cacheFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: run {
                Toast.makeText(this, "Could not read image", Toast.LENGTH_SHORT).show()
                return
            }
        } catch (e: Exception) {
            Toast.makeText(this, "Could not read image", Toast.LENGTH_SHORT).show()
            return
        }

        // Double-check actual file size after copy
        if (cacheFile.length() > maxSize) {
            cacheFile.delete()
            Toast.makeText(this, "Image too large to send (max 10 MB)", Toast.LENGTH_SHORT).show()
            return
        }

        val serviceIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_IMAGE
            putExtra(ClipRelayService.EXTRA_IMAGE_PATH, cacheFile.absolutePath)
            putExtra(ClipRelayService.EXTRA_MIME_TYPE, mimeType)
        }
        runCatching {
            ContextCompat.startForegroundService(this, serviceIntent)
        }.onFailure {
            cacheFile.delete()
            Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
            return
        }
        showSentToast()
    }

    private fun getUriSize(uri: Uri): Long? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null
                } else null
            }
        } catch (_: Exception) {
            null
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
