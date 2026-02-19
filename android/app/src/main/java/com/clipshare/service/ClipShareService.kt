package com.clipshare.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.NotificationCompat
import com.clipshare.R
import com.clipshare.ble.Advertiser
import com.clipshare.ble.AssembledPayload
import com.clipshare.ble.ChunkReassembler
import com.clipshare.ble.ChunkTransfer
import com.clipshare.ble.GattServerCallback
import com.clipshare.ble.GattServerManager
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
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

    private val transferExecutor = Executors.newSingleThreadExecutor()
    private val incomingDataReassembler = ChunkReassembler()

    @Volatile
    private var lastInboundHash: String? = null

    @Volatile
    private var pendingInboundHashFromMetadata: String? = null

    override fun onCreate() {
        super.onCreate()

        clipboardWriter = ClipboardWriter(this)

        gattServer = GattServerManager(
            this,
            GattServerCallback(
                onAvailableReceived = { bytes ->
                    transferExecutor.execute {
                        handleAvailableMetadata(bytes)
                    }
                },
                onDataReceived = { bytes ->
                    transferExecutor.execute {
                        handleIncomingDataFrame(bytes)
                    }
                },
                onDeviceConnectionChanged = { isConnected ->
                    if (!isConnected) {
                        transferExecutor.execute {
                            incomingDataReassembler.reset()
                            pendingInboundHashFromMetadata = null
                        }
                    }
                }
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
                    pushPlainTextToMac(text)
                }
            }
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun handleIncomingDataFrame(frame: ByteArray) {
        val assembled = incomingDataReassembler.consumeFrame(frame) ?: return
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
        if (payload.encoding != "utf-8") {
            return null
        }
        return payload.bytes.toString(Charsets.UTF_8)
    }

    private fun pushPlainTextToMac(text: String) {
        val plaintext = text.toByteArray(Charsets.UTF_8)
        if (plaintext.isEmpty() || plaintext.size > MAX_CLIPBOARD_BYTES) {
            return
        }

        if (!gattServer.hasConnectedCentral()) {
            Log.d(TAG, "No connected Mac central; skipping Android->Mac push")
            return
        }

        val txId = UUID.randomUUID().toString().lowercase()
        val totalChunks = ChunkTransfer.totalChunks(plaintext.size)
        val dataFrames = ArrayList<ByteArray>(totalChunks + 1)
        dataFrames.add(
            ChunkTransfer.header(
                txId = txId,
                totalChunks = totalChunks,
                totalBytes = plaintext.size,
                encoding = "utf-8"
            )
        )

        repeat(totalChunks) { index ->
            dataFrames.add(ChunkTransfer.chunk(plaintext, index))
        }

        val availablePayload = JSONObject()
            .put("hash", sha256Hex(plaintext))
            .put("size", plaintext.size)
            .put("type", "text/plain")
            .put("tx_id", txId)
            .toString()
            .toByteArray(Charsets.UTF_8)

        val published = gattServer.publishClipboardFrames(availablePayload, dataFrames)
        if (!published) {
            Log.d(TAG, "No subscribers for Android->Mac push")
        }
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
