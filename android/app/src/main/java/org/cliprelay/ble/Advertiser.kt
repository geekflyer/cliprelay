package org.cliprelay.ble

// Manages BLE advertising with automatic retry and periodic restart to survive Android power management.

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log

class Advertiser(private val context: Context, private val serviceUuid: ParcelUuid) {
    companion object {
        private const val TAG = "Advertiser"
        private const val RETRY_BASE_DELAY_MS = 1_000L
        private const val RETRY_MAX_DELAY_MS = 30_000L
        // Periodic restart interval: Android can silently kill advertisements
        // (Doze, battery optimization, BLE stack resets) without any callback.
        // Cycling the advertisement every 4 minutes ensures recovery.
        private const val HEALTH_CHECK_INTERVAL_MS = 4 * 60 * 1_000L
    }

    private var callback: AdvertiseCallback? = null
    private var shouldAdvertise = false
    private var retryAttempt = 0
    private val handler = Handler(Looper.getMainLooper())
    private val retryRunnable = Runnable {
        if (shouldAdvertise && callback == null) {
            startInternal()
        }
    }
    private val healthCheckRunnable = Runnable {
        if (shouldAdvertise) {
            Log.d(TAG, "Periodic advertising health-check — cycling advertisement")
            cycleAdvertisement()
            scheduleHealthCheck()
        }
    }

    // Written from session/service threads, read on the main-looper advertising
    // path — @Volatile guarantees the freshly-set tag is visible to the next cycle.
    @Volatile
    var deviceTag: ByteArray? = null
    var psm: Int = 0

    fun start() {
        shouldAdvertise = true
        handler.removeCallbacks(retryRunnable)
        startInternal()
        scheduleHealthCheck()
    }

    private fun startInternal() {
        // Obtain the advertiser reference lazily so it's always current, even after a
        // Bluetooth toggle (the adapter reference captured at construction time goes stale).
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val instance = btManager?.adapter?.bluetoothLeAdvertiser
        if (instance == null) {
            scheduleRetry("advertiser unavailable")
            return
        }
        if (callback != null) {
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        // Primary advertisement: device tag + PSM as manufacturer data.
        // This is deliberately in the PRIMARY advert (ADV_IND), not the scan
        // response: the central receives the primary advert passively, whereas
        // the scan response requires an active SCAN_REQ/SCAN_RSP exchange that
        // some macOS radios drop for tens of seconds under Wi-Fi/BT power-save —
        // which made pairing/reconnect crawl. With the payload here, the central
        // gets everything it needs from the packet it already receives reliably.
        // The macOS central scans broadly (withServices: nil) and matches on this
        // 0xFFFF manufacturer payload, so it no longer needs the service UUID in
        // the primary advert. Budget: 3 (flags) + 14 (mfr data: 2 header + 2
        // company id + 10 payload) = 17 bytes, well under the 31-byte limit.
        val advertiseBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
        val tag = deviceTag
        if (tag != null) {
            // Pack: [device_tag: 8 bytes][psm: 2 bytes big-endian]
            val payload = ByteArray(tag.size + 2)
            System.arraycopy(tag, 0, payload, 0, tag.size)
            payload[tag.size] = (psm shr 8).toByte()
            payload[tag.size + 1] = (psm and 0xFF).toByte()
            // 0xFFFF = Bluetooth SIG reserved for testing/development
            advertiseBuilder.addManufacturerData(0xFFFF, payload)
        }
        val advertiseData = advertiseBuilder.build()

        // Scan response: service UUID. The current macOS central no longer needs
        // it (it matches on the manufacturer payload above), but we keep
        // advertising it for debuggability and any future service-based
        // discovery. We intentionally do NOT include the local device name since
        // scan responses have a strict 31-byte budget and long Bluetooth names
        // can prevent advertising from starting. 128-bit UUID = 18 bytes.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)
            .build()

        val advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                retryAttempt = 0
                val tagHex = deviceTag?.joinToString("") { "%02x".format(it) } ?: "null"
                Log.w(TAG, "BLE advertise started (deviceTag=$tagHex, psm=$psm)")
            }

            override fun onStartFailure(errorCode: Int) {
                callback = null
                if (!shouldAdvertise) return

                Log.e(TAG, "BLE advertise start failed: $errorCode")
                scheduleRetry("start failure: $errorCode")
            }
        }
        callback = advertiseCallback
        try {
            instance.startAdvertising(settings, advertiseData, scanResponse, advertiseCallback)
        } catch (e: SecurityException) {
            callback = null
            Log.e(TAG, "BLE advertise start threw SecurityException", e)
            scheduleRetry("security exception")
        }
    }

    fun stop() {
        shouldAdvertise = false
        retryAttempt = 0
        handler.removeCallbacks(retryRunnable)
        handler.removeCallbacks(healthCheckRunnable)
        stopAdvertisingInternal()
    }

    fun restart() {
        stop()
        start()
    }

    /**
     * Stop and re-start the advertisement without changing [shouldAdvertise].
     * Used by the periodic health-check to recover from silently killed ads.
     */
    private fun cycleAdvertisement() {
        stopAdvertisingInternal()
        retryAttempt = 0
        startInternal()
    }

    private fun stopAdvertisingInternal() {
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val instance = btManager?.adapter?.bluetoothLeAdvertiser
        callback?.let { instance?.stopAdvertising(it) }
        callback = null
    }

    private fun scheduleHealthCheck() {
        handler.removeCallbacks(healthCheckRunnable)
        handler.postDelayed(healthCheckRunnable, HEALTH_CHECK_INTERVAL_MS)
    }

    private fun scheduleRetry(reason: String) {
        if (!shouldAdvertise) return
        val exponential = RETRY_BASE_DELAY_MS shl retryAttempt.coerceAtMost(8)
        val delayMs = exponential.coerceAtMost(RETRY_MAX_DELAY_MS)
        retryAttempt += 1
        handler.removeCallbacks(retryRunnable)
        handler.postDelayed(retryRunnable, delayMs)
        Log.w(TAG, "Scheduling BLE advertise retry in ${delayMs}ms ($reason)")
    }
}
