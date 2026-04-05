package org.cliprelay.ui

// Animated Compose component: celebratory particle burst shown after successful pairing.

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class RingAnim(
    val radius: Animatable<Float, *>,
    val alpha: Animatable<Float, *>
)

@Composable
fun PairingBurst(onBurstShown: () -> Unit) {
    val flashAlpha = remember { Animatable(0f) }
    val checkScale = remember { Animatable(0f) }

    val rings = remember {
        List(4) {
            RingAnim(
                radius = Animatable(0f),
                alpha = Animatable(1f)
            )
        }
    }

    LaunchedEffect(Unit) {
        // Flash
        launch {
            flashAlpha.animateTo(0.80f, tween(150))
            flashAlpha.animateTo(0f, tween(600))
        }

        // Rings with staggered starts (180ms apart)
        rings.forEachIndexed { i, ring ->
            launch {
                delay(i * 180L)
                launch {
                    ring.radius.animateTo(550f, tween(2200))
                }
                ring.alpha.animateTo(0f, tween(2200))
            }
        }

        // Checkmark springs in after 120ms
        launch {
            delay(120)
            checkScale.animateTo(
                1f,
                spring(
                    stiffness = 200f,
                    dampingRatio = Spring.DampingRatioMediumBouncy
                )
            )
        }

        // Notify ViewModel that burst was shown after 800ms
        delay(800)
        onBurstShown()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Flash overlay
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Aqua.copy(alpha = flashAlpha.value))
        )

        // Expanding rings
        Canvas(modifier = Modifier.fillMaxSize()) {
            val center = Offset(size.width / 2f, size.height / 2f)
            val ringColor = Aqua
            rings.forEach { ring ->
                if (ring.alpha.value > 0.01f && ring.radius.value > 0f) {
                    drawCircle(
                        color = ringColor.copy(alpha = ring.alpha.value * 0.6f),
                        radius = ring.radius.value.dp.toPx(),
                        center = center,
                        style = Stroke(width = 2.dp.toPx())
                    )
                }
            }
        }

        // Checkmark
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .scale(checkScale.value)
                    .size(72.dp)
                    .clip(CircleShape)
                    .background(Color.White),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = Icons.Filled.Check,
                    contentDescription = null,
                    tint = Teal,
                    modifier = Modifier
                        .size(40.dp)
                        .padding(4.dp)
                )
            }
        }
    }
}
