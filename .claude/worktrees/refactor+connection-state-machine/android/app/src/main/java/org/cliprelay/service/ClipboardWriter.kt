package org.cliprelay.service

// Writes received text or images to the Android system clipboard on the main thread.

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import androidx.core.content.FileProvider
import java.io.File

class ClipboardWriter(context: Context) {
    companion object {
        private const val CLIP_LABEL = "cliprelay"
    }

    private val appContext = context.applicationContext
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())

    fun writeText(text: String) {
        val applyWrite = {
            val clip = ClipData.newPlainText(CLIP_LABEL, text)
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
            runCatching { clipboard.setPrimaryClip(clip) }
            Unit
        }
        if (Looper.myLooper() == Looper.getMainLooper()) applyWrite() else mainHandler.post(applyWrite)
    }

    fun writeImage(imageData: ByteArray, contentType: String) {
        val applyWrite = {
            val dir = File(appContext.cacheDir, "shared_images")
            dir.mkdirs()
            val extension = when (contentType) {
                "image/jpeg" -> "jpg"
                else -> "png"
            }
            val file = File(dir, "clipboard_image.$extension")
            file.writeBytes(imageData)
            val uri = FileProvider.getUriForFile(appContext, "${appContext.packageName}.fileprovider", file)
            val mimeType = if (contentType == "image/jpeg") "image/jpeg" else "image/png"
            val clip = ClipData.newUri(appContext.contentResolver, CLIP_LABEL, uri)
            runCatching { clipboard.setPrimaryClip(clip) }
            Unit
        }
        if (Looper.myLooper() == Looper.getMainLooper()) applyWrite() else mainHandler.post(applyWrite)
    }

    fun clearClipIfMatches(expectedText: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (clipMatches(expectedText)) {
                runCatching { clipboard.clearPrimaryClip() }
            }
        } else {
            mainHandler.post {
                if (clipMatches(expectedText)) {
                    runCatching { clipboard.clearPrimaryClip() }
                }
            }
        }
    }

    private fun clipMatches(expectedText: String): Boolean {
        return try {
            val currentClip = clipboard.primaryClip ?: return false
            if (currentClip.itemCount == 0) return false

            val currentLabel = clipboard.primaryClipDescription?.label?.toString()
            if (currentLabel != CLIP_LABEL) return false

            val currentText = currentClip.getItemAt(0).text?.toString() ?: return false
            currentText == expectedText
        } catch (_: SecurityException) {
            false
        }
    }
}
