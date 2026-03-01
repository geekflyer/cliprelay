package com.cliprelay.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import android.os.Build
import android.util.Log
import java.util.UUID
import java.util.concurrent.TimeUnit

class GattServerManager(
    private val context: Context,
    private val callback: GattServerCallback
) {
    companion object {
        private const val TAG = "GattServerManager"
        private const val NOTIFICATION_SEND_TIMEOUT_MS = 500L
        private const val NOTIFICATION_RETRY_LIMIT = 3
        val SERVICE_UUID: UUID = UUID.fromString("c10b0001-1234-5678-9abc-def012345678")
        val AVAILABLE_UUID: UUID = UUID.fromString("c10b0002-1234-5678-9abc-def012345678")
        val DATA_UUID: UUID = UUID.fromString("c10b0003-1234-5678-9abc-def012345678")
        val CCC_DESCRIPTOR_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    @Volatile private var server: BluetoothGattServer? = null
    @Volatile private var availableCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var dataCharacteristic: BluetoothGattCharacteristic? = null

    fun start() {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val gattServer = bluetoothManager.openGattServer(context, callback)
        if (gattServer == null) {
            Log.e(TAG, "openGattServer returned null — Bluetooth adapter may be unavailable")
            throw IllegalStateException("openGattServer returned null — cannot start GATT server")
        }
        server = gattServer
        callback.server = gattServer

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val available = BluetoothGattCharacteristic(
            AVAILABLE_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val data = BluetoothGattCharacteristic(
            DATA_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        available.addDescriptor(
            BluetoothGattDescriptor(
                CCC_DESCRIPTOR_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE
            )
        )

        data.addDescriptor(
            BluetoothGattDescriptor(
                CCC_DESCRIPTOR_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE
            )
        )

        availableCharacteristic = available
        dataCharacteristic = data

        service.addCharacteristic(available)
        service.addCharacteristic(data)
        server?.addService(service)
    }

    fun hasConnectedCentral(): Boolean {
        return callback.connectedDevicesSnapshot().isNotEmpty()
    }

    fun publishClipboardFrames(
        availablePayload: ByteArray,
        dataFrames: List<ByteArray>
    ): Boolean {
        val server = server ?: return false
        val available = availableCharacteristic ?: return false
        val data = dataCharacteristic ?: return false
        val connectedDevices = callback.connectedDevicesSnapshot()
        if (connectedDevices.isEmpty()) {
            return false
        }

        // Drain any stale permits before starting
        callback.notificationSent.drainPermits()
        callback.lastNotificationStatus = BluetoothGatt.GATT_SUCCESS

        connectedDevices.forEach { device ->
            if (!sendNotificationWithFlowControl(server, device, available, availablePayload)) {
                Log.w(TAG, "Failed to deliver Available metadata to ${device.address}")
                return false
            }
        }

        dataFrames.forEach { frame ->
            connectedDevices.forEach { device ->
                if (!sendNotificationWithFlowControl(server, device, data, frame)) {
                    Log.w(TAG, "Failed to deliver data frame to ${device.address}")
                    return false
                }
            }
        }

        return true
    }

    /**
     * Forcibly disconnect all connected centrals (e.g. after unpair)
     * while keeping the GATT server itself running.
     */
    fun disconnectAllCentrals() {
        val srv = server ?: return
        val devices = callback.connectedDevicesSnapshot()
        for (device in devices) {
            Log.d(TAG, "Forcibly disconnecting central ${device.address}")
            srv.cancelConnection(device)
        }
    }

    fun stop() {
        server?.close()
        callback.server = null
        callback.clearConnectedDevices()
        server = null
        availableCharacteristic = null
        dataCharacteristic = null
    }

    private fun sendNotificationWithFlowControl(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ): Boolean {
        repeat(NOTIFICATION_RETRY_LIMIT) { attempt ->
            val queued = notifyCharacteristicChanged(server, device, characteristic, value)
            if (!queued) {
                Log.w(
                    TAG,
                    "notifyCharacteristicChanged not queued (char=${characteristic.uuid}, attempt=${attempt + 1}/$NOTIFICATION_RETRY_LIMIT)"
                )
                callback.notificationSent.tryAcquire(50, TimeUnit.MILLISECONDS)
                return@repeat
            }

            if (callback.notificationSent.tryAcquire(NOTIFICATION_SEND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                if (callback.lastNotificationStatus == BluetoothGatt.GATT_SUCCESS) {
                    return true
                }
                Log.w(
                    TAG,
                    "onNotificationSent returned failure status=${callback.lastNotificationStatus} (char=${characteristic.uuid}, attempt=${attempt + 1}/$NOTIFICATION_RETRY_LIMIT)"
                )
                return@repeat
            }

            Log.w(
                TAG,
                "onNotificationSent timeout (char=${characteristic.uuid}, attempt=${attempt + 1}/$NOTIFICATION_RETRY_LIMIT)"
            )
        }

        return false
    }

    private fun notifyCharacteristicChanged(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return server.notifyCharacteristicChanged(device, characteristic, false, value) == BluetoothGatt.GATT_SUCCESS
        }

        @Suppress("DEPRECATION")
        return run {
            characteristic.value = value
            server.notifyCharacteristicChanged(device, characteristic, false)
        }
    }
}
