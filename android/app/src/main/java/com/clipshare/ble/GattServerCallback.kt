package com.clipshare.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import java.util.UUID

class GattServerCallback(
    private val onAvailableReceived: (ByteArray) -> Unit,
    private val onDataReceived: (ByteArray) -> Unit,
    private val onDeviceConnectionChanged: (Boolean) -> Unit
) : BluetoothGattServerCallback() {
    companion object {
        private val CCC_DESCRIPTOR_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    var server: BluetoothGattServer? = null
    private val connectedDevices = linkedSetOf<BluetoothDevice>()

    fun connectedDevicesSnapshot(): List<BluetoothDevice> = synchronized(connectedDevices) {
        connectedDevices.toList()
    }

    override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
        if (device == null) {
            return
        }

        synchronized(connectedDevices) {
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                connectedDevices.add(device)
            } else {
                connectedDevices.remove(device)
            }
            onDeviceConnectionChanged(connectedDevices.isNotEmpty())
        }
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
        if (characteristic.uuid == GattServerManager.AVAILABLE_UUID) {
            onAvailableReceived(value)
        }
        if (characteristic.uuid == GattServerManager.DATA_UUID) {
            onDataReceived(value)
        }
        if (responseNeeded) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
        }
    }

    override fun onCharacteristicReadRequest(
        device: BluetoothDevice,
        requestId: Int,
        offset: Int,
        characteristic: BluetoothGattCharacteristic
    ) {
        val value = characteristic.value ?: byteArrayOf()
        if (offset > value.size) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
            return
        }

        val sliced = if (offset == 0) value else value.copyOfRange(offset, value.size)
        server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, sliced)
    }

    override fun onDescriptorReadRequest(
        device: BluetoothDevice,
        requestId: Int,
        offset: Int,
        descriptor: BluetoothGattDescriptor
    ) {
        val value = descriptor.value ?: BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        if (offset > value.size) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
            return
        }

        val sliced = if (offset == 0) value else value.copyOfRange(offset, value.size)
        server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, sliced)
    }

    override fun onDescriptorWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        descriptor: BluetoothGattDescriptor,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray
    ) {
        if (descriptor.uuid == CCC_DESCRIPTOR_UUID) {
            descriptor.value = value
        }

        if (responseNeeded) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
        }
    }
}
