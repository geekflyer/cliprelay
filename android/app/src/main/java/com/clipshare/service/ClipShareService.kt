package com.clipshare.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.ParcelUuid
import androidx.core.app.NotificationCompat
import com.clipshare.R
import com.clipshare.ble.Advertiser
import com.clipshare.ble.GattServerCallback
import com.clipshare.ble.GattServerManager

class ClipShareService : Service() {
    companion object {
        const val ACTION_PUSH_TEXT = "com.clipshare.action.PUSH_TEXT"
        const val EXTRA_TEXT = "extra_text"
    }

    private lateinit var gattServer: GattServerManager
    private lateinit var advertiser: Advertiser
    private lateinit var clipboardWriter: ClipboardWriter

    override fun onCreate() {
        super.onCreate()
        clipboardWriter = ClipboardWriter(this)
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
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PUSH_TEXT) {
            val text = intent.getStringExtra(EXTRA_TEXT)
            if (!text.isNullOrBlank()) {
                // TODO: route through encrypted chunk transfer to connected Mac central.
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

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
