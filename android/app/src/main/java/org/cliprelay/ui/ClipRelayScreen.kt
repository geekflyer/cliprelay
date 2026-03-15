package org.cliprelay.ui

// Main Compose UI screen showing connection status, pairing controls, and transfer animations.

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import org.cliprelay.BuildConfig
import org.cliprelay.R
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

// ─── UI-specific background colors ───────────────────────────────────────────
private val BgTopUnpaired = Color(0xFFE8F5F3)
private val BgTopConnected = Color(0xFFD6F5EF)
private val BgBottomUnpaired = Color(0xFFF0F0F0)
private val BgBottomConnected = Color(0xFFF0F7F5)

// ─── Root Screen ─────────────────────────────────────────────────────────────
@Composable
fun ClipRelayScreen(
    state: AppState,
    showBurst: Boolean,
    clipboardTransferFlow: Flow<Boolean> = emptyFlow(),
    autoClearEnabled: Boolean,
    autoCopyEnabled: Boolean,
    autoCopyAccessibilityEnabled: Boolean = false,
    onPairClick: () -> Unit,
    onUnpairClick: () -> Unit,
    onBurstShown: () -> Unit,
    onAutoClearSettingChanged: (Boolean) -> Unit,
    onAutoCopySettingChanged: (Boolean) -> Unit,
    onAutoCopyFixClick: () -> Unit = {},
    onHelpClick: () -> Unit = {},
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
                val dotColor = if (isConnected) Color(0x0F003028) else Color(0x0E000000)
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
                    listOf(Color(0x2E00FFD5), Color(0x0F00FFD5), Color(0x0500FFD5), Color.Transparent)
                } else {
                    listOf(Color(0x1A00FFD5), Color(0x0A00FFD5), Color(0x0300FFD5), Color.Transparent)
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
                autoClearEnabled = autoClearEnabled,
                autoCopyEnabled = autoCopyEnabled,
                autoCopyAccessibilityEnabled = autoCopyAccessibilityEnabled,
                onPairClick = onPairClick,
                onUnpairClick = onUnpairClick,
                onAutoClearSettingChanged = onAutoClearSettingChanged,
                onAutoCopySettingChanged = onAutoCopySettingChanged,
                onAutoCopyFixClick = onAutoCopyFixClick
            )
            Spacer(modifier = Modifier.weight(1f))
            FooterSection(isPaired = isPaired, onHelpClick = onHelpClick)
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
            bg = Color(0x1400FFD5),
            dot = Color(0xFFBDBDBD),
            text = Teal,
            label = "Searching for Mac"
        )
        is AppState.Connected -> ChipStyle(
            bg = Color(0x1A00FFD5),
            dot = Aqua,
            text = Teal,
            label = "Connected"
        )
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .then(
                if (state is AppState.Connected)
                    Modifier.border(1.dp, Aqua.copy(alpha = 0.3f), RoundedCornerShape(20.dp))
                else Modifier
            )
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
    autoClearEnabled: Boolean,
    autoCopyEnabled: Boolean,
    autoCopyAccessibilityEnabled: Boolean = false,
    onPairClick: () -> Unit,
    onUnpairClick: () -> Unit,
    onAutoClearSettingChanged: (Boolean) -> Unit,
    onAutoCopySettingChanged: (Boolean) -> Unit,
    onAutoCopyFixClick: () -> Unit = {}
) {
    val isPaired = state !is AppState.Unpaired
    val isConnected = state is AppState.Connected

    val cardTopColor by animateColorAsState(
        targetValue = when (state) {
            is AppState.Unpaired -> Color.White
            is AppState.Searching -> Color(0xFFF5FFFC)
            is AppState.Connected -> Color(0xFFF0FFFC)
        },
        animationSpec = tween(600),
        label = "cardTop"
    )

    val borderColor by animateColorAsState(
        targetValue = when (state) {
            is AppState.Unpaired -> Color(0x1400FFD5)
            is AppState.Searching -> Color(0x1F00FFD5)
            is AppState.Connected -> Color(0x3300FFD5)
        },
        animationSpec = tween(600),
        label = "cardBorder"
    )

    val deviceName = when (state) {
        is AppState.Connected -> state.deviceName
        is AppState.Searching -> state.deviceName
        else -> null
    }
    val deviceTag = when (state) {
        is AppState.Connected -> state.deviceTag
        is AppState.Searching -> state.deviceTag
        else -> null
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .shadow(
                elevation = if (isConnected) 8.dp else 5.dp,
                shape = RoundedCornerShape(28.dp),
                spotColor = if (isConnected) Color(0x1A00FFD5) else Color(0x1A000000)
            )
            .clip(RoundedCornerShape(28.dp))
            .background(Brush.verticalGradient(listOf(cardTopColor, Color.White)))
            .border(
                width = 1.dp,
                color = borderColor,
                shape = RoundedCornerShape(28.dp)
            )
            .padding(start = 24.dp, end = 24.dp, top = 36.dp, bottom = 28.dp)
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // App icon above title
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(Aqua),
                contentAlignment = Alignment.Center
            ) {
                Image(
                    painter = painterResource(R.mipmap.ic_launcher_foreground),
                    contentDescription = "ClipRelay icon",
                    modifier = Modifier.size(64.dp)
                )
            }
            Spacer(modifier = Modifier.height(12.dp))
            // Title
            Text(
                text = "ClipRelay",
                fontSize = 34.sp,
                fontWeight = FontWeight.Bold,
                color = Teal,
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Seamless clipboard sharing with your Mac",
                fontSize = 15.sp,
                color = if (isPaired) Teal.copy(alpha = 0.45f) else Color(0x66000000),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.height(24.dp))
            HorizontalDivider(
                color = if (isPaired) Color(0x1400FFD5) else Color(0x0F00FFD5),
                thickness = 1.dp
            )
            Spacer(modifier = Modifier.height(24.dp))

            // Device row with background lock watermark when connected
            val lockAlpha by animateColorAsState(
                targetValue = if (isConnected) Aqua.copy(alpha = 0.12f) else Color.Transparent,
                animationSpec = tween(800),
                label = "lockAlpha"
            )
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.Center
            ) {
                // Big lock watermark + label behind device row
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.offset(y = (-28).dp)
                ) {
                Canvas(
                    modifier = Modifier.size(100.dp)
                ) {
                    val c = lockAlpha
                    if (c != Color.Transparent) {
                        val w = size.width
                        val h = size.height
                        val cx = w / 2f

                        // Lock body
                        val bodyW = w * 0.58f
                        val bodyH = h * 0.38f
                        val bodyTop = h * 0.52f
                        drawRoundRect(
                            color = c,
                            topLeft = Offset(cx - bodyW / 2f, bodyTop),
                            size = Size(bodyW, bodyH),
                            cornerRadius = CornerRadius(bodyW * 0.15f)
                        )

                        // Shackle arc
                        val sW = bodyW * 0.62f
                        val sH = h * 0.28f
                        val shackleStroke = bodyW * 0.13f
                        drawArc(
                            color = c,
                            startAngle = 180f,
                            sweepAngle = 180f,
                            useCenter = false,
                            topLeft = Offset(cx - sW / 2f, bodyTop - sH),
                            size = Size(sW, sH),
                            style = Stroke(shackleStroke, cap = StrokeCap.Round)
                        )

                        // Shackle legs
                        val legTop = bodyTop - sH / 2f
                        drawLine(c, Offset(cx - sW / 2f, legTop), Offset(cx - sW / 2f, bodyTop), shackleStroke)
                        drawLine(c, Offset(cx + sW / 2f, legTop), Offset(cx + sW / 2f, bodyTop), shackleStroke)
                    }
                }
                if (isPaired) {
                    Text(
                        text = if (isConnected) "End-to-end encrypted" else "Paired",
                        fontSize = 11.sp,
                        color = Teal.copy(alpha = 0.4f),
                        fontWeight = FontWeight.Medium
                    )
                    if (deviceTag != null) {
                        Text(
                            text = "Pairing: $deviceTag",
                            fontSize = 11.sp,
                            color = Teal.copy(alpha = 0.45f),
                            fontWeight = FontWeight.Normal
                        )
                    }
                }
                }

                // Device row on top
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Top
                ) {
                    DeviceNode(
                        isPhone = true,
                        state = state,
                        label = "This phone"
                    )
                    // Offset beam to vertically center on the 80dp icon boxes
                    BeamCanvas(
                        state = state,
                        clipboardTransferFlow = clipboardTransferFlow,
                        modifier = Modifier
                            .weight(1f)
                            .height(40.dp)
                            .padding(horizontal = 8.dp)
                            .offset(y = 20.dp)
                    )
                    DeviceNode(
                        isPhone = false,
                        state = state,
                        label = deviceName ?: "Mac"
                    )
                }
            }

            Spacer(modifier = Modifier.height(28.dp))

            // Action button
            if (!isPaired) {
                Button(
                    onClick = onPairClick,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(28.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Aqua,
                        contentColor = Teal
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
                val unpairBg by animateColorAsState(
                    targetValue = if (isConnected) Color(0x1400FFD5) else Color(0x0F00FFD5),
                    animationSpec = tween(400),
                    label = "unpairBg"
                )
                val unpairBorder by animateColorAsState(
                    targetValue = if (isConnected) Color(0x2600FFD5) else Color(0x1A00FFD5),
                    animationSpec = tween(400),
                    label = "unpairBorder"
                )
                Button(
                    onClick = onUnpairClick,
                    modifier = Modifier
                        .fillMaxWidth()
                        .border(1.dp, unpairBorder, RoundedCornerShape(28.dp)),
                    shape = RoundedCornerShape(28.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = unpairBg,
                        contentColor = Teal
                    ),
                    elevation = ButtonDefaults.buttonElevation(0.dp, 0.dp, 0.dp)
                ) {
                    Text(
                        text = "Unpair",
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(vertical = 4.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))
            AutoClearSettingRow(
                enabled = autoClearEnabled,
                onEnabledChange = onAutoClearSettingChanged
            )
            Spacer(modifier = Modifier.height(8.dp))
            AutoCopySettingRow(
                enabled = autoCopyEnabled,
                accessibilityEnabled = autoCopyAccessibilityEnabled,
                onEnabledChange = onAutoCopySettingChanged,
                onFixClick = onAutoCopyFixClick
            )
        }
    }
}

@Composable
private fun AutoClearSettingRow(
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit
) {
    val toggleBg = if (enabled) Color(0x1400FFD5) else Color(0x08000000)
    val toggleBorder = if (enabled) Color(0x2B00FFD5) else Color(0x14000000)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(toggleBg)
            .border(1.dp, toggleBorder, RoundedCornerShape(18.dp))
            .toggleable(
                value = enabled,
                role = Role.Switch,
                onValueChange = onEnabledChange
            )
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(R.string.auto_clear_setting_title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = stringResource(R.string.auto_clear_setting_subtitle),
                fontSize = 12.sp,
                color = Color(0x80000000),
                lineHeight = 16.sp
            )
        }

        Spacer(modifier = Modifier.width(12.dp))

        Switch(
            checked = enabled,
            onCheckedChange = onEnabledChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Teal,
                checkedTrackColor = Aqua.copy(alpha = 0.45f),
                checkedBorderColor = Aqua.copy(alpha = 0.60f),
                uncheckedThumbColor = Color(0xFF7A7A7A),
                uncheckedTrackColor = Color(0x15000000),
                uncheckedBorderColor = Color(0x40000000)
            )
        )
    }
}

@Composable
private fun AutoCopySettingRow(
    enabled: Boolean,
    accessibilityEnabled: Boolean = false,
    onEnabledChange: (Boolean) -> Unit,
    onFixClick: () -> Unit = {}
) {
    val isBroken = enabled && !accessibilityEnabled
    val warningColor = Color(0xFFE57373)

    val toggleBg = if (enabled) Color(0x1400FFD5) else Color(0x08000000)
    val toggleBorder = when {
        isBroken -> warningColor.copy(alpha = 0.5f)
        enabled -> Color(0x2B00FFD5)
        else -> Color(0x14000000)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(toggleBg)
            .border(if (isBroken) 2.dp else 1.dp, toggleBorder, RoundedCornerShape(18.dp))
            .then(
                if (isBroken)
                    // In broken state, tapping the row opens accessibility settings
                    Modifier.clickable(onClick = onFixClick)
                else
                    Modifier.toggleable(
                        value = enabled,
                        role = Role.Switch,
                        onValueChange = onEnabledChange
                    )
            )
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (isBroken) {
            Text(
                text = "\u26A0\uFE0F",
                fontSize = 24.sp,
                modifier = Modifier.padding(end = 10.dp)
            )
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = stringResource(R.string.auto_copy_setting_title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = if (isBroken)
                    stringResource(R.string.auto_copy_needs_accessibility)
                else if (enabled)
                    stringResource(R.string.auto_copy_setting_subtitle_on)
                else
                    stringResource(R.string.auto_copy_setting_subtitle_off),
                fontSize = 12.sp,
                fontWeight = if (isBroken) FontWeight.SemiBold else FontWeight.Normal,
                color = if (isBroken) warningColor else Color(0x80000000),
                lineHeight = 16.sp
            )
        }

        Spacer(modifier = Modifier.width(12.dp))

        // In broken state, switch toggles off (disables auto-copy)
        // In normal state, switch toggles on/off as usual
        Switch(
            checked = enabled,
            onCheckedChange = onEnabledChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Teal,
                checkedTrackColor = Aqua.copy(alpha = 0.45f),
                checkedBorderColor = Aqua.copy(alpha = 0.60f),
                uncheckedThumbColor = Color(0xFF7A7A7A),
                uncheckedTrackColor = Color(0x15000000),
                uncheckedBorderColor = Color(0x40000000)
            )
        )
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
        targetValue = if (isActive) Color(0x1400FFD5) else Color(0x0D000000),
        animationSpec = tween(400),
        label = "iconBg"
    )
    val iconTint by animateColorAsState(
        targetValue = if (isActive) Teal else Color(0x40000000),
        animationSpec = tween(400),
        label = "iconTint"
    )
    val borderAlpha by animateColorAsState(
        targetValue = if (isActive) Color(0x1F00FFD5) else Color.Transparent,
        animationSpec = tween(400),
        label = "borderAlpha"
    )
    val labelColor = if (isActive) Color(0xB3000000) else Color(0x59000000)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.width(90.dp)
    ) {
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
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
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
private fun FooterSection(isPaired: Boolean, onHelpClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.padding(horizontal = 28.dp, vertical = 16.dp)
    ) {
        if (isPaired) {
            Button(
                onClick = onHelpClick,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(28.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0x1400FFD5),
                    contentColor = Teal
                ),
                elevation = ButtonDefaults.buttonElevation(0.dp, 0.dp, 0.dp)
            ) {
                Text(
                    text = "\uD83D\uDCA1 How to share",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(vertical = 4.dp)
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
        }
        Text(
            text = "ClipRelay v${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_HASH})",
            style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
            color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
