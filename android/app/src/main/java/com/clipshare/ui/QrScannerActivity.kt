package com.clipshare.ui

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class QrScannerActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val textView = TextView(this)
        textView.text = "QR scanner placeholder (CameraX/ML Kit wiring goes here)."
        textView.setPadding(32, 32, 32, 32)
        setContentView(textView)
    }
}
