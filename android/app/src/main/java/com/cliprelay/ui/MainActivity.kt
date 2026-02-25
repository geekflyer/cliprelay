package com.cliprelay.ui

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import android.view.View
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.cliprelay.R
import com.cliprelay.pairing.PairingStore
import com.cliprelay.permissions.BlePermissions
import com.cliprelay.service.ClipRelayService

class MainActivity : AppCompatActivity() {
    companion object {
        private const val PERMISSION_REQUEST_CODE = 100
    }

    private lateinit var status: TextView
    private lateinit var pairButton: com.google.android.material.button.MaterialButton
    private lateinit var unpairButton: com.google.android.material.button.MaterialButton
    private var isPaired = false
    private var connectedDeviceName: String? = null

    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ClipRelayService.ACTION_CONNECTION_STATE) {
                val connected = intent.getBooleanExtra(ClipRelayService.EXTRA_CONNECTED, false)
                if (connected) {
                    connectedDeviceName = intent.getStringExtra(ClipRelayService.EXTRA_DEVICE_NAME)
                } else {
                    connectedDeviceName = null
                }
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
            val reloadIntent = Intent(this, ClipRelayService::class.java)
            reloadIntent.action = ClipRelayService.ACTION_RELOAD_PAIRING
            startServiceSafely(reloadIntent)
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
            val reloadIntent = Intent(this, ClipRelayService::class.java)
            reloadIntent.action = ClipRelayService.ACTION_RELOAD_PAIRING
            startServiceSafely(reloadIntent)
        }
    }

    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(ClipRelayService.ACTION_CONNECTION_STATE)
        ContextCompat.registerReceiver(
            this,
            connectionReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        // Ask service for current connection state
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    override fun onPause() {
        super.onPause()
        unregisterReceiver(connectionReceiver)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) return

        ensureServiceRunning()
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    private fun updateUI(connected: Boolean) {
        status.text = when {
            !isPaired -> getString(R.string.status_help)
            connected -> {
                val name = connectedDeviceName
                if (name != null) getString(R.string.status_connected_to, name)
                else getString(R.string.status_connected)
            }
            else -> getString(R.string.status_paired)
        }
        pairButton.visibility = if (isPaired) View.GONE else View.VISIBLE
        unpairButton.visibility = if (isPaired) View.VISIBLE else View.GONE
    }

    private fun ensureServiceRunning() {
        startServiceSafely(Intent(this, ClipRelayService::class.java))
    }

    private fun startServiceSafely(intent: Intent) {
        if (!BlePermissions.hasRequiredRuntimePermissions(this)) {
            return
        }

        val started = runCatching {
            ContextCompat.startForegroundService(this, intent)
        }.isSuccess
        if (!started) {
            Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
        }
    }

    private fun requestRuntimePermissions() {
        val permissions = BlePermissions.requiredRuntimePermissions().toMutableList()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        if (permissions.isEmpty()) return

        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERMISSION_REQUEST_CODE)
        }
    }
}
