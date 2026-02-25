package com.cliprelay.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

// ─── Color constants ─────────────────────────────────────────────────────────
private val NeonGreen = Color(0xFF39FF14)
private val DarkGreen = Color(0xFF2E7D32)
private val TitleGreen = Color(0xFF1B5E20)
private val TextGreen = Color(0xFF1B8A1B)
private val IconGreen = Color(0xFF1B9E1B)

private val BgTopUnpaired = Color(0xFFE8F5E9)
private val BgTopConnected = Color(0xFFD6F5D6)
private val BgBottomUnpaired = Color(0xFFF0F0F0)
private val BgBottomConnected = Color(0xFFF0F7F0)

// ─── Root Screen ─────────────────────────────────────────────────────────────
@Composable
fun ClipRelayScreen(
    state: AppState,
    showBurst: Boolean,
    clipboardTransferFlow: Flow<Boolean> = emptyFlow(),
    onPairClick: () -> Unit,
    onUnpairClick: () -> Unit,
    onBurstShown: () -> Unit,
) {
    val isConnected = state is AppState.Connected
    val isPaired = state !is AppState.Unpaired

    val bgTop by animateColorAsState(
        targetValue = if (isConnected) BgTopConnected else BgTopUnpaired,
        animationSpec = tween(600),
        label = "bgTop"
    )
    val bgBottom by animateColorAsState(
        targetValue = if (isConnected) BgBottomConnected else BgBottomUnpaired,
        animationSpec = tween(600),
        label = "bgBottom"
    )

    // Toast state
    var showToast by remember { mutableStateOf(false) }
    var toastMessage by remember { mutableStateOf("") }

    LaunchedEffect(state) {
        if (state is AppState.Connected) {
            toastMessage = if (state.deviceName != null) "Connected to ${state.deviceName}" else "Connected to Mac"
            showToast = true
            delay(3000)
            showToast = false
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.00f to bgTop,
                        0.60f to Color(0xFFF5F5F5),
                        1.00f to bgBottom
                    )
                )
            )
            .drawBehind {
                // Dot grid
                val dotSpacing = 22.dp.toPx()
                val dotRadius = 1.dp.toPx()
                val dotColor = if (isConnected) Color(0x0F003200) else Color(0x0E000000)
                var x = 0f
                while (x <= size.width) {
                    var y = 0f
                    while (y <= size.height) {
                        drawCircle(dotColor, dotRadius, Offset(x, y))
                        y += dotSpacing
                    }
                    x += dotSpacing
                }
                // Aurora glow
                val auroraColors = if (isConnected) {
                    listOf(Color(0x2E39FF14), Color(0x0F39FF14), Color(0x0539FF14), Color.Transparent)
                } else {
                    listOf(Color(0x1A39FF14), Color(0x0A39FF14), Color(0x0339FF14), Color.Transparent)
                }
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = auroraColors,
                        center = Offset(size.width / 2f, size.height * 0.42f),
                        radius = 180.dp.toPx()
                    ),
                    radius = 180.dp.toPx(),
                    center = Offset(size.width / 2f, size.height * 0.42f)
                )
            }
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(12.dp))
            StatusChip(state = state)
            Spacer(modifier = Modifier.weight(1f))
            MainCard(
                state = state,
                clipboardTransferFlow = clipboardTransferFlow,
                onPairClick = onPairClick,
                onUnpairClick = onUnpairClick
            )
            Spacer(modifier = Modifier.weight(1f))
            FooterSection()
        }

        // Toast (slides in from bottom)
        AnimatedVisibility(
            visible = showToast,
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 80.dp, start = 20.dp, end = 20.dp)
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF323232))
                    .padding(horizontal = 20.dp, vertical = 14.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(NeonGreen)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Text(
                        text = toastMessage,
                        color = Color.White,
                        fontSize = 14.sp
                    )
                }
            }
        }

        // Pairing burst overlay
        AnimatedVisibility(
            visible = showBurst,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(300))
        ) {
            PairingBurst(onBurstShown = onBurstShown)
        }
    }
}

// ─── Status Chip ─────────────────────────────────────────────────────────────
@Composable
private fun StatusChip(state: AppState) {
    val (bgColor, dotColor, textColor, label) = when (state) {
        is AppState.Unpaired -> ChipStyle(
            bg = Color(0x0A000000),
            dot = Color(0x33000000),
            text = Color(0x73000000),
            label = "Not paired"
        )
        is AppState.Searching -> ChipStyle(
            bg = Color(0x1439FF14),
            dot = Color(0xFFBDBDBD),
            text = TextGreen,
            label = "Waiting for Mac"
        )
        is AppState.Connected -> ChipStyle(
            bg = Color(0x1A39FF14),
            dot = NeonGreen,
            text = TextGreen,
            label = "Connected"
        )
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Animated dot for Searching state
        if (state is AppState.Searching) {
            BlinkingDot(color = dotColor)
        } else {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = label,
            color = textColor,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

private data class ChipStyle(
    val bg: Color,
    val dot: Color,
    val text: Color,
    val label: String
)

@Composable
private fun BlinkingDot(color: Color) {
    val alpha = remember { androidx.compose.animation.core.Animatable(1f) }
    LaunchedEffect(Unit) {
        while (true) {
            alpha.animateTo(0.3f, tween(1000))
            alpha.animateTo(1f, tween(1000))
        }
    }
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = alpha.value))
    )
}

// ─── Main Card ───────────────────────────────────────────────────────────────
@Composable
private fun MainCard(
    state: AppState,
    clipboardTransferFlow: Flow<Boolean>,
    onPairClick: () -> Unit,
    onUnpairClick: () -> Unit
) {
    val isPaired = state !is AppState.Unpaired
    val isConnected = state is AppState.Connected

    val cardTopColor by animateColorAsState(
        targetValue = when (state) {
            is AppState.Unpaired -> Color.White
            is AppState.Searching -> Color(0xFFF5FFF5)
            is AppState.Connected -> Color(0xFFF0FFF0)
        },
        animationSpec = tween(600),
        label = "cardTop"
    )

    val borderColor by animateColorAsState(
        targetValue = when (state) {
            is AppState.Unpaired -> Color(0x08000000)
            is AppState.Searching -> Color(0x1F39FF14)
            is AppState.Connected -> Color(0x3339FF14)
        },
        animationSpec = tween(600),
        label = "cardBorder"
    )

    val deviceName = (state as? AppState.Connected)?.deviceName

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .shadow(
                elevation = if (isConnected) 6.dp else 3.dp,
                shape = RoundedCornerShape(28.dp),
                spotColor = if (isConnected) Color(0x1A39FF14) else Color(0x1A000000)
            )
            .clip(RoundedCornerShape(28.dp))
            .background(Brush.verticalGradient(listOf(cardTopColor, Color.White)))
            .border(
                width = if (isPaired) 1.dp else 0.5.dp,
                color = borderColor,
                shape = RoundedCornerShape(28.dp)
            )
            .padding(start = 24.dp, end = 24.dp, top = 36.dp, bottom = 28.dp)
    ) {
        Column {
            // Title
            Text(
                text = "ClipRelay",
                fontSize = 34.sp,
                fontWeight = FontWeight.Bold,
                color = if (isPaired) Color(0xFF0D7D0D) else TitleGreen,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Clipboard sync",
                fontSize = 15.sp,
                color = if (isPaired) Color(0xFF0D7D0D).copy(alpha = 0.45f) else Color(0x66000000),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.height(24.dp))
            HorizontalDivider(
                color = if (isPaired) Color(0x1439FF14) else Color(0x0F000000),
                thickness = 1.dp
            )
            Spacer(modifier = Modifier.height(24.dp))

            // Device row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                DeviceNode(
                    isPhone = true,
                    state = state,
                    label = "This phone"
                )
                BeamCanvas(
                    state = state,
                    clipboardTransferFlow = clipboardTransferFlow,
                    modifier = Modifier
                        .weight(1f)
                        .height(40.dp)
                        .padding(horizontal = 8.dp)
                )
                DeviceNode(
                    isPhone = false,
                    state = state,
                    label = deviceName ?: "MacBook"
                )
            }

            Spacer(modifier = Modifier.height(28.dp))

            // Action button
            if (!isPaired) {
                Button(
                    onClick = onPairClick,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(28.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = DarkGreen
                    )
                ) {
                    Text(
                        text = "Pair with Mac",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(vertical = 4.dp)
                    )
                }
            } else {
                TextButton(
                    onClick = onUnpairClick,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(28.dp),
                    colors = ButtonDefaults.textButtonColors(
                        contentColor = Color(0x73000000)
                    )
                ) {
                    Text(
                        text = "Unpair",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
    }
}

// ─── Device Node ─────────────────────────────────────────────────────────────
@Composable
private fun DeviceNode(
    isPhone: Boolean,
    state: AppState,
    label: String
) {
    val isPaired = state !is AppState.Unpaired
    val isConnected = state is AppState.Connected
    // Phone is "active" once paired; Mac is active only when connected
    val isActive = if (isPhone) isPaired else isConnected

    val iconBg by animateColorAsState(
        targetValue = if (isActive) Color(0x1439FF14) else Color(0x0D000000),
        animationSpec = tween(400),
        label = "iconBg"
    )
    val iconTint by animateColorAsState(
        targetValue = if (isActive) IconGreen else Color(0x40000000),
        animationSpec = tween(400),
        label = "iconTint"
    )
    val borderAlpha by animateColorAsState(
        targetValue = if (isActive) Color(0x1F39FF14) else Color.Transparent,
        animationSpec = tween(400),
        label = "borderAlpha"
    )
    val labelColor = if (isActive) Color(0xB3000000) else Color(0x59000000)

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            modifier = Modifier
                .size(80.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(iconBg)
                .border(1.dp, borderAlpha, RoundedCornerShape(24.dp)),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.size(36.dp)) {
                if (isPhone) {
                    drawPhoneIcon(iconTint)
                } else {
                    drawMacIcon(iconTint)
                }
            }
        }
        Spacer(modifier = Modifier.height(10.dp))
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = labelColor,
            textAlign = TextAlign.Center
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawPhoneIcon(tint: Color) {
    val w = size.width
    val h = size.height
    val bodyW = w * 0.52f
    val bodyH = h * 0.88f
    val left = (w - bodyW) / 2f
    val top = (h - bodyH) / 2f
    val cornerR = CornerRadius(bodyW * 0.22f)

    // Phone body
    drawRoundRect(
        color = tint,
        topLeft = Offset(left, top),
        size = Size(bodyW, bodyH),
        cornerRadius = cornerR
    )
    // Screen cutout
    drawRoundRect(
        color = Color.White.copy(alpha = 0.25f),
        topLeft = Offset(left + bodyW * 0.10f, top + bodyH * 0.08f),
        size = Size(bodyW * 0.80f, bodyH * 0.72f),
        cornerRadius = CornerRadius(bodyW * 0.12f)
    )
    // Home button
    drawCircle(
        color = Color.White.copy(alpha = 0.35f),
        radius = bodyW * 0.10f,
        center = Offset(w / 2f, top + bodyH * 0.88f)
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawMacIcon(tint: Color) {
    val w = size.width
    val h = size.height

    // Screen lid
    val screenW = w * 0.90f
    val screenH = h * 0.56f
    val screenLeft = (w - screenW) / 2f
    val screenTop = h * 0.06f
    drawRoundRect(
        color = tint,
        topLeft = Offset(screenLeft, screenTop),
        size = Size(screenW, screenH),
        cornerRadius = CornerRadius(3f.dp.toPx())
    )
    // Screen glass
    drawRoundRect(
        color = Color.White.copy(alpha = 0.25f),
        topLeft = Offset(screenLeft + screenW * 0.06f, screenTop + screenH * 0.08f),
        size = Size(screenW * 0.88f, screenH * 0.76f),
        cornerRadius = CornerRadius(2f.dp.toPx())
    )

    // Base/keyboard
    val baseW = w * 1.0f
    val baseH = h * 0.18f
    val baseTop = screenTop + screenH + h * 0.04f
    drawRoundRect(
        color = tint.copy(alpha = 0.85f),
        topLeft = Offset((w - baseW) / 2f, baseTop),
        size = Size(baseW, baseH),
        cornerRadius = CornerRadius(2f.dp.toPx())
    )
    // Notch (hinge)
    drawRoundRect(
        color = tint.copy(alpha = 0.60f),
        topLeft = Offset(w * 0.30f, baseTop - h * 0.02f),
        size = Size(w * 0.40f, h * 0.04f),
        cornerRadius = CornerRadius(1f.dp.toPx())
    )
}

// ─── Footer ──────────────────────────────────────────────────────────────────
@Composable
private fun FooterSection() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp)
    ) {
        Text(
            text = "Clipboard syncs automatically in the background.",
            fontSize = 13.sp,
            color = Color(0x4D000000),
            textAlign = TextAlign.Center,
            lineHeight = 20.sp
        )
        Spacer(modifier = Modifier.height(16.dp))
        // Nav bar hint
        Box(
            modifier = Modifier
                .width(134.dp)
                .height(5.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(Color(0x1F000000))
        )
    }
}
