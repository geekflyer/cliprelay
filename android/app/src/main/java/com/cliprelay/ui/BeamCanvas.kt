package com.cliprelay.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.Flow

@Composable
fun BeamCanvas(
    state: AppState,
    clipboardTransferFlow: Flow<Boolean> = kotlinx.coroutines.flow.emptyFlow(),
    modifier: Modifier = Modifier
) {
    when (state) {
        is AppState.Unpaired -> UnpairedBeam(modifier)
        is AppState.Searching -> SearchingBeam(modifier)
        is AppState.Connected -> ConnectedBeam(clipboardTransferFlow, modifier)
    }
}

@Composable
private fun UnpairedBeam(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        drawLine(
            color = Color(0x33000000),
            start = Offset(0f, size.height / 2f),
            end = Offset(size.width, size.height / 2f),
            strokeWidth = 1.5f.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(
                intervals = floatArrayOf(6f.dp.toPx(), 8f.dp.toPx()),
                phase = 0f
            )
        )
    }
}

@Composable
private fun SearchingBeam(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "search")

    val dashPhase by transition.animateFloat(
        initialValue = 14f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing)),
        label = "dashPhase"
    )

    // Slower: was 2400ms, now 4000ms
    val masterTime by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(4000, easing = LinearEasing)),
        label = "masterTime"
    )

    @Suppress("UNUSED_VARIABLE")
    val labelAlpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.3f,
        animationSpec = infiniteRepeatable(tween(1000), RepeatMode.Reverse),
        label = "labelAlpha"
    )

    Canvas(modifier = modifier) {
        val cy = size.height / 2f
        val dashLen = 6f.dp.toPx()
        val gapLen = 8f.dp.toPx()
        val period = dashLen + gapLen
        val fadeEnd = size.width * 0.55f
        val neonGreen = Aqua
        val darkGreen = Teal

        // Fading dashed line: draw segment by segment up to 55% width
        var xDash = (dashPhase.dp.toPx() % period) - period
        while (xDash < fadeEnd) {
            val x1 = xDash.coerceAtLeast(0f)
            val x2 = (xDash + dashLen).coerceAtMost(fadeEnd)
            if (x2 > x1) {
                val midProgress = ((x1 + x2) / 2f) / fadeEnd
                val alpha = (1f - midProgress).coerceIn(0f, 1f)
                drawLine(
                    color = neonGreen.copy(alpha = 0.35f * alpha),
                    start = Offset(x1, cy),
                    end = Offset(x2, cy),
                    strokeWidth = 1.5f.dp.toPx(),
                    cap = StrokeCap.Round
                )
            }
            xDash += period
        }

        // 3 packets with staggered phases, moving left-to-right
        for (i in 0 until 3) {
            val phase = i / 3f
            val progress = (masterTime + phase) % 1f
            if (progress > 0.75f) continue
            val px = progress / 0.75f * (size.width * 0.75f)
            val alpha = when {
                progress < 0.10f -> progress / 0.10f
                progress > 0.60f -> 1f - (progress - 0.60f) / 0.15f
                else -> 1f
            }.coerceIn(0f, 1f)
            drawCircle(
                color = darkGreen.copy(alpha = alpha),
                radius = 4f.dp.toPx(),
                center = Offset(px, cy)
            )
        }
    }
}

@Composable
private fun ConnectedBeam(
    clipboardTransferFlow: Flow<Boolean>,
    modifier: Modifier = Modifier
) {
    val transition = rememberInfiniteTransition(label = "connected")

    val dashPhaseFwd by transition.animateFloat(
        initialValue = 12f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing)),
        label = "dashFwd"
    )

    val dashPhaseBwd by transition.animateFloat(
        initialValue = 0f,
        targetValue = 12f,
        animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing)),
        label = "dashBwd"
    )

    // Slower: was 1800ms, now 3200ms
    val masterTime by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(3200, easing = LinearEasing)),
        label = "masterTime"
    )

    // Clipboard icon: -1f = inactive, 0..1 = animating
    var clipProgress by remember { mutableStateOf(-1f) }
    var clipGoesRight by remember { mutableStateOf(true) }

    // Trigger animation only on real clipboard transfer events
    LaunchedEffect(clipboardTransferFlow) {
        clipboardTransferFlow.collect { fromMac ->
            // fromMac=true → Mac→Android → right-to-left (bottom track, clipGoesRight=false)
            // fromMac=false → Android→Mac → left-to-right (top track, clipGoesRight=true)
            clipGoesRight = !fromMac
            val startTime = withFrameMillis { it }
            val duration = 1200L
            while (true) {
                val t = withFrameMillis { it }
                val elapsed = t - startTime
                if (elapsed >= duration) break
                clipProgress = elapsed.toFloat() / duration
            }
            clipProgress = -1f
        }
    }

    val clipProgressSnapshot = clipProgress
    val clipRightSnapshot = clipGoesRight

    Canvas(modifier = modifier) {
        val cy = size.height / 2f
        val trackOffset = 8f.dp.toPx()
        val dashLen = 5f.dp.toPx()
        val gapLen = 7f.dp.toPx()
        val neonGreen = Aqua
        val darkGreen = Teal
        val packetRadius = 3.5f.dp.toPx()

        // Top track: left→right
        drawLine(
            color = neonGreen.copy(alpha = 0.45f),
            start = Offset(0f, cy - trackOffset),
            end = Offset(size.width, cy - trackOffset),
            strokeWidth = 1.5f.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(
                intervals = floatArrayOf(dashLen, gapLen),
                phase = dashPhaseFwd.dp.toPx()
            )
        )

        // Bottom track: right→left
        drawLine(
            color = neonGreen.copy(alpha = 0.45f),
            start = Offset(0f, cy + trackOffset),
            end = Offset(size.width, cy + trackOffset),
            strokeWidth = 1.5f.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(
                intervals = floatArrayOf(dashLen, gapLen),
                phase = dashPhaseBwd.dp.toPx()
            )
        )

        // Top track packets (left→right), 2 packets
        for (i in 0 until 2) {
            val phase = i / 2f
            val progress = (masterTime + phase) % 1f
            val alpha = when {
                progress < 0.08f -> progress / 0.08f
                progress > 0.90f -> (1f - progress) / 0.10f
                else -> 1f
            }.coerceIn(0f, 1f)
            drawCircle(
                color = darkGreen.copy(alpha = alpha),
                radius = packetRadius,
                center = Offset(progress * size.width, cy - trackOffset)
            )
        }

        // Bottom track packets (right→left), 2 packets
        for (i in 0 until 2) {
            val phase = i / 2f
            val progress = (masterTime + phase) % 1f
            val alpha = when {
                progress < 0.08f -> progress / 0.08f
                progress > 0.90f -> (1f - progress) / 0.10f
                else -> 1f
            }.coerceIn(0f, 1f)
            drawCircle(
                color = darkGreen.copy(alpha = alpha),
                radius = packetRadius,
                center = Offset((1f - progress) * size.width, cy + trackOffset)
            )
        }

        // Clipboard icon — only visible during an actual transfer event
        if (clipProgressSnapshot >= 0f) {
            val iconSize = 14f.dp.toPx()
            val cx = if (clipRightSnapshot) clipProgressSnapshot * size.width
            else (1f - clipProgressSnapshot) * size.width
            val trackY = if (clipRightSnapshot) cy - trackOffset else cy + trackOffset
            val iconAlpha = when {
                clipProgressSnapshot < 0.1f -> clipProgressSnapshot / 0.1f
                clipProgressSnapshot > 0.85f -> (1f - clipProgressSnapshot) / 0.15f
                else -> 1f
            }.coerceIn(0f, 1f)
            drawRoundRect(
                color = Teal.copy(alpha = iconAlpha),
                topLeft = Offset(cx - iconSize / 2f, trackY - iconSize / 2f),
                size = Size(iconSize, iconSize),
                cornerRadius = CornerRadius(3f.dp.toPx())
            )
            val tabW = iconSize * 0.4f
            val tabH = iconSize * 0.18f
            drawRoundRect(
                color = Teal.copy(alpha = iconAlpha),
                topLeft = Offset(cx - tabW / 2f, trackY - iconSize / 2f - tabH * 0.5f),
                size = Size(tabW, tabH),
                cornerRadius = CornerRadius(2f.dp.toPx())
            )
        }
    }
}
