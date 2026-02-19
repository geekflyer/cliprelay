package com.clipshare.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.ParcelUuid

class Advertiser(private val serviceUuid: ParcelUuid) {
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
        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)

        val data = dataBuilder.build()
        callback = object : AdvertiseCallback() {}
        instance.startAdvertising(settings, data, callback)
    }

    fun stop() {
        val instance = advertiser ?: return
        callback?.let { instance.stopAdvertising(it) }
        callback = null
    }
}
