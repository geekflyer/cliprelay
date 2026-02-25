package com.cliprelay.ble

class BleConnectionStateMachine {
    private val connectedDeviceIds = linkedSetOf<String>()

    fun onConnectionChanged(deviceId: String, isConnected: Boolean): Boolean {
        return synchronized(connectedDeviceIds) {
            if (isConnected) {
                connectedDeviceIds.add(deviceId)
            } else {
                connectedDeviceIds.remove(deviceId)
            }
            connectedDeviceIds.isNotEmpty()
        }
    }

    fun snapshot(): Set<String> = synchronized(connectedDeviceIds) {
        connectedDeviceIds.toSet()
    }

    fun clear() = synchronized(connectedDeviceIds) {
        connectedDeviceIds.clear()
    }
}
