package com.cliprelay.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper

class ClipboardWriter(context: Context) {
    private val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val mainHandler = Handler(Looper.getMainLooper())

    fun writeText(text: String) {
        val clip = ClipData.newPlainText("cliprelay", text)
        if (Looper.myLooper() == Looper.getMainLooper()) {
            clipboard.setPrimaryClip(clip)
        } else {
            mainHandler.post { clipboard.setPrimaryClip(clip) }
        }
    }
}
