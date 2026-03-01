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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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

    val badgeBorderAlpha by transition.animateFloat(
        initialValue = 0.25f,
        targetValue = 0.45f,
        animationSpec = infiniteRepeatable(tween(2500), RepeatMode.Reverse),
        label = "badgeBorder"
    )

    val textMeasurer = rememberTextMeasurer()

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

        // ── Encryption pill badge at beam center ──
        val badgeLabel = textMeasurer.measure(
            "E2EE",
            TextStyle(
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp
            )
        )

        val lockIconSize = 10f.dp.toPx()
        val iconTextGap = 3f.dp.toPx()
        val badgePadH = 8f.dp.toPx()
        val badgePadV = 4f.dp.toPx()

        val contentWidth = lockIconSize + iconTextGap + badgeLabel.size.width
        val badgeW = contentWidth + badgePadH * 2
        val badgeH = maxOf(badgeLabel.size.height.toFloat(), lockIconSize) + badgePadV * 2
        val badgeL = (size.width - badgeW) / 2f
        val badgeT = cy - badgeH / 2f
        val cornerR = CornerRadius(badgeH / 2f)

        // Subtle glow behind badge
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(neonGreen.copy(alpha = 0.12f), Color.Transparent),
                center = Offset(size.width / 2f, cy),
                radius = badgeH * 1.5f
            ),
            radius = badgeH * 1.5f,
            center = Offset(size.width / 2f, cy)
        )

        // Badge background
        drawRoundRect(Color.White, Offset(badgeL, badgeT), Size(badgeW, badgeH), cornerR)

        // Badge border (pulsing)
        drawRoundRect(
            neonGreen.copy(alpha = badgeBorderAlpha),
            Offset(badgeL, badgeT), Size(badgeW, badgeH), cornerR,
            style = Stroke(1f.dp.toPx())
        )

        // Lock icon (left side of badge)
        val lockL = badgeL + badgePadH
        val lockT = cy - lockIconSize / 2f
        val lockColor = darkGreen

        // Lock body
        val lBodyW = lockIconSize * 0.72f
        val lBodyH = lockIconSize * 0.45f
        val lBodyTop = lockT + lockIconSize * 0.50f
        drawRoundRect(
            color = lockColor,
            topLeft = Offset(lockL + (lockIconSize - lBodyW) / 2f, lBodyTop),
            size = Size(lBodyW, lBodyH),
            cornerRadius = CornerRadius(lockIconSize * 0.08f)
        )

        // Lock shackle arc
        val sW = lockIconSize * 0.46f
        val sH = lockIconSize * 0.34f
        val shackleStrokeW = lockIconSize * 0.12f
        drawArc(
            color = lockColor,
            startAngle = 180f,
            sweepAngle = 180f,
            useCenter = false,
            topLeft = Offset(lockL + (lockIconSize - sW) / 2f, lBodyTop - sH),
            size = Size(sW, sH),
            style = Stroke(shackleStrokeW, cap = StrokeCap.Round)
        )

        // Lock shackle legs
        val legX1 = lockL + (lockIconSize - sW) / 2f
        val legX2 = lockL + (lockIconSize + sW) / 2f
        val shackleLegTop = lBodyTop - sH / 2f
        drawLine(lockColor, Offset(legX1, shackleLegTop), Offset(legX1, lBodyTop), shackleStrokeW)
        drawLine(lockColor, Offset(legX2, shackleLegTop), Offset(legX2, lBodyTop), shackleStrokeW)

        // "E2EE" text
        drawText(
            badgeLabel,
            color = darkGreen,
            topLeft = Offset(
                lockL + lockIconSize + iconTextGap,
                cy - badgeLabel.size.height / 2f
            )
        )

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
