package org.cliprelay.ble

// Manages BLE advertising with automatic retry and periodic restart to survive Android power management.

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
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
    private var includeDeviceName = true
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

        // Primary advertisement: service UUID only (for central scan filtering).
        // Must stay under 31 bytes: 3 (flags) + 18 (128-bit UUID) = 21 bytes.
        val advertiseData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)
            .build()

        // Scan response: device tag + PSM as manufacturer data, plus device name.
        // Manufacturer data: 2 (company ID) + 8 (tag) + 2 (PSM) = 12 bytes + overhead ~12 bytes.
        // Device name: up to ~15 chars. Prefer to include the real device name when
        // it fits; otherwise truncate the UTF-8 bytes and embed the truncated name
        // into the manufacturer payload so the receiver can still see a short name.
        val scanResponseBuilder = AdvertiseData.Builder()
        var nameBytesToEmbed: ByteArray? = null
        var effectiveIncludeDeviceName = includeDeviceName
        if (effectiveIncludeDeviceName) {
            val adapterName = try {
                btManager.adapter.name
            } catch (e: SecurityException) {
                Log.e(TAG, "Permission denied while getting adapter name", e)
                null
            }
            if (!adapterName.isNullOrEmpty()) {
                val nameBytes = adapterName.toByteArray(Charsets.UTF_8)
                val deviceNameByteLimit = 15
                val truncatedNameByteLimit = 10
                if (nameBytes.size > deviceNameByteLimit) {
                    // Too long to include as the local name field; instead embed a
                    // truncated UTF-8 prefix in manufacturer data and disable the
                    // system device name to avoid payload-too-large errors.
                    effectiveIncludeDeviceName = false
                    // Truncate by bytes; this may cut a UTF-8 sequence, but it's
                    // acceptable for a short display name.
                    nameBytesToEmbed = nameBytes.copyOfRange(0, truncatedNameByteLimit)
                    Log.w(
                        TAG,
                        "Device name (${nameBytes.size} bytes) truncated to ${nameBytesToEmbed.size} bytes for advertisement"
                    )
                }
            }
        }
        scanResponseBuilder.setIncludeDeviceName(effectiveIncludeDeviceName)
        val tag = deviceTag
        if (tag != null) {
            // Pack: [device_tag: N bytes][psm: 2 bytes big-endian][optional truncated name]
            val nameLen = nameBytesToEmbed?.size ?: 0
            val payload = ByteArray(tag.size + 2 + nameLen)
            var offset = 0
            System.arraycopy(tag, 0, payload, offset, tag.size)
            offset += tag.size
            payload[offset] = (psm shr 8).toByte()
            offset += 1
            payload[offset] = (psm and 0xFF).toByte()
            offset += 1
            if (nameLen > 0) {
                nameBytesToEmbed?.copyInto(payload, destinationOffset = offset, startIndex = 0, endIndex = nameLen)
            }
            // 0xFFFF = Bluetooth SIG reserved for testing/development
            scanResponseBuilder.addManufacturerData(0xFFFF, payload)
        }
        val scanResponse = scanResponseBuilder.build()

        val advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                retryAttempt = 0
                Log.w(TAG, "BLE advertise started")
            }

            override fun onStartFailure(errorCode: Int) {
                callback = null
                if (!shouldAdvertise) return

                if (
                    errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE &&
                        includeDeviceName
                ) {
                    includeDeviceName = false
                    retryAttempt = 0
                    Log.w(TAG, "BLE advertise payload too large; retrying without device name")
                } else {
                    Log.e(TAG, "BLE advertise start failed: $errorCode")
                }
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
        includeDeviceName = true
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
     * Used by the periodic health check to recover from silently killed ads.
     */
    private fun cycleAdvertisement() {
        stopAdvertisingInternal()
        retryAttempt = 0
        startInternal()
    }

    private fun stopAdvertisingInternal() {
        val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val instance = btManager?.adapter?.bluetoothLeAdvertiser
        try {
            callback?.let { instance?.stopAdvertising(it) }
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE stopAdvertising threw SecurityException", e)
        }
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
