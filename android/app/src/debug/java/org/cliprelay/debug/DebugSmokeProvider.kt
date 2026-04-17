package org.cliprelay.debug

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle

class DebugSmokeProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val context = context ?: return bundleWithResult(3)
        val result = when (method) {
            "import_pairing" -> DebugSmokeCommands.importPairing(
                context,
                arg ?: extras?.getString("token"),
                extras?.getString("device_name")
            )
            "clear_pairing" -> DebugSmokeCommands.clearPairing(context)
            "reset_probe" -> DebugSmokeCommands.resetProbe(context)
            else -> 0
        }
        return bundleWithResult(result)
    }

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0

    private fun bundleWithResult(result: Int): Bundle = Bundle().apply {
        putInt("result", result)
    }
}
