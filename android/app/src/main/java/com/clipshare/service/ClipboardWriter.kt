package com.clipshare.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context

class ClipboardWriter(context: Context) {
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    fun writeText(text: String) {
        val clip = ClipData.newPlainText("clipshare", text)
        clipboard.setPrimaryClip(clip)
    }
}
