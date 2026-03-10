package org.cliprelay.ui

// Main activity: handles permissions, QR scanning results, and hosts the Compose UI.

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import org.cliprelay.crypto.E2ECrypto
import org.cliprelay.pairing.PairingStore
import org.cliprelay.permissions.BlePermissions
import org.cliprelay.service.ClipRelayService
import org.cliprelay.settings.ClipboardSettingsStore

class MainActivity : AppCompatActivity() {

    private val viewModel: MainViewModel by viewModels()
    private lateinit var clipboardSettingsStore: ClipboardSettingsStore

    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ClipRelayService.ACTION_CONNECTION_STATE -> {
                    val connected = intent.getBooleanExtra(ClipRelayService.EXTRA_CONNECTED, false)
                    val name = intent.getStringExtra(ClipRelayService.EXTRA_DEVICE_NAME)
                    viewModel.onConnectionChanged(connected, name)
                }
                ClipRelayService.ACTION_PAIRING_COMPLETE -> {
                    val deviceTag = intent.getStringExtra(ClipRelayService.EXTRA_DEVICE_TAG)
                    viewModel.onPaired(deviceTag)
                }
                ClipRelayService.ACTION_CLIPBOARD_TRANSFER -> {
                    val fromMac = intent.getBooleanExtra(ClipRelayService.EXTRA_FROM_MAC, true)
                    viewModel.onClipboardTransfer(fromMac)
                }
            }
        }
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        ensureServiceRunning()
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    private val scannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            // Don't compute device tag here — ECDH handshake hasn't completed yet.
            // The service will broadcast ACTION_PAIRING_COMPLETE with the tag.
            viewModel.onPaired(deviceTag = null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        requestRuntimePermissions()
        ensureServiceRunning()
        clipboardSettingsStore = ClipboardSettingsStore(this)

        val secret = PairingStore(this).loadSharedSecret()
        val isPaired = secret != null
        val deviceName = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
            .getString(ClipRelayService.KEY_CONNECTED_DEVICE, null)
        val deviceTag = secret?.let { s ->
            val hex = E2ECrypto.deviceTag(s).take(4).joinToString("") { "%02X".format(it) }
            hex.chunked(4).joinToString(" ")
        }
        val autoClearEnabled = clipboardSettingsStore.isAutoClearSyncedClipboardEnabled()
        viewModel.initState(isPaired, deviceName, deviceTag, autoClearEnabled)

        setContent {
            val state by viewModel.state.collectAsState()
            val showBurst by viewModel.showBurst.collectAsState()
            val autoClearEnabled by viewModel.autoClearEnabled.collectAsState()

            ClipRelayScreen(
                state = state,
                showBurst = showBurst,
                clipboardTransferFlow = viewModel.clipboardTransfer,
                autoClearEnabled = autoClearEnabled,
                onPairClick = {
                    scannerLauncher.launch(Intent(this, QrScannerActivity::class.java))
                },
                onUnpairClick = {
                    viewModel.onUnpaired()
                    val unpairIntent = Intent(this, ClipRelayService::class.java)
                    unpairIntent.action = ClipRelayService.ACTION_UNPAIR
                    if (!startServiceSafely(unpairIntent)) {
                        PairingStore(this).clear()
                    }
                },
                onBurstShown = {
                    viewModel.onBurstShown()
                },
                onAutoClearSettingChanged = { enabled ->
                    viewModel.onAutoClearSettingChanged(enabled)
                    clipboardSettingsStore.setAutoClearSyncedClipboardEnabled(enabled)
                }
            )
        }
    }

    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(ClipRelayService.ACTION_CONNECTION_STATE).also {
            it.addAction(ClipRelayService.ACTION_PAIRING_COMPLETE)
            it.addAction(ClipRelayService.ACTION_CLIPBOARD_TRANSFER)
        }
        ContextCompat.registerReceiver(
            this,
            connectionReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    override fun onPause() {
        super.onPause()
        unregisterReceiver(connectionReceiver)
    }

    private fun ensureServiceRunning() {
        startServiceSafely(Intent(this, ClipRelayService::class.java))
    }

    private fun startServiceSafely(intent: Intent): Boolean {
        if (!BlePermissions.hasRequiredRuntimePermissions(this)) return false
        val started = runCatching {
            ContextCompat.startForegroundService(this, intent)
        }.isSuccess
        if (!started) {
            Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
        }
        return started
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
            permissionLauncher.launch(missing.toTypedArray())
        }
    }
}
