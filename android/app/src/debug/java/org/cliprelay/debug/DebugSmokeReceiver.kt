package org.cliprelay.debug

// BroadcastReceiver for smoke-test intents: import/clear pairing secrets and reset the probe.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
class DebugSmokeReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_IMPORT_PAIRING = "org.cliprelay.debug.IMPORT_PAIRING"
        const val ACTION_CLEAR_PAIRING = "org.cliprelay.debug.CLEAR_PAIRING"
        const val ACTION_RESET_PROBE = "org.cliprelay.debug.RESET_PROBE"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        setResultCode(DebugSmokeCommands.handle(context, intent))
    }
}
