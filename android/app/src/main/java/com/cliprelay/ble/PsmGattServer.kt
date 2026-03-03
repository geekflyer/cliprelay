package com.cliprelay.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

class PsmGattServer(
    private val context: Context,
    private val bluetoothManager: BluetoothManager,
    private val psm: Int
) {
    companion object {
        // Same service UUID as the existing BLE service (for advertisement matching)
        val SERVICE_UUID: UUID = UUID.fromString("c10b0001-1234-5678-9abc-def012345678")
        // New characteristic UUID for PSM (different from old data characteristics)
        val PSM_CHAR_UUID: UUID = UUID.fromString("c10b0010-1234-5678-9abc-def012345678")
    }

    private var gattServer: BluetoothGattServer? = null

    fun start() {
        val callback = object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                if (characteristic.uuid == PSM_CHAR_UUID) {
                    val psmBytes = ByteBuffer.allocate(2)
                        .order(ByteOrder.BIG_ENDIAN)
                        .putShort(psm.toShort())
                        .array()
                    gattServer?.sendResponse(
                        device, requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset, psmBytes
                    )
                } else {
                    gattServer?.sendResponse(
                        device, requestId,
                        BluetoothGatt.GATT_READ_NOT_PERMITTED,
                        0, null
                    )
                }
            }
        }

        val server = bluetoothManager.openGattServer(context, callback)
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val psmChar = BluetoothGattCharacteristic(
            PSM_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        service.addCharacteristic(psmChar)
        server.addService(service)
        gattServer = server
    }

    fun stop() {
        gattServer?.clearServices()
        gattServer?.close()
        gattServer = null
    }
}
