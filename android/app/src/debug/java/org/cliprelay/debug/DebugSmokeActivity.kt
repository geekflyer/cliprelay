package org.cliprelay.debug

import android.app.Activity
import android.os.Bundle
import android.util.Log

class DebugSmokeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i("DebugSmokeActivity", "Handling action=${intent?.action}")
        val result = DebugSmokeCommands.handle(this, intent)
        Log.i("DebugSmokeActivity", "Handled action=${intent?.action} result=$result")
        finish()
        Log.i("DebugSmokeActivity", "Finish requested")
    }
}
