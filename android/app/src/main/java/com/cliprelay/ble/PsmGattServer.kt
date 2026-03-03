package com.cliprelay.ble

// GATT server that advertises the L2CAP PSM so the Mac can discover which channel to connect on.

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class PsmGattServer(
    private val context: Context,
    private val bluetoothManager: BluetoothManager,
    private val psm: Int
) {
    companion object {
        private const val TAG = "PsmGattServer"
        // Same service UUID as the existing BLE service (for advertisement matching)
        val SERVICE_UUID: UUID = UUID.fromString("c10b0001-1234-5678-9abc-def012345678")
        // New characteristic UUID for PSM (different from old data characteristics)
        val PSM_CHAR_UUID: UUID = UUID.fromString("c10b0010-1234-5678-9abc-def012345678")
    }

    private var gattServer: BluetoothGattServer? = null

    fun start() {
        val serviceAddedLatch = CountDownLatch(1)

        val callback = object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "GATT service registered successfully")
                } else {
                    Log.e(TAG, "GATT service registration failed with status $status")
                }
                serviceAddedLatch.countDown()
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                Log.w(TAG, "PSM read request from ${device.address}")
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

        // Wait for the service to be fully registered before returning.
        // Without this, service discovery from the central may fail.
        if (!serviceAddedLatch.await(3, TimeUnit.SECONDS)) {
            Log.e(TAG, "Timed out waiting for GATT service registration")
        }
    }

    fun stop() {
        gattServer?.clearServices()
        gattServer?.close()
        gattServer = null
    }
}
