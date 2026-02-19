package com.clipshare.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.util.Base64
import android.util.Log
import android.os.IBinder
import android.os.ParcelUuid
import androidx.core.app.NotificationCompat
import com.clipshare.R
import com.clipshare.ble.Advertiser
import com.clipshare.ble.ChunkTransfer
import com.clipshare.ble.GattServerCallback
import com.clipshare.ble.GattServerManager
import com.clipshare.crypto.E2ECrypto
import com.clipshare.pairing.PairingStore
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors

class ClipShareService : Service() {
    companion object {
        const val ACTION_PUSH_TEXT = "com.clipshare.action.PUSH_TEXT"
        const val EXTRA_TEXT = "extra_text"
        private const val TAG = "ClipShareService"
        private const val MAX_CLIPBOARD_BYTES = 102_400
    }

    private lateinit var gattServer: GattServerManager
    private lateinit var advertiser: Advertiser
    private lateinit var clipboardWriter: ClipboardWriter
    private lateinit var pairingStore: PairingStore
    private val secureRandom = SecureRandom()
    private val transferExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        clipboardWriter = ClipboardWriter(this)
        pairingStore = PairingStore(this)
        gattServer = GattServerManager(
            this,
            GattServerCallback(
                onPushReceived = { bytes ->
                    val text = bytes.toString(Charsets.UTF_8)
                    clipboardWriter.writeText(text)
                },
                onDeviceConnectionChanged = {}
            )
        )
        advertiser = Advertiser(ParcelUuid(GattServerManager.SERVICE_UUID))
        startForeground(1001, buildNotification())
        gattServer.start()
        advertiser.start()
    }

    override fun onDestroy() {
        advertiser.stop()
        gattServer.stop()
        transferExecutor.shutdown()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PUSH_TEXT) {
            val text = intent.getStringExtra(EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                transferExecutor.execute {
                    pushEncryptedTextToMac(text)
                }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun pushEncryptedTextToMac(text: String) {
        val plaintext = text.toByteArray(Charsets.UTF_8)
        if (plaintext.isEmpty() || plaintext.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        if (!gattServer.hasConnectedCentral()) {
            Log.d(TAG, "No connected Mac central; skipping Android->Mac push")
            return
        }

        val key = E2ECrypto.deriveAesKey(pairingStore.encryptionSeed())
        val nonce = ByteArray(12)
        secureRandom.nextBytes(nonce)

        val encrypted = E2ECrypto.encrypt(plaintext, key, nonce)
        val encryptedEnvelope = JSONObject()
            .put("algorithm", "aes-256-gcm")
            .put("nonce", Base64.encodeToString(nonce, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .toString()
            .toByteArray(Charsets.UTF_8)

        val totalChunks = ChunkTransfer.totalChunks(encryptedEnvelope.size)
        val dataFrames = ArrayList<ByteArray>(totalChunks + 1)
        dataFrames.add(
            ChunkTransfer.header(
                totalChunks = totalChunks,
                totalBytes = encryptedEnvelope.size,
                encoding = "aes-gcm-json"
            )
        )

        repeat(totalChunks) { index ->
            dataFrames.add(ChunkTransfer.chunk(encryptedEnvelope, index))
        }

        val availablePayload = JSONObject()
            .put("hash", sha256Hex(plaintext))
            .put("size", plaintext.size)
            .put("type", "text/plain")
            .toString()
            .toByteArray(Charsets.UTF_8)

        gattServer.publishClipboardFrames(availablePayload, dataFrames)
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }

    private fun buildNotification(): Notification {
        val channelId = "clipshare-service"
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
