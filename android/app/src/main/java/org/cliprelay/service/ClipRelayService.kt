package org.cliprelay.service

// Foreground service that orchestrates BLE advertising, L2CAP connections, and clipboard sync.

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import org.cliprelay.R
import org.cliprelay.ble.Advertiser
import org.cliprelay.ble.L2capServer
import org.cliprelay.ble.L2capServerCallback
import org.cliprelay.crypto.E2ECrypto
import org.cliprelay.debug.DebugSmokeProbe
import org.cliprelay.permissions.BlePermissions
import org.cliprelay.pairing.PairingStore
import org.cliprelay.protocol.ProtocolException
import org.cliprelay.protocol.Session
import org.cliprelay.protocol.SessionCallback
import org.cliprelay.protocol.SessionMode
import org.cliprelay.protocol.VersionMismatchException
import org.cliprelay.settings.ClipboardSettingsStore
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors

class ClipRelayService : Service(), L2capServerCallback, SessionCallback {
    companion object {
        const val ACTION_PUSH_TEXT = "org.cliprelay.action.PUSH_TEXT"
        const val ACTION_RELOAD_PAIRING = "org.cliprelay.action.RELOAD_PAIRING"
        const val ACTION_UNPAIR = "org.cliprelay.action.UNPAIR"
        const val ACTION_START_PAIRING = "org.cliprelay.action.START_PAIRING"
        const val ACTION_CONNECTION_STATE = "org.cliprelay.action.CONNECTION_STATE"
        const val ACTION_QUERY_CONNECTION = "org.cliprelay.action.QUERY_CONNECTION"
        const val ACTION_CLIPBOARD_TRANSFER = "org.cliprelay.action.CLIPBOARD_TRANSFER"
        const val ACTION_PAIRING_COMPLETE = "org.cliprelay.action.PAIRING_COMPLETE"
        const val EXTRA_TEXT = "extra_text"
        const val EXTRA_CONNECTED = "extra_connected"
        const val EXTRA_DEVICE_NAME = "extra_device_name"
        const val EXTRA_DEVICE_TAG = "extra_device_tag"
        const val EXTRA_FROM_MAC = "extra_from_mac"

        const val ACTION_VERSION_MISMATCH = "org.cliprelay.action.VERSION_MISMATCH"
        const val ACTION_GHOST_FINISHED = "org.cliprelay.action.GHOST_FINISHED"
        const val ACTION_ACCESSIBILITY_COPY_DETECTED = "org.cliprelay.action.ACCESSIBILITY_COPY_DETECTED"
        const val ACTION_SEND_CONFIG_UPDATE = "org.cliprelay.action.SEND_CONFIG_UPDATE"
        const val ACTION_PUSH_IMAGE = "org.cliprelay.action.PUSH_IMAGE"
        const val EXTRA_IMAGE_PATH = "extra_image_path"
        const val EXTRA_MIME_TYPE = "extra_mime_type"
        const val ACTION_RICH_MEDIA_SETTING_CHANGED = "org.cliprelay.action.RICH_MEDIA_SETTING_CHANGED"
        const val EXTRA_RICH_MEDIA_ENABLED = "extra_rich_media_enabled"

        const val PREFS_NAME = "cliprelay_state"
        const val KEY_CONNECTED_DEVICE = "connected_device_name"

        private const val TAG = "ClipRelayService"
        private const val MAX_CLIPBOARD_BYTES = 102_400
        private const val CLIPBOARD_DEBOUNCE_MS = 200L
    }

    // BLE components
    private var advertiser: Advertiser? = null
    private var l2capServer: L2capServer? = null

    // Active L2CAP session (at most one)
    @Volatile
    private var activeSession: Session? = null
    private var sessionThread: Thread? = null

    // Pairing state
    private val isPaired: Boolean get() = pairingStore.loadSharedSecret() != null
    @Volatile
    private var lastInboundHash: String? = null
    @Volatile
    private var lastSentTextHash: String? = null
    @Volatile
    private var lastReceivedImageHash: String? = null

    // Support
    private lateinit var clipboardWriter: ClipboardWriter
    private lateinit var clipboardSettingsStore: ClipboardSettingsStore
    private lateinit var pairingStore: PairingStore
    private val executor = Executors.newSingleThreadExecutor()
    private val clipboardAutoClearHandler = Handler(Looper.getMainLooper())
    private var pendingClipboardAutoClear: Runnable? = null

    @Volatile
    private var bleStarted = false
    @Volatile
    private var isDestroyed = false
    @Volatile
    private var pairingInProgress = false
    private var pendingPairingKeyPair: java.security.KeyPair? = null
    private var pendingMacPublicKeyRaw: ByteArray? = null

    // Auto-copy state (guards for ghost activity launches)
    @Volatile
    private var lastClipboardLaunchMs = 0L
    @Volatile
    private var ghostActivityInFlight = false

    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> {
                    Log.w(TAG, "Bluetooth enabled — ensuring BLE components are running")
                    ensureBleComponentsState(restartIfRunning = true)
                    sendConnectionBroadcast(false)
                }
                BluetoothAdapter.STATE_OFF -> {
                    Log.w(TAG, "Bluetooth disabled — stopping BLE components")
                    stopBleComponents()
                }
            }
        }
    }

    // ── Lifecycle ──────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        clipboardWriter = ClipboardWriter(this)
        clipboardSettingsStore = ClipboardSettingsStore(this)
        pairingStore = PairingStore(this)

        loadPairingState()
        DebugSmokeProbe.reset(this)

        startForeground(1001, buildNotification())
        ContextCompat.registerReceiver(
            this,
            bluetoothStateReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        ensureBleComponentsState()

        // Publish direct share shortcut if already paired
        if (isPaired) {
            publishDirectShareShortcut(loadConnectedDeviceName())
        }
    }

    override fun onDestroy() {
        isDestroyed = true
        clipboardAutoClearHandler.removeCallbacksAndMessages(null)
        unregisterReceiver(bluetoothStateReceiver)
        executor.shutdownNow()
        stopBleComponents()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        loadPairingState()

        when (intent?.action) {
            ACTION_UNPAIR -> {
                handleUnpairRequest()
                return START_STICKY
            }
            ACTION_START_PAIRING -> {
                handleStartPairing()
                return START_STICKY
            }
            ACTION_RELOAD_PAIRING -> {
                // RELOAD_PAIRING handles its own BLE lifecycle — skip the
                // general ensureBleComponentsState() to avoid a double-start.
                if (!isPaired) {
                    if (bleStarted) {
                        stopBleComponents()
                    }
                    sendConnectionBroadcast(false)
                } else if (BlePermissions.hasRequiredRuntimePermissions(this)) {
                    if (bleStarted) {
                        stopBleComponents(broadcastDisconnected = false)
                    }
                    ensureBleComponentsState()
                } else {
                    Log.w(TAG, "BLE runtime permissions missing; stopping BLE components")
                    stopBleComponents()
                }
                return START_STICKY
            }
            ACTION_GHOST_FINISHED -> {
                clearGhostActivityInFlight()
                return START_STICKY
            }
            ACTION_ACCESSIBILITY_COPY_DETECTED -> {
                handleClipboardChanged()
                return START_STICKY
            }
            ACTION_SEND_CONFIG_UPDATE -> {
                activeSession?.sendConfigUpdate()
                return START_STICKY
            }
            ACTION_PUSH_IMAGE -> {
                val imagePath = intent.getStringExtra(EXTRA_IMAGE_PATH)
                val mimeType = intent.getStringExtra(EXTRA_MIME_TYPE) ?: "image/png"
                if (imagePath != null) {
                    executor.execute {
                        pushImageToMac(imagePath, mimeType)
                    }
                }
            }
            ACTION_PUSH_TEXT -> {
                clearGhostActivityInFlight()
                val text = intent.getStringExtra(EXTRA_TEXT)
                if (!text.isNullOrBlank()) {
                    executor.execute {
                        pushPlainTextToMac(text)
                    }
                }
            }
            ACTION_QUERY_CONNECTION -> {
                val connected = activeSession != null
                val name = if (connected) loadConnectedDeviceName() else null
                sendConnectionBroadcast(connected, name)
            }
        }

        ensureBleComponentsState()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── BLE stack management ──────────────────────────────────────────

    private fun ensureBleComponentsState(restartIfRunning: Boolean = false) {
        if (!isPaired && !pairingInProgress) {
            if (bleStarted) {
                Log.w(TAG, "Shared secret missing; stopping BLE components")
                stopBleComponents()
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

        startBle()
    }

    private fun startBle() {
        Log.w(TAG, "startBle() — isPaired=$isPaired")
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        if (adapter == null) {
            Log.e(TAG, "BluetoothAdapter unavailable")
            sendConnectionBroadcast(false)
            return
        }

        val serviceUUID = java.util.UUID.fromString("c10b0001-1234-5678-9abc-def012345678")

        val started = runCatching {
            // 1. Start L2CAP server, get PSM
            val l2cap = L2capServer(adapter, this)
            val psm = l2cap.start()
            l2capServer = l2cap
            Log.w(TAG, "L2CAP server started on PSM $psm")

            // 2. Start advertising with PSM embedded in manufacturer data
            //    (No GATT server needed — Mac reads PSM from scan response)
            val adv = Advertiser(this, ParcelUuid(serviceUUID))
            adv.psm = psm
            adv.deviceTag = if (pairingInProgress) {
                pendingMacPublicKeyRaw?.let { macPub ->
                    java.security.MessageDigest.getInstance("SHA-256")
                        .digest(macPub)
                        .copyOfRange(0, 8)
                }
            } else {
                pairingStore.loadSharedSecret()?.let { secret ->
                    E2ECrypto.deviceTag(E2ECrypto.hexToBytes(secret))
                }
            }
            adv.start()
            advertiser = adv
            Log.w(TAG, "BLE advertising started (psm=$psm, deviceTag=${advertiser?.deviceTag?.let { it.joinToString("") { b -> "%02x".format(b) } } ?: "null"})")

            true
        }.getOrElse { error ->
            bleStarted = false
            advertiser?.stop()
            advertiser = null
            l2capServer?.stop()
            l2capServer = null
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

    private fun stopBleComponents(broadcastDisconnected: Boolean = true) {
        // Tear down active session
        activeSession?.close()
        sessionThread?.let { thread ->
            try { thread.join(2000) } catch (_: InterruptedException) {}
        }
        activeSession = null
        sessionThread = null

        // Stop BLE stack
        advertiser?.stop()
        advertiser = null
        l2capServer?.stop()
        l2capServer = null

        bleStarted = false
        if (broadcastDisconnected) {
            sendConnectionBroadcast(false)
        }
    }

    private fun loadPairingState() {
        val secret = pairingStore.loadSharedSecret()
        if (secret != null) {
            val secretBytes = E2ECrypto.hexToBytes(secret)
            advertiser?.deviceTag = E2ECrypto.deviceTag(secretBytes)
        } else {
            advertiser?.deviceTag = null
            saveConnectedDeviceName(null)
        }
    }

    // ── L2capServerCallback ───────────────────────────────────────────

    override fun onClientConnected(socket: BluetoothSocket) {
        Log.w(TAG, "L2CAP client connected")

        // Tear down previous session
        activeSession?.close()
        sessionThread?.let { thread ->
            try { thread.join(2000) } catch (_: InterruptedException) {}
        }

        // Determine session mode
        val mode = if (pairingInProgress) {
            val keyPair = pendingPairingKeyPair ?: run {
                Log.e(TAG, "Pairing in progress but no key pair available")
                return
            }
            val macPub = pendingMacPublicKeyRaw ?: run {
                Log.e(TAG, "Pairing in progress but no Mac public key available")
                return
            }
            SessionMode.Pairing(
                ownPrivateKey = keyPair.private,
                ownPublicKeyRaw = E2ECrypto.x25519PublicKeyToRaw(keyPair.public),
                remotePublicKeyRaw = macPub
            )
        } else {
            SessionMode.Normal
        }

        // Create new session (Android is the responder)
        val secret = if (pairingInProgress) null else pairingStore.loadSharedSecret()
        val session = Session(
            socket.inputStream, socket.outputStream,
            isInitiator = false,
            this,  // SessionCallback
            mode = mode,
            sharedSecretHex = secret,
            settingsProvider = pairingStore
        )
        session.localName = android.os.Build.MODEL
        activeSession = session

        sessionThread = Thread({
            session.performHandshake()
            session.listenForMessages()
        }, "L2CAP-Session").apply {
            isDaemon = true
            start()
        }
    }

    override fun onAcceptError(error: IOException) {
        Log.e(TAG, "L2CAP accept error: ${error.message}")
        // The L2CAP server loop has exited. If we're still alive, restart.
        if (!isDestroyed && bleStarted) {
            Handler(Looper.getMainLooper()).post {
                if (!isDestroyed && bleStarted) {
                    Log.d(TAG, "Restarting BLE stack after L2CAP accept error")
                    stopBleComponents(broadcastDisconnected = false)
                    ensureBleComponentsState()
                }
            }
        }
    }

    // ── SessionCallback ───────────────────────────────────────────────

    override fun onSessionReady() {
        Log.w(TAG, "L2CAP session ready")

        // If the advertiser's device tag was updated during pairing (without a
        // restart), restart it now so future reconnections use the correct tag.
        // The HELLO/WELCOME handshake is complete, so it's safe to cycle BLE
        // advertising without risking the active L2CAP connection.
        advertiser?.restart()

        // The HELLO/WELCOME handshake carries the remote device name. Persist
        // it so the UI always shows the real hostname (e.g. "Christian's Mac")
        // instead of null — during pairing, KEY_CONFIRM doesn't include a name
        // so this is the first point where the Mac's name is available.
        activeSession?.remoteName?.let {
            saveConnectedDeviceName(it)
            publishDirectShareShortcut(it)
        }

        val name = loadConnectedDeviceName()
        sendConnectionBroadcast(true, name)
        DebugSmokeProbe.onConnectionChanged(this, true)
    }

    override fun onClipboardReceived(plaintext: ByteArray, hash: String) {
        val decodedText = plaintext.toString(Charsets.UTF_8)
        if (decodedText.isEmpty()) return

        lastInboundHash = hash
        clipboardWriter.writeText(decodedText)
        scheduleClipboardAutoClear(decodedText)
        sendClipboardTransferBroadcast(fromMac = true)
        DebugSmokeProbe.onInboundClipboardApplied(this, decodedText)
    }

    override fun onTransferComplete(hash: String) {
        Log.d(TAG, "Outbound transfer complete: $hash")
        sendClipboardTransferBroadcast(fromMac = false)
    }

    override fun onSessionError(error: Exception) {
        Log.e(TAG, "Session error: ${error.message}")
        activeSession = null
        sessionThread = null
        sendConnectionBroadcast(false)
        DebugSmokeProbe.onConnectionChanged(this, false)

        if (error is VersionMismatchException) {
            val intent = Intent(ACTION_VERSION_MISMATCH)
            intent.setPackage(packageName)
            sendBroadcast(intent)
        }
        // L2CAP server is still listening, will accept next connection
    }

    override fun hasHash(hash: String): Boolean {
        return hash == lastInboundHash
    }

    override fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?) {
        val secretHex = sharedSecret.joinToString("") { "%02x".format(it) }
        Log.w(TAG, "ECDH pairing complete, storing shared secret")

        // Store the shared secret
        pairingStore.saveSharedSecret(secretHex)

        // Update the device tag for future advertisements, but do NOT restart
        // advertising now — the HELLO/WELCOME handshake is still in progress on
        // this same L2CAP connection.  Restarting BLE advertising mid-handshake
        // can disrupt the active connection on some Android devices.  The
        // advertiser will be restarted in onSessionReady() once the full
        // handshake completes.
        advertiser?.deviceTag = E2ECrypto.deviceTag(sharedSecret)

        // Clear pairing state
        pairingInProgress = false
        pendingPairingKeyPair = null
        pendingMacPublicKeyRaw = null

        // Clean up temporary prefs
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).edit()
            .remove("pending_pairing_pubkey")
            .apply()

        // Save device name
        if (remoteName != null) {
            saveConnectedDeviceName(remoteName)
        }

        // Broadcast pairing complete with device tag for UI
        val deviceTagHex = E2ECrypto.deviceTag(sharedSecret).take(4)
            .joinToString("") { "%02X".format(it) }
            .chunked(4).joinToString(" ")
        val pairingIntent = Intent(ACTION_PAIRING_COMPLETE)
        pairingIntent.setPackage(packageName)
        pairingIntent.putExtra(EXTRA_DEVICE_TAG, deviceTagHex)
        pairingIntent.putExtra(EXTRA_DEVICE_NAME, remoteName)
        sendBroadcast(pairingIntent)
        publishDirectShareShortcut(remoteName)
    }

    override fun onRichMediaSettingChanged(enabled: Boolean) {
        val intent = Intent(ACTION_RICH_MEDIA_SETTING_CHANGED)
        intent.setPackage(packageName)
        intent.putExtra(EXTRA_RICH_MEDIA_ENABLED, enabled)
        sendBroadcast(intent)
    }

    override fun onImageSendFailed(reason: String) {
        Log.w(TAG, "Image send failed: $reason")
        Handler(Looper.getMainLooper()).post {
            android.widget.Toast.makeText(
                this,
                "Could not transfer image. Make sure both devices are on the same Wi-Fi network.",
                android.widget.Toast.LENGTH_LONG
            ).show()
        }
    }

    override fun onImageReceived(data: ByteArray, contentType: String, hash: String) {
        lastReceivedImageHash = hash
        Log.w(TAG, "Received image from Mac (${data.size} bytes, $contentType)")
        clipboardWriter.writeImage(data, contentType)
        sendClipboardTransferBroadcast(fromMac = true)
    }

    override fun isDeviceAwake(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val km = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        return pm.isInteractive && !km.isDeviceLocked
    }

    // ── Outbound (Android → Mac) ─────────────────────────────────────

    private fun pushPlainTextToMac(text: String) {
        if (isDestroyed) return
        val plaintext = text.toByteArray(Charsets.UTF_8)
        if (plaintext.isEmpty() || plaintext.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        // Dedup: skip if we already sent this exact text
        val textHash = MessageDigest.getInstance("SHA-256")
            .digest(plaintext).joinToString("") { "%02x".format(it) }
        if (textHash == lastSentTextHash) {
            Log.d(TAG, "Skipping send — same text already sent")
            return
        }
        lastSentTextHash = textHash

        val session = activeSession
        if (session == null) {
            Log.d(TAG, "No active L2CAP session; skipping Android->Mac push")
            return
        }

        session.sendClipboard(plaintext)
        DebugSmokeProbe.onOutboundClipboardPublished(this, text)
    }

    private fun pushImageToMac(imagePath: String, mimeType: String) {
        if (isDestroyed) return
        val file = java.io.File(imagePath)
        if (!file.exists()) {
            Log.e(TAG, "Image file not found: $imagePath")
            return
        }
        val imageData = file.readBytes()
        file.delete() // clean up cache file after reading

        val maxSize = 10_485_760 // 10 MB
        if (imageData.isEmpty() || imageData.size > maxSize) {
            Log.w(TAG, "Image too large or empty: ${imageData.size} bytes")
            Handler(Looper.getMainLooper()).post {
                android.widget.Toast.makeText(this, "Image too large to send (max 10 MB)", android.widget.Toast.LENGTH_SHORT).show()
            }
            return
        }

        val session = activeSession
        if (session == null) {
            Log.w(TAG, "No active session; cannot send image")
            Handler(Looper.getMainLooper()).post {
                android.widget.Toast.makeText(this, "Not connected to Mac", android.widget.Toast.LENGTH_SHORT).show()
            }
            return
        }

        if (!pairingStore.isRichMediaEnabled()) {
            Log.w(TAG, "Rich media not enabled; cannot send image")
            Handler(Looper.getMainLooper()).post {
                android.widget.Toast.makeText(this, "Image sync is not enabled", android.widget.Toast.LENGTH_SHORT).show()
            }
            return
        }

        session.sendImage(imageData, mimeType)
        Log.w(TAG, "Queued image for send (${imageData.size} bytes, $mimeType)")
    }

    // ── Pairing ────────────────────────────────────────────────────────

    private fun handleStartPairing() {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        val macPubKeyHex = prefs.getString("pending_pairing_pubkey", null) ?: return
        val macPubKeyRaw = E2ECrypto.hexToBytes(macPubKeyHex)

        // Generate ephemeral X25519 key pair
        val keyPair = E2ECrypto.generateX25519KeyPair()

        // Store pairing state for session creation
        pendingPairingKeyPair = keyPair
        pendingMacPublicKeyRaw = macPubKeyRaw
        pairingInProgress = true

        Log.w(TAG, "Started pairing mode with pairing tag")

        // Restart BLE components with pairing tag
        if (bleStarted) {
            stopBleComponents(broadcastDisconnected = false)
        }
        ensureBleComponentsState()
    }

    // ── Unpair ────────────────────────────────────────────────────────

    private fun handleUnpairRequest() {
        val hadConnection = bleStarted

        pairingStore.clear()
        clipboardSettingsStore.setAutoCopyOnboardingShown(false)
        clipboardSettingsStore.setAutoCopyEnabled(false)
        removeDirectShareShortcut()
        loadPairingState()

        if (hadConnection) {
            stopBleComponents()
        } else {
            sendConnectionBroadcast(false)
        }
    }

    // ── Clipboard helpers ─────────────────────────────────────────────

    private fun scheduleClipboardAutoClear(inboundText: String) {
        pendingClipboardAutoClear?.let {
            clipboardAutoClearHandler.removeCallbacks(it)
            pendingClipboardAutoClear = null
        }

        if (!clipboardSettingsStore.isAutoClearSyncedClipboardEnabled()) {
            return
        }

        val clearRunnable = Runnable {
            pendingClipboardAutoClear = null
            if (!clipboardSettingsStore.isAutoClearSyncedClipboardEnabled()) {
                return@Runnable
            }
            clipboardWriter.clearClipIfMatches(inboundText)
        }
        pendingClipboardAutoClear = clearRunnable
        clipboardAutoClearHandler.postDelayed(clearRunnable, ClipboardSettingsStore.AUTO_CLEAR_DELAY_MS)
    }

    // ── Auto-copy (triggered by AccessibilityService) ────────────────

    private fun handleClipboardChanged() {
        Log.d(TAG, "Clipboard changed — activeSession=${activeSession != null}, ghostInFlight=$ghostActivityInFlight")

        // Skip if no active session (no Mac connected)
        if (activeSession == null) {
            Log.d(TAG, "Skipping clipboard: no active session")
            return
        }

        // 200ms time guard to prevent double-fires from text classification
        val now = System.currentTimeMillis()
        if (now - lastClipboardLaunchMs < CLIPBOARD_DEBOUNCE_MS) {
            Log.d(TAG, "Skipping clipboard: debounce (${now - lastClipboardLaunchMs}ms)")
            return
        }
        lastClipboardLaunchMs = now

        // Skip if ghost activity is already in flight
        if (ghostActivityInFlight) {
            Log.d(TAG, "Skipping clipboard: ghost activity in flight")
            return
        }

        // Always launch ghost activity — even when the app is "foreground" per
        // ProcessLifecycleOwner, a Service cannot read the clipboard on Android 10+.
        // Only an Activity with window focus can call getPrimaryClip() successfully.
        Log.d(TAG, "Launching ghost activity for clipboard read")
        ghostActivityInFlight = true
        val ghostIntent = Intent(this, ClipboardGhostActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
        }
        startActivity(ghostIntent)
    }

    fun clearGhostActivityInFlight() {
        ghostActivityInFlight = false
    }

    // ── Direct Share shortcut ─────────────────────────────────────────

    private fun publishDirectShareShortcut(deviceName: String?) {
        val label = deviceName ?: "Mac"
        val shortcut = ShortcutInfoCompat.Builder(this, "send_to_mac")
            .setShortLabel(label)
            .setIcon(IconCompat.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(Intent(Intent.ACTION_SEND).apply {
                setClass(this@ClipRelayService, org.cliprelay.ui.ShareReceiverActivity::class.java)
                type = "*/*"
                putExtra(Intent.EXTRA_TEXT, "")
            })
            .setCategories(setOf("org.cliprelay.category.SEND_TO_MAC"))
            .setLongLived(true)
            .build()

        ShortcutManagerCompat.addDynamicShortcuts(this, listOf(shortcut))
        Log.d(TAG, "Published direct share shortcut: $label")
    }

    private fun removeDirectShareShortcut() {
        ShortcutManagerCompat.removeDynamicShortcuts(this, listOf("send_to_mac"))
        Log.d(TAG, "Removed direct share shortcut")
    }

    // ── Broadcasts ────────────────────────────────────────────────────

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

    // ── Preferences ───────────────────────────────────────────────────

    private fun saveConnectedDeviceName(name: String?) {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        prefs.edit().apply {
            if (name != null) putString(KEY_CONNECTED_DEVICE, name) else remove(KEY_CONNECTED_DEVICE)
            apply()
        }
    }

    private fun loadConnectedDeviceName(): String? =
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(KEY_CONNECTED_DEVICE, null)

    // ── Notification ──────────────────────────────────────────────────

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
