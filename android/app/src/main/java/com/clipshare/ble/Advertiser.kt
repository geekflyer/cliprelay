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
        // Service UUID (128-bit) takes 18 bytes + 3 bytes flags = 21 bytes, well within 31.
        val advertiseData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)
            .build()

        // Scan response: full device name via the standard Local Name AD type.
        // Using setIncludeDeviceName(true) instead of custom service data avoids the
        // 13-byte name limit imposed by 128-bit UUID service data overhead, and uses
        // the same name source that the macOS Bluetooth pairing dialog reads.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()

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
}
