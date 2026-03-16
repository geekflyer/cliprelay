package org.cliprelay.service

// Writes received text or images to the Android system clipboard on the main thread.

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import java.io.File

class ClipboardWriter(private val context: Context) {
    companion object {
        private const val CLIP_LABEL = "cliprelay"
    }

    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())

    fun writeText(text: String) {
        val applyWrite = {
            val clip = ClipData.newPlainText(CLIP_LABEL, text)
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

    fun writeImage(data: ByteArray, mimeType: String) {
        val ext = when {
            mimeType.contains("png") -> "png"
            mimeType.contains("jpeg") || mimeType.contains("jpg") -> "jpg"
            mimeType.contains("gif") -> "gif"
            mimeType.contains("webp") -> "webp"
            else -> "png"
        }
        val file = File(context.cacheDir, "cliprelay_image.$ext")
        file.writeBytes(data)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        // Grant read permission broadly so any app can paste the image
        context.grantUriPermission("*", uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val applyWrite = {
            val clip = ClipData.newUri(context.contentResolver, CLIP_LABEL, uri)
            runCatching { clipboard.setPrimaryClip(clip) }
            Unit
        }
        if (Looper.myLooper() == Looper.getMainLooper()) applyWrite() else mainHandler.post(applyWrite)
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
