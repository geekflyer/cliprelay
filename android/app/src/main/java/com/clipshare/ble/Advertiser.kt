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
    private var activeServiceData: ByteArray? = null

    fun start(serviceData: ByteArray? = null) {
        val instance = advertiser ?: return
        if (callback != null && activeServiceData.contentEquals(serviceData)) {
            return
        }
        if (callback != null) {
            stop()
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val dataBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(serviceUuid)

        serviceData?.takeIf { it.isNotEmpty() }?.let {
            dataBuilder.addServiceData(serviceUuid, it)
        }

        val data = dataBuilder.build()
        callback = object : AdvertiseCallback() {}
        instance.startAdvertising(settings, data, callback)
        activeServiceData = serviceData?.copyOf()
    }

    fun stop() {
        val instance = advertiser ?: return
        callback?.let { instance.stopAdvertising(it) }
        callback = null
        activeServiceData = null
    }
}
