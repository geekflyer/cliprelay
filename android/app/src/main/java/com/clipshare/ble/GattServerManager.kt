package com.clipshare.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.content.Context
import java.util.UUID

class GattServerManager(
    private val context: Context,
    private val callback: GattServerCallback
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("c10b0001-1234-5678-9abc-def012345678")
        val AVAILABLE_UUID: UUID = UUID.fromString("c10b0002-1234-5678-9abc-def012345678")
        val DATA_UUID: UUID = UUID.fromString("c10b0003-1234-5678-9abc-def012345678")
        val PUSH_UUID: UUID = UUID.fromString("c10b0004-1234-5678-9abc-def012345678")
        val INFO_UUID: UUID = UUID.fromString("c10b0005-1234-5678-9abc-def012345678")
    }

    private var server: BluetoothGattServer? = null

    fun start() {
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        server = bluetoothManager.openGattServer(context, callback)

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val available = BluetoothGattCharacteristic(
            AVAILABLE_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        val data = BluetoothGattCharacteristic(
            DATA_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        val push = BluetoothGattCharacteristic(
            PUSH_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val info = BluetoothGattCharacteristic(
            INFO_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        service.addCharacteristic(available)
        service.addCharacteristic(data)
        service.addCharacteristic(push)
        service.addCharacteristic(info)
        server?.addService(service)
    }

    fun stop() {
        server?.close()
        server = null
    }
}
