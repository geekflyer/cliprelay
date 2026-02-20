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

        val advertiseDataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)

        val tag = deviceTag
        if (tag != null) {
            advertiseDataBuilder.addServiceData(serviceUuid, tag)
        }

        val advertiseData = advertiseDataBuilder.build()

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

    fun restart() {
        stop()
        start()
    }
}
