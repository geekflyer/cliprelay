package com.clipshare.ui

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.clipshare.R
import com.clipshare.pairing.PairingStore
import com.clipshare.service.ClipShareService

class MainActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private lateinit var pairButton: com.google.android.material.button.MaterialButton
    private lateinit var unpairButton: com.google.android.material.button.MaterialButton
    private var isPaired = false

    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ClipShareService.ACTION_CONNECTION_STATE) {
                val connected = intent.getBooleanExtra(ClipShareService.EXTRA_CONNECTED, false)
                updateUI(connected)
            }
        }
    }

    private val scannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            isPaired = true
            updateUI(connected = false)
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
        pairButton = findViewById(R.id.pairWithMacButton)
        unpairButton = findViewById(R.id.unpairButton)
        isPaired = PairingStore(this).loadToken() != null
        updateUI(connected = false)

        pairButton.setOnClickListener {
            scannerLauncher.launch(Intent(this, QrScannerActivity::class.java))
        }
        unpairButton.setOnClickListener {
            PairingStore(this).clear()
            isPaired = false
            updateUI(connected = false)
            val reloadIntent = Intent(this, ClipShareService::class.java)
            reloadIntent.action = ClipShareService.ACTION_RELOAD_PAIRING
            startForegroundService(reloadIntent)
        }
    }

    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(ClipShareService.ACTION_CONNECTION_STATE)
        registerReceiver(connectionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        // Ask service for current connection state
        val queryIntent = Intent(this, ClipShareService::class.java)
        queryIntent.action = ClipShareService.ACTION_QUERY_CONNECTION
        startForegroundService(queryIntent)
    }

    override fun onPause() {
        super.onPause()
        unregisterReceiver(connectionReceiver)
    }

    private fun updateUI(connected: Boolean) {
        status.text = when {
            !isPaired -> getString(R.string.status_help)
            connected -> getString(R.string.status_connected)
            else -> getString(R.string.status_paired)
        }
        pairButton.visibility = if (isPaired) View.GONE else View.VISIBLE
        unpairButton.visibility = if (isPaired) View.VISIBLE else View.GONE
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
