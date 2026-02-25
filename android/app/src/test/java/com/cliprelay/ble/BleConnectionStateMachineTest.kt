package com.cliprelay.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BleConnectionStateMachineTest {
    @Test
    fun disconnectReconnectCycle_releasesConnectionSlot() {
        val machine = BleConnectionStateMachine()

        assertTrue(machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = true))
        assertTrue(machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = true))
        assertEquals(setOf("AA:BB:CC:DD:EE:01"), machine.snapshot())

        assertFalse(machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = false))
        assertEquals(emptySet<String>(), machine.snapshot())

        assertTrue(machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = true))
        assertEquals(setOf("AA:BB:CC:DD:EE:01"), machine.snapshot())
    }

    @Test
    fun clear_removesAllTrackedDevices() {
        val machine = BleConnectionStateMachine()
        machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = true)
        machine.onConnectionChanged("AA:BB:CC:DD:EE:02", isConnected = true)

        machine.clear()

        assertEquals(emptySet<String>(), machine.snapshot())
    }

    @Test
    fun freshMachine_hasNoConnectedDevices() {
        val machine = BleConnectionStateMachine()

        assertTrue(machine.snapshot().isEmpty())
        assertFalse(machine.onConnectionChanged("AA:BB:CC:DD:EE:01", isConnected = false))
        assertTrue(machine.snapshot().isEmpty())
    }
}
