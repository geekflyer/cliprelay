package com.cliprelay.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper

class ClipboardWriter(context: Context) {
    companion object {
        private const val CLIP_LABEL = "cliprelay"
    }

    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())

    fun writeText(text: String) {
        val applyWrite = {
            val clip = ClipData.newPlainText(CLIP_LABEL, text)
            clipboard.setPrimaryClip(clip)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) applyWrite() else mainHandler.post(applyWrite)
    }

    fun clearClipIfMatches(expectedText: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (clipMatches(expectedText)) {
                clipboard.clearPrimaryClip()
            }
        } else {
            mainHandler.post {
                if (clipMatches(expectedText)) {
                    clipboard.clearPrimaryClip()
                }
            }
        }
    }

    private fun clipMatches(expectedText: String): Boolean {
        val currentClip = clipboard.primaryClip ?: return false
        if (currentClip.itemCount == 0) return false

        val currentLabel = clipboard.primaryClipDescription?.label?.toString()
        if (currentLabel != CLIP_LABEL) return false

        val currentText = currentClip.getItemAt(0).text?.toString() ?: return false
        return currentText == expectedText
    }
}
