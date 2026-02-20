package com.clipshare.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.ParcelUuid
import android.util.Log

class Advertiser(private val serviceUuid: ParcelUuid) {
    companion object {
        private const val TAG = "Advertiser"
    }

    private val advertiser: BluetoothLeAdvertiser? = BluetoothAdapter.getDefaultAdapter()?.bluetoothLeAdvertiser
    private var callback: AdvertiseCallback? = null

    var deviceTag: ByteArray? = null

    fun start() {
        val instance = advertiser ?: return
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

        // Scan response: device tag as service data for paired device recognition.
        // 128-bit UUID service data with 8-byte tag = ~26 bytes, fits in 31.
        val scanResponseBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
        val tag = deviceTag
        if (tag != null) {
            scanResponseBuilder.addServiceData(serviceUuid, tag)
        }
        val scanResponse = scanResponseBuilder.build()

        callback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "BLE advertise start failed: $errorCode")
            }
        }
        instance.startAdvertising(settings, advertiseData, scanResponse, callback)
    }

    fun stop() {
        val instance = advertiser ?: return
        callback?.let { instance.stopAdvertising(it) }
        callback = null
    }

    fun restart() {
        stop()
        start()
    }
}
