package com.cliprelay.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.NotificationCompat
import com.cliprelay.R
import com.cliprelay.ble.Advertiser
import com.cliprelay.ble.BleInboundStateMachine
import com.cliprelay.ble.ChunkTransfer
import com.cliprelay.ble.GattServerCallback
import com.cliprelay.ble.GattServerManager
import com.cliprelay.crypto.E2ECrypto
import com.cliprelay.debug.DebugSmokeProbe
import com.cliprelay.permissions.BlePermissions
import com.cliprelay.pairing.PairingStore
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.SecretKey

class ClipRelayService : Service() {
    companion object {
        const val ACTION_PUSH_TEXT = "com.cliprelay.action.PUSH_TEXT"
        const val ACTION_RELOAD_PAIRING = "com.cliprelay.action.RELOAD_PAIRING"
        const val ACTION_UNPAIR = "com.cliprelay.action.UNPAIR"
        const val ACTION_CONNECTION_STATE = "com.cliprelay.action.CONNECTION_STATE"
        const val ACTION_QUERY_CONNECTION = "com.cliprelay.action.QUERY_CONNECTION"
        const val ACTION_CLIPBOARD_TRANSFER = "com.cliprelay.action.CLIPBOARD_TRANSFER"
        const val EXTRA_TEXT = "extra_text"
        const val EXTRA_CONNECTED = "extra_connected"
        const val EXTRA_DEVICE_NAME = "extra_device_name"
        const val EXTRA_FROM_MAC = "extra_from_mac"

        const val PREFS_NAME = "cliprelay_state"
        const val KEY_CONNECTED_DEVICE = "connected_device_name"

        private const val TAG = "ClipRelayService"
        private const val MAX_CLIPBOARD_BYTES = 102_400
        private const val STALE_CONNECTION_CHECK_INTERVAL_MS = 60_000L
        private const val STALE_CONNECTION_TIMEOUT_SECONDS = 90
        private const val PAYLOAD_TYPE_TEXT = "text/plain"
        private const val PAYLOAD_TYPE_CONTROL = "application/x-cliprelay-control"
        private const val CONTROL_EVENT_ANDROID_UNPAIRED = "android_unpaired"
    }

    private lateinit var gattServer: GattServerManager
    private lateinit var gattCallback: GattServerCallback
    private lateinit var advertiser: Advertiser
    private lateinit var clipboardWriter: ClipboardWriter
    private lateinit var pairingStore: PairingStore

    private val transferExecutor = Executors.newSingleThreadExecutor()
    private val inboundStateMachine = BleInboundStateMachine()
    private val staleConnectionHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var bleStarted = false
    @Volatile
    private var isDestroyed = false

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> {
                    Log.d(TAG, "Bluetooth enabled — ensuring BLE components are running")
                    ensureBleComponentsState(restartIfRunning = true)
                    sendConnectionBroadcast(false)
                }
                BluetoothAdapter.STATE_OFF -> {
                    Log.d(TAG, "Bluetooth disabled — stopping GATT server and advertiser")
                    stopBleComponents()
                }
            }
        }
    }

    @Volatile
    private var encryptionKey: SecretKey? = null

    @Volatile
    private var lastInboundHash: String? = null

    override fun onCreate() {
        super.onCreate()

        clipboardWriter = ClipboardWriter(this)
        pairingStore = PairingStore(this)

        gattCallback = GattServerCallback(
            onAvailableReceived = { deviceId, bytes ->
                transferExecutor.execute {
                    handleAvailableMetadata(deviceId, bytes)
                }
            },
            onDataReceived = { deviceId, bytes ->
                transferExecutor.execute {
                    handleIncomingDataFrame(deviceId, bytes)
                }
            },
            onDeviceConnectionChanged = { deviceId, isConnected, hasConnectedDevices ->
                if (!isConnected) {
                    transferExecutor.execute {
                        inboundStateMachine.onDisconnected(deviceId)
                    }
                }
                DebugSmokeProbe.onConnectionChanged(this, hasConnectedDevices)
                val name = loadConnectedDeviceName()
                sendConnectionBroadcast(hasConnectedDevices, name)
            }
        )
        gattServer = GattServerManager(this, gattCallback)

        advertiser = Advertiser(this, ParcelUuid(GattServerManager.SERVICE_UUID))
        loadPairingState()
        DebugSmokeProbe.reset(this)

        startForeground(1001, buildNotification())
        registerReceiver(bluetoothStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        ensureBleComponentsState()
        scheduleStaleConnectionCheck()
    }

    override fun onDestroy() {
        isDestroyed = true
        staleConnectionHandler.removeCallbacksAndMessages(null)
        unregisterReceiver(bluetoothStateReceiver)
        transferExecutor.shutdownNow()
        stopBleComponents()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        loadPairingState()

        if (intent?.action == ACTION_UNPAIR) {
            handleUnpairRequest()
            return START_STICKY
        }

        ensureBleComponentsState()

        when (intent?.action) {
            ACTION_PUSH_TEXT -> {
                val text = intent.getStringExtra(EXTRA_TEXT)
                if (!text.isNullOrBlank()) {
                    transferExecutor.execute {
                        pushPlainTextToMac(text)
                    }
                }
            }
            ACTION_RELOAD_PAIRING -> {
                // If token was cleared (unpair), stop the entire BLE stack.
                // server.close() tears down all central connections, and we
                // intentionally do NOT restart — there's nothing to connect to
                // when unpaired. A new pairing via QR will trigger another
                // RELOAD_PAIRING that restarts everything.
                if (encryptionKey == null) {
                    if (bleStarted) {
                        stopBleComponents(disconnectCentralsFirst = true)
                    }
                    sendConnectionBroadcast(false)
                } else if (BlePermissions.hasRequiredRuntimePermissions(this)) {
                    if (bleStarted) {
                        advertiser.restart()
                    } else {
                        ensureBleComponentsState()
                    }
                } else {
                    Log.w(TAG, "BLE runtime permissions missing; stopping BLE components")
                    stopBleComponents()
                }
                transferExecutor.execute {
                    inboundStateMachine.resetAll()
                }
            }
            ACTION_QUERY_CONNECTION -> {
                val connected = gattServer.hasConnectedCentral()
                val name = if (connected) loadConnectedDeviceName() else null
                sendConnectionBroadcast(connected, name)
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureBleComponentsState(restartIfRunning: Boolean = false) {
        if (encryptionKey == null) {
            if (bleStarted) {
                Log.d(TAG, "Pairing token missing; stopping BLE components")
                stopBleComponents(disconnectCentralsFirst = true)
            }
            return
        }

        if (!BlePermissions.hasRequiredRuntimePermissions(this)) {
            if (bleStarted) {
                Log.w(TAG, "BLE runtime permissions missing; stopping BLE components")
                stopBleComponents()
            }
            return
        }

        if (restartIfRunning && bleStarted) {
            stopBleComponents(broadcastDisconnected = false)
        }

        if (bleStarted) {
            return
        }

        val started = runCatching {
            gattServer.start()
            advertiser.start()
            true
        }.getOrElse { error ->
            bleStarted = false
            advertiser.stop()
            gattServer.stop()
            if (error is SecurityException) {
                Log.e(TAG, "BLE startup blocked by missing runtime permission", error)
            } else {
                Log.e(TAG, "BLE startup failed", error)
            }
            false
        }

        bleStarted = started
        if (!started) {
            sendConnectionBroadcast(false)
        }
    }

    private fun stopBleComponents(
        broadcastDisconnected: Boolean = true,
        disconnectCentralsFirst: Boolean = false
    ) {
        if (disconnectCentralsFirst) {
            gattServer.disconnectAllCentrals()
        }
        advertiser.stop()
        gattServer.stop()
        bleStarted = false
        transferExecutor.execute {
            inboundStateMachine.resetAll()
        }
        if (broadcastDisconnected) {
            sendConnectionBroadcast(false)
        }
    }

    private fun loadPairingState() {
        val token = pairingStore.loadToken()
        if (token != null) {
            encryptionKey = E2ECrypto.deriveKey(token)
            advertiser.deviceTag = E2ECrypto.deviceTag(token)
        } else {
            encryptionKey = null
            advertiser.deviceTag = null
            saveConnectedDeviceName(null)
        }
    }

    private fun handleIncomingDataFrame(deviceId: String, frame: ByteArray) {
        val assembled = inboundStateMachine.onDataFrame(deviceId, frame) ?: return
        val assembledBytes = assembled.bytes

        // Decrypt
        val key = encryptionKey
        if (key == null) {
            Log.w(TAG, "No encryption key; ignoring incoming data")
            return
        }

        val plaintext = try {
            E2ECrypto.open(assembledBytes, key)
        } catch (e: Exception) {
            Log.e(TAG, "Decryption failed: ${e.message}")
            return
        }

        val decodedText = plaintext.toString(Charsets.UTF_8)
        if (decodedText.isEmpty()) return

        val hash = sha256Hex(decodedText.toByteArray(Charsets.UTF_8))
        if (hash == lastInboundHash) return

        lastInboundHash = hash
        clipboardWriter.writeText(decodedText)
        sendClipboardTransferBroadcast(fromMac = true)
        DebugSmokeProbe.onInboundClipboardApplied(this, decodedText)
    }

    private fun handleAvailableMetadata(deviceId: String, metadata: ByteArray) {
        inboundStateMachine.onAvailableMetadata(deviceId, metadata)
    }

    private fun pushPlainTextToMac(text: String) {
        if (isDestroyed) return
        val plaintext = text.toByteArray(Charsets.UTF_8)
        if (plaintext.isEmpty() || plaintext.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        if (!gattServer.hasConnectedCentral()) {
            Log.d(TAG, "No connected Mac central; skipping Android->Mac push")
            return
        }

        val key = encryptionKey
        if (key == null) {
            Log.w(TAG, "No encryption key; skipping Android->Mac push")
            return
        }

        val published = publishEncryptedPayloadToMac(
            plaintext = plaintext,
            key = key,
            payloadType = PAYLOAD_TYPE_TEXT
        )
        if (!published) {
            Log.d(TAG, "No subscribers for Android->Mac push")
        } else {
            sendClipboardTransferBroadcast(fromMac = false)
            DebugSmokeProbe.onOutboundClipboardPublished(this, text)
        }
    }

    private fun handleUnpairRequest() {
        encryptionKey?.let { key ->
            publishAndroidUnpairedControl(key)
        }

        pairingStore.clear()
        loadPairingState()

        if (bleStarted) {
            stopBleComponents(disconnectCentralsFirst = true)
        } else {
            sendConnectionBroadcast(false)
        }

        transferExecutor.execute {
            inboundStateMachine.resetAll()
        }
    }

    private fun publishAndroidUnpairedControl(key: SecretKey) {
        val controlPayload = JSONObject()
            .put("event", CONTROL_EVENT_ANDROID_UNPAIRED)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val published = publishEncryptedPayloadToMac(
            plaintext = controlPayload,
            key = key,
            payloadType = PAYLOAD_TYPE_CONTROL
        )
        if (published) {
            Log.d(TAG, "Published Android unpair control event")
        } else {
            Log.d(TAG, "No connected Mac central for unpair control event")
        }
    }

    private fun publishEncryptedPayloadToMac(
        plaintext: ByteArray,
        key: SecretKey,
        payloadType: String
    ): Boolean {
        if (!gattServer.hasConnectedCentral()) {
            return false
        }

        val encrypted = try {
            E2ECrypto.seal(plaintext, key)
        } catch (e: Exception) {
            Log.e(TAG, "Encryption failed: ${e.message}")
            return false
        }

        val txId = UUID.randomUUID().toString().lowercase()
        val totalChunks = ChunkTransfer.totalChunks(encrypted.size)
        val dataFrames = ArrayList<ByteArray>(totalChunks + 1)
        dataFrames.add(
            ChunkTransfer.header(
                txId = txId,
                totalChunks = totalChunks,
                totalBytes = encrypted.size,
                encoding = "utf-8"
            )
        )

        repeat(totalChunks) { index ->
            dataFrames.add(ChunkTransfer.chunk(encrypted, index))
        }

        val availablePayload = JSONObject()
            .put("hash", sha256Hex(encrypted))
            .put("size", encrypted.size)
            .put("type", payloadType)
            .put("tx_id", txId)
            .toString()
            .toByteArray(Charsets.UTF_8)

        return gattServer.publishClipboardFrames(availablePayload, dataFrames)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }

    private fun sendClipboardTransferBroadcast(fromMac: Boolean) {
        val intent = Intent(ACTION_CLIPBOARD_TRANSFER)
        intent.setPackage(packageName)
        intent.putExtra(EXTRA_FROM_MAC, fromMac)
        sendBroadcast(intent)
    }

    private fun sendConnectionBroadcast(connected: Boolean, deviceName: String? = null) {
        val intent = Intent(ACTION_CONNECTION_STATE)
        intent.setPackage(packageName)
        intent.putExtra(EXTRA_CONNECTED, connected)
        if (deviceName != null) intent.putExtra(EXTRA_DEVICE_NAME, deviceName)
        sendBroadcast(intent)
    }

    private fun saveConnectedDeviceName(name: String?) {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        prefs.edit().apply {
            if (name != null) putString(KEY_CONNECTED_DEVICE, name) else remove(KEY_CONNECTED_DEVICE)
            apply()
        }
    }

    private fun loadConnectedDeviceName(): String? =
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(KEY_CONNECTED_DEVICE, null)

    private fun scheduleStaleConnectionCheck() {
        staleConnectionHandler.postDelayed(object : Runnable {
            override fun run() {
                if (isDestroyed) return
                if (bleStarted) {
                    val reaped = gattCallback.reapStaleConnections(STALE_CONNECTION_TIMEOUT_SECONDS)
                    if (reaped) {
                        Log.d(TAG, "Reaped stale BLE connections")
                    }
                }
                staleConnectionHandler.postDelayed(this, STALE_CONNECTION_CHECK_INTERVAL_MS)
            }
        }, STALE_CONNECTION_CHECK_INTERVAL_MS)
    }

    private fun buildNotification(): Notification {
        val channelId = "cliprelay-service"
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            channelId,
            getString(R.string.service_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)

        return NotificationCompat.Builder(this, channelId)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.service_notification_text))
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }
}
