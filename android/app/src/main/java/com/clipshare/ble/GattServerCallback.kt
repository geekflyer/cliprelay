package com.clipshare.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback

class GattServerCallback(
    private val onPushReceived: (ByteArray) -> Unit,
    private val onDeviceConnectionChanged: (Boolean) -> Unit
) : BluetoothGattServerCallback() {

    override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
        onDeviceConnectionChanged(newState == BluetoothGatt.STATE_CONNECTED)
    }

    override fun onCharacteristicWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        characteristic: BluetoothGattCharacteristic,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray
    ) {
        onPushReceived(value)
    }

    override fun onCharacteristicReadRequest(
        device: BluetoothDevice,
        requestId: Int,
        offset: Int,
        characteristic: BluetoothGattCharacteristic
    ) {
    }
}
