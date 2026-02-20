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

        // Scan response: device tag as manufacturer data + device name.
        // Manufacturer data: 2 (company ID) + 8 (tag) = 10 bytes + overhead ~12 bytes.
        // Device name: up to ~17 chars. Both fit in 31 bytes.
        val scanResponseBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
        val tag = deviceTag
        if (tag != null) {
            // 0xFFFF = Bluetooth SIG reserved for testing/development
            scanResponseBuilder.addManufacturerData(0xFFFF, tag)
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
