package org.cliprelay.permissions

// Resolves which BLE runtime permissions are required on the current Android SDK version.

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

object BlePermissions {
    fun requiredRuntimePermissions(sdkInt: Int = Build.VERSION.SDK_INT): List<String> {
        if (sdkInt < Build.VERSION_CODES.S) return emptyList()
        return listOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE
        )
    }

    fun hasRequiredRuntimePermissions(context: Context, sdkInt: Int = Build.VERSION.SDK_INT): Boolean {
        val required = requiredRuntimePermissions(sdkInt)
        if (required.isEmpty()) return true
        return required.all { permission ->
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        }
    }
}
