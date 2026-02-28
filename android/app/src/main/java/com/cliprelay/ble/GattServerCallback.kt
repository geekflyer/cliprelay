package com.cliprelay.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.util.Log
import java.util.UUID
import java.util.concurrent.Semaphore

class GattServerCallback(
    private val onAvailableReceived: (deviceId: String, payload: ByteArray) -> Unit,
    private val onDataReceived: (deviceId: String, payload: ByteArray) -> Unit,
    private val onDeviceConnectionChanged: (
        deviceId: String,
        isConnected: Boolean,
        hasConnectedDevices: Boolean
    ) -> Unit
) : BluetoothGattServerCallback() {


    @Volatile var server: BluetoothGattServer? = null
    val notificationSent = Semaphore(0)
    @Volatile var lastNotificationStatus: Int = BluetoothGatt.GATT_SUCCESS
    private val connectedDevicesById = linkedMapOf<String, BluetoothDevice>()
    private val lastActivityByDeviceId = linkedMapOf<String, Long>()
    private val connectionStateMachine = BleConnectionStateMachine()

    private fun deviceIdFor(device: BluetoothDevice): String {
        return device.address ?: device.toString()
    }

    fun connectedDevicesSnapshot(): List<BluetoothDevice> = synchronized(connectedDevicesById) {
        connectedDevicesById.values.toList()
    }

    fun clearConnectedDevices() = synchronized(connectedDevicesById) {
        connectedDevicesById.clear()
        lastActivityByDeviceId.clear()
        connectionStateMachine.clear()
    }

    override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
        if (device == null) {
            return
        }

        val deviceId = deviceIdFor(device)
        val isConnected = newState == BluetoothGatt.STATE_CONNECTED

        synchronized(connectedDevicesById) {
            if (isConnected) {
                connectedDevicesById[deviceId] = device
                lastActivityByDeviceId[deviceId] = System.currentTimeMillis()
            } else {
                connectedDevicesById.remove(deviceId)
                lastActivityByDeviceId.remove(deviceId)
            }
            val hasConnectedDevices = connectionStateMachine.onConnectionChanged(deviceId, isConnected)
            onDeviceConnectionChanged(deviceId, isConnected, hasConnectedDevices)
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
        val deviceId = deviceIdFor(device)
        synchronized(connectedDevicesById) {
            lastActivityByDeviceId[deviceId] = System.currentTimeMillis()
        }
        if (characteristic.uuid == GattServerManager.AVAILABLE_UUID) {
            onAvailableReceived(deviceId, value)
        }
        if (characteristic.uuid == GattServerManager.DATA_UUID) {
            onDataReceived(deviceId, value)
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
        val deviceId = deviceIdFor(device)
        synchronized(connectedDevicesById) {
            lastActivityByDeviceId[deviceId] = System.currentTimeMillis()
        }
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

    override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
        lastNotificationStatus = status
        notificationSent.release()
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
        if (descriptor.uuid == GattServerManager.CCC_DESCRIPTOR_UUID) {
            descriptor.value = value
        }

        if (responseNeeded) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
        }
    }

    /**
     * Remove devices that have had no GATT activity (reads/writes) for [timeoutSeconds].
     * Returns true if any stale devices were reaped.
     */
    fun reapStaleConnections(timeoutSeconds: Int): Boolean {
        val cutoff = System.currentTimeMillis() - timeoutSeconds * 1000L
        val staleEntries = mutableListOf<Pair<String, BluetoothDevice>>()

        synchronized(connectedDevicesById) {
            val iter = connectedDevicesById.entries.iterator()
            while (iter.hasNext()) {
                val (deviceId, device) = iter.next()
                val lastActivity = lastActivityByDeviceId[deviceId] ?: 0L
                if (lastActivity < cutoff) {
                    staleEntries.add(deviceId to device)
                    iter.remove()
                    lastActivityByDeviceId.remove(deviceId)
                }
            }
        }

        for ((deviceId, _) in staleEntries) {
            Log.d("GattServerCallback", "Reaping stale connection: $deviceId")
            val hasConnectedDevices = synchronized(connectedDevicesById) {
                connectionStateMachine.onConnectionChanged(deviceId, false)
            }
            onDeviceConnectionChanged(deviceId, false, hasConnectedDevices)
        }

        return staleEntries.isNotEmpty()
    }
}
