package com.clipshare.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import com.clipshare.R
import com.clipshare.ble.Advertiser
import com.clipshare.ble.AssembledPayload
import com.clipshare.ble.ChunkReassembler
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
        const val ACTION_REFRESH_PAIRING = "com.clipshare.action.REFRESH_PAIRING"
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
    private val incomingPushReassembler = ChunkReassembler()

    @Volatile
    private var activeSeed: ByteArray = byteArrayOf()

    @Volatile
    private var lastInboundHash: String? = null

    @Volatile
    private var pendingInboundHashFromMetadata: String? = null

    override fun onCreate() {
        super.onCreate()

        clipboardWriter = ClipboardWriter(this)
        pairingStore = PairingStore(this)
        activeSeed = pairingStore.encryptionSeed()

        gattServer = GattServerManager(
            this,
            GattServerCallback(
                onAvailableReceived = { bytes ->
                    transferExecutor.execute {
                        handleAvailableMetadata(bytes)
                    }
                },
                onPushReceived = { bytes ->
                    transferExecutor.execute {
                        handleIncomingPushFrame(bytes)
                    }
                },
                onDeviceConnectionChanged = {}
            )
        )

        advertiser = Advertiser(ParcelUuid(GattServerManager.SERVICE_UUID))

        startForeground(1001, buildNotification())
        gattServer.start()
        advertiser.start(pairingStore.pairingTokenForAdvertising())
    }

    override fun onDestroy() {
        advertiser.stop()
        gattServer.stop()
        transferExecutor.shutdown()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PUSH_TEXT -> {
                val text = intent.getStringExtra(EXTRA_TEXT)
                if (!text.isNullOrBlank()) {
                    transferExecutor.execute {
                        pushEncryptedTextToMac(text)
                    }
                }
            }

            ACTION_REFRESH_PAIRING -> {
                refreshPairingContext()
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refreshPairingContext() {
        activeSeed = pairingStore.encryptionSeed()
        advertiser.start(pairingStore.pairingTokenForAdvertising())
    }

    private fun handleIncomingPushFrame(frame: ByteArray) {
        val assembled = incomingPushReassembler.consumeFrame(frame) ?: return
        val decodedText = decodeIncomingPayload(assembled) ?: return
        val decodedBytes = decodedText.toByteArray(Charsets.UTF_8)
        if (decodedBytes.isEmpty() || decodedBytes.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        val hash = sha256Hex(decodedBytes)
        if (hash == lastInboundHash) {
            return
        }

        val metadataHash = pendingInboundHashFromMetadata
        if (!metadataHash.isNullOrBlank() && metadataHash != hash) {
            pendingInboundHashFromMetadata = null
            return
        }

        pendingInboundHashFromMetadata = null
        lastInboundHash = hash
        clipboardWriter.writeText(decodedText)
    }

    private fun handleAvailableMetadata(metadata: ByteArray) {
        val json = runCatching {
            JSONObject(metadata.toString(Charsets.UTF_8))
        }.getOrNull() ?: return

        val hash = json.optString("hash")
        if (hash.isNotBlank()) {
            pendingInboundHashFromMetadata = hash
        }
    }

    private fun decodeIncomingPayload(payload: AssembledPayload): String? {
        if (payload.encoding != "aes-gcm-json") {
            return payload.bytes.toString(Charsets.UTF_8)
        }

        val envelope = runCatching {
            JSONObject(payload.bytes.toString(Charsets.UTF_8))
        }.getOrNull() ?: return null

        val nonce = decodeBase64(envelope.optString("nonce")) ?: return null
        val ciphertext = decodeBase64(envelope.optString("ciphertext")) ?: return null
        val session = decodeBase64(envelope.optString("session"))

        val key = if (session == null || session.isEmpty()) {
            E2ECrypto.deriveAesKey(activeSeed)
        } else {
            E2ECrypto.deriveSessionKey(activeSeed, session)
        }

        val plaintext = runCatching {
            E2ECrypto.decrypt(ciphertext, key, nonce)
        }.getOrNull() ?: return null

        return plaintext.toString(Charsets.UTF_8)
    }

    private fun pushEncryptedTextToMac(text: String) {
        val plaintext = text.toByteArray(Charsets.UTF_8)
        if (plaintext.isEmpty() || plaintext.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        if (!gattServer.hasConnectedCentral()) {
            Log.d(TAG, "No connected Mac central; skipping Android->Mac push")
            return
        }

        val sessionNonce = ByteArray(16)
        secureRandom.nextBytes(sessionNonce)

        val nonce = ByteArray(12)
        secureRandom.nextBytes(nonce)

        val sessionKey = E2ECrypto.deriveSessionKey(activeSeed, sessionNonce)
        val encrypted = E2ECrypto.encrypt(plaintext, sessionKey, nonce)

        val encryptedEnvelope = JSONObject()
            .put("algorithm", "aes-256-gcm")
            .put("session", Base64.encodeToString(sessionNonce, Base64.NO_WRAP))
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

        val published = gattServer.publishClipboardFrames(availablePayload, dataFrames)
        if (!published) {
            Log.d(TAG, "No subscribers for Android->Mac push")
        }
    }

    private fun decodeBase64(value: String?): ByteArray? {
        if (value.isNullOrBlank()) {
            return null
        }

        val normalized = value.replace(' ', '+')
        val flags = listOf(
            Base64.NO_WRAP,
            Base64.DEFAULT,
            Base64.URL_SAFE or Base64.NO_WRAP,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )

        flags.forEach { flag ->
            val decoded = runCatching { Base64.decode(normalized, flag) }.getOrNull()
            if (decoded != null) {
                return decoded
            }
        }

        return null
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
