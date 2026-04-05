package org.cliprelay.permissions

import android.Manifest
import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Test

class BlePermissionsTest {
    @Test
    fun sdkBelowS_hasNoRuntimeBlePermissions() {
        assertEquals(emptyList<String>(), BlePermissions.requiredRuntimePermissions(Build.VERSION_CODES.R))
    }

    @Test
    fun sdkSAndAbove_requiresScanConnectAndAdvertise() {
        val expected = listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )

        assertEquals(expected, BlePermissions.requiredRuntimePermissions(Build.VERSION_CODES.S))
        assertEquals(expected, BlePermissions.requiredRuntimePermissions(Build.VERSION_CODES.UPSIDE_DOWN_CAKE))
    }
}
