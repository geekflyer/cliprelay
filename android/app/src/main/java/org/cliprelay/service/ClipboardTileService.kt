package org.cliprelay.service

// Quick Settings tile that sends the current clipboard to the paired Mac.
// Tapping the tile launches ClipboardGhostActivity to read the clipboard.

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import org.cliprelay.R
import org.cliprelay.pairing.PairingStore

class ClipboardTileService : TileService() {

    companion object {
        private const val TAG = "ClipboardTile"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()

        val pairingStore = PairingStore(this)
        if (pairingStore.loadSharedSecret() == null) {
            Log.d(TAG, "Not paired — ignoring tile tap")
            return
        }

        Log.d(TAG, "Tile tapped — launching send activity")

        val sendIntent = Intent(this, ClipboardSendActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_NO_ANIMATION or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
        }
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            val pendingIntent = android.app.PendingIntent.getActivity(
                this, 0, sendIntent,
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(sendIntent)
        }
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        val pairingStore = PairingStore(this)
        val isPaired = pairingStore.loadSharedSecret() != null

        if (isPaired) {
            val deviceName = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
                .getString(ClipRelayService.KEY_CONNECTED_DEVICE, null)
            tile.label = getString(R.string.tile_label)
            tile.subtitle = deviceName
            tile.state = Tile.STATE_INACTIVE
        } else {
            tile.label = getString(R.string.tile_label)
            tile.subtitle = getString(R.string.tile_not_paired)
            tile.state = Tile.STATE_UNAVAILABLE
        }

        tile.updateTile()
    }
}
