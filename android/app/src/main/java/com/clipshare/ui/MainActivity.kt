package com.clipshare.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.clipshare.R
import com.clipshare.service.ClipShareService

class MainActivity : AppCompatActivity() {
    private lateinit var status: TextView

    private val scannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            status.text = getString(R.string.status_paired)
            // Tell service to reload pairing and restart advertising
            val reloadIntent = Intent(this, ClipShareService::class.java)
            reloadIntent.action = ClipShareService.ACTION_RELOAD_PAIRING
            startForegroundService(reloadIntent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        requestRuntimePermissions()
        ensureServiceRunning()

        status = findViewById(R.id.statusText)
        status.text = getString(R.string.status_running)

        val pairButton = findViewById<com.google.android.material.button.MaterialButton>(
            R.id.pairWithMacButton
        )
        pairButton.setOnClickListener {
            scannerLauncher.launch(Intent(this, QrScannerActivity::class.java))
        }
    }

    private fun ensureServiceRunning() {
        startForegroundService(Intent(this, ClipShareService::class.java))
    }

    private fun requestRuntimePermissions() {
        val permissions = mutableListOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )

        if (Build.VERSION.SDK_INT >= 33) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), 100)
        }
    }
}
