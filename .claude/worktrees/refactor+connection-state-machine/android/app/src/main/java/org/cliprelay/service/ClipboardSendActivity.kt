package org.cliprelay.service

// Visible clipboard-send activity launched from the Quick Settings tile.
// Shows a brief translucent overlay with a send animation while reading
// and forwarding the clipboard. Unlike ClipboardGhostActivity, this is
// meant to be seen by the user as confirmation.

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.cliprelay.ui.Aqua
import org.cliprelay.ui.Teal

class ClipboardSendActivity : ComponentActivity() {

    companion object {
        private const val TAG = "ClipboardSend"
    }

    private val safetyHandler = Handler(Looper.getMainLooper())
    private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        safetyHandler.postDelayed({
            if (!finished) finishSend()
        }, 2000L)

        val deviceName = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
            .getString(ClipRelayService.KEY_CONNECTED_DEVICE, null) ?: "Mac"

        setContent {
            SendOverlay(deviceName = deviceName, onAnimationEnd = { finishSend() })
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || finished) return

        window.decorView.post {
            if (finished) return@post
            readClipboardAndForward()
        }
    }

    private fun readClipboardAndForward() {
        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        if (clipboardManager == null) {
            Log.w(TAG, "ClipboardManager unavailable")
            return
        }

        val clip = try {
            clipboardManager.primaryClip
        } catch (e: SecurityException) {
            Log.w(TAG, "Clipboard access denied: ${e.message}")
            return
        }
        if (clip == null || clip.itemCount == 0) return

        val text = clip.getItemAt(0).coerceToText(this)?.toString()
        if (text.isNullOrBlank()) return

        val pushIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_PUSH_TEXT
            putExtra(ClipRelayService.EXTRA_TEXT, text)
        }
        startService(pushIntent)
        Log.d(TAG, "Forwarded clipboard text to service (${text.length} chars)")
    }

    private fun finishSend() {
        if (finished) return
        finished = true
        safetyHandler.removeCallbacksAndMessages(null)
        finish()
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun onDestroy() {
        safetyHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}

@Composable
private fun SendOverlay(deviceName: String, onAnimationEnd: () -> Unit) {
    val scale = remember { Animatable(0.8f) }
    val alpha = remember { Animatable(0f) }

    LaunchedEffect(Unit) {
        // Fade in and scale up
        alpha.animateTo(1f, tween(150))
        scale.animateTo(1f, tween(200))
        // Hold briefly
        kotlinx.coroutines.delay(600)
        // Fade out
        alpha.animateTo(0f, tween(300))
        onAnimationEnd()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0x66000000))
            .alpha(alpha.value),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .scale(scale.value)
                .clip(RoundedCornerShape(24.dp))
                .background(Color(0xF0FFFFFF))
                .size(180.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "✓",
                fontSize = 40.sp,
                fontWeight = FontWeight.Bold,
                color = Aqua
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Sending clipboard to",
                fontSize = 14.sp,
                color = Color(0x99000000)
            )
            Text(
                text = deviceName,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = Teal
            )
        }
    }
}
