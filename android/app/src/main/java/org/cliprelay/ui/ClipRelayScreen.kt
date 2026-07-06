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
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
    hideClipboardEnabled: Boolean = true,
    autoCopyEnabled: Boolean,
    autoCopyAccessibilityEnabled: Boolean = false,
    imageSyncEnabled: Boolean = false,
    otpRelayEnabled: Boolean = false,
    pairingFailed: Boolean = false,
    onPairingCancelClick: () -> Unit = {},
    onPairingErrorDismiss: () -> Unit = {},
    onPairClick: () -> Unit,
    onForgetMacClick: (String) -> Unit = {},
    onBurstShown: () -> Unit,
    onAutoClearSettingChanged: (Boolean) -> Unit,
    onHideClipboardSettingChanged: (Boolean) -> Unit = {},
    onAutoCopySettingChanged: (Boolean) -> Unit,
    onImageSyncSettingChanged: (Boolean) -> Unit = {},
    onAutoCopyFixClick: () -> Unit = {},
    onOtpRelaySettingChanged: (Boolean) -> Unit = {},
    onHelpClick: () -> Unit = {},
    onSupportLinkClick: (String) -> Unit = {},
    onShareLogsClick: (String) -> Unit = {},
) {
    val isConnected = state is AppState.Paired && state.anyConnected
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
        // Scrollable so the card (which contains the footer buttons) stays fully
        // reachable when the Mac list grows it beyond the screen; the clipped
        // card edge doubles as the scroll affordance. When everything fits,
        // SpaceBetween with a min-height of the viewport centers the layout.
        // Insets handled inside the scroll column so content scrolls behind
        // the transparent status and gesture bars (edge-to-edge).
        BoxWithConstraints(
            modifier = Modifier.fillMaxSize()
        ) {
            val viewportHeight = maxHeight
            val scrollState = rememberScrollState()
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(scrollState)
                    .heightIn(min = viewportHeight),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(
                    modifier = Modifier.windowInsetsTopHeight(WindowInsets.statusBars)
                )
                Spacer(modifier = Modifier.height(12.dp))
                StatusChip(state = state)
            }
            Box(modifier = Modifier.padding(vertical = 16.dp)) {
                MainCard(
                    state = state,
                    clipboardTransferFlow = clipboardTransferFlow,
                    autoClearEnabled = autoClearEnabled,
                    hideClipboardEnabled = hideClipboardEnabled,
                    autoCopyEnabled = autoCopyEnabled,
                    autoCopyAccessibilityEnabled = autoCopyAccessibilityEnabled,
                    imageSyncEnabled = imageSyncEnabled,
                    otpRelayEnabled = otpRelayEnabled,
                    pairingFailed = pairingFailed,
                    onPairingCancelClick = onPairingCancelClick,
                    onPairingErrorDismiss = onPairingErrorDismiss,
                    onPairClick = onPairClick,
                    onForgetMacClick = onForgetMacClick,
                    onAutoClearSettingChanged = onAutoClearSettingChanged,
                    onHideClipboardSettingChanged = onHideClipboardSettingChanged,
                    onAutoCopySettingChanged = onAutoCopySettingChanged,
                    onImageSyncSettingChanged = onImageSyncSettingChanged,
                    onAutoCopyFixClick = onAutoCopyFixClick,
                    onOtpRelaySettingChanged = onOtpRelaySettingChanged,
                    footer = {
                        FooterSection(
                            isPaired = isPaired,
                            bleState = when {
                                isConnected -> "connected"
                                state is AppState.Paired -> "searching"
                                state is AppState.Pairing -> "searching"
                                else -> "unpaired"
                            },
                            onHelpClick = onHelpClick,
                            onSupportLinkClick = onSupportLinkClick,
                            onShareLogsClick = onShareLogsClick,
                        )
                    }
                )
            }
            Text(
                text = "ClipRelay v${BuildConfig.VERSION_NAME} (${BuildConfig.GIT_HASH})",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 12.dp)
            )
            Spacer(
                modifier = Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars)
            )
            }

            // Bottom fade: clipped card content melts to white when more is below.
            AnimatedVisibility(
                visible = scrollState.canScrollForward,
                modifier = Modifier.align(Alignment.BottomCenter),
                enter = fadeIn(tween(200)),
                exit = fadeOut(tween(200))
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(64.dp)
                        .background(
                            Brush.verticalGradient(
                                listOf(Color.Transparent, Color.White)
                            )
                        )
                )
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
        is AppState.Pairing -> ChipStyle(
            bg = Color(0x1400FFD5),
            dot = Color(0xFFBDBDBD),
            text = Teal,
            label = "Pairing…"
        )
        is AppState.Paired -> if (state.anyConnected) ChipStyle(
            bg = Color(0x1A00FFD5),
            dot = Aqua,
            text = Teal,
            label = when {
                state.macs.size == 1 -> "Connected"
                else -> "Connected to ${state.connectedCount} of ${state.macs.size} Macs"
            }
        ) else ChipStyle(
            bg = Color(0x1400FFD5),
            dot = Color(0xFFBDBDBD),
            text = Teal,
            label = if (state.macs.size == 1) "Searching for Mac" else "Searching for Macs"
        )
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .then(
                if (state is AppState.Paired && state.anyConnected)
                    Modifier.border(1.dp, Aqua.copy(alpha = 0.3f), RoundedCornerShape(20.dp))
                else Modifier
            )
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Animated dot for Searching/Pairing states
        if ((state is AppState.Paired && !state.anyConnected) || state is AppState.Pairing) {
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
    hideClipboardEnabled: Boolean = true,
    autoCopyEnabled: Boolean,
    autoCopyAccessibilityEnabled: Boolean = false,
    imageSyncEnabled: Boolean = false,
    otpRelayEnabled: Boolean = false,
    pairingFailed: Boolean = false,
    onPairingCancelClick: () -> Unit = {},
    onPairingErrorDismiss: () -> Unit = {},
    onPairClick: () -> Unit,
    onForgetMacClick: (String) -> Unit = {},
    onAutoClearSettingChanged: (Boolean) -> Unit,
    onHideClipboardSettingChanged: (Boolean) -> Unit = {},
    onAutoCopySettingChanged: (Boolean) -> Unit,
    onImageSyncSettingChanged: (Boolean) -> Unit = {},
    onAutoCopyFixClick: () -> Unit = {},
    onOtpRelaySettingChanged: (Boolean) -> Unit = {},
    footer: @Composable () -> Unit = {}
) {
    val isPaired = state !is AppState.Unpaired
    val isConnected = state is AppState.Paired && state.anyConnected
    val macs = (state as? AppState.Paired)?.macs ?: emptyList()

    val cardTopColor by animateColorAsState(
        targetValue = when {
            state is AppState.Unpaired -> Color.White
            isConnected -> Color(0xFFF0FFFC)
            else -> Color(0xFFF5FFFC)
        },
        animationSpec = tween(600),
        label = "cardTop"
    )

    val borderColor by animateColorAsState(
        targetValue = when {
            state is AppState.Unpaired -> Color(0x1400FFD5)
            isConnected -> Color(0x3300FFD5)
            else -> Color(0x1F00FFD5)
        },
        animationSpec = tween(600),
        label = "cardBorder"
    )

    // Node label: single Mac shows its name; several show a count.
    val deviceName = when {
        macs.size == 1 -> macs[0].name
        macs.size > 1 -> "${macs.size} Macs"
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
            .padding(start = 24.dp, end = 24.dp, top = 24.dp, bottom = 24.dp)
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // App icon + title inline, centered
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
                modifier = Modifier.fillMaxWidth()
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(15.dp))
                        .background(Aqua),
                    contentAlignment = Alignment.Center
                ) {
                    Image(
                        painter = painterResource(R.mipmap.ic_launcher_foreground),
                        contentDescription = "ClipRelay icon",
                        modifier = Modifier.size(48.dp)
                    )
                }
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = "ClipRelay",
                    fontSize = 34.sp,
                    fontWeight = FontWeight.Bold,
                    color = Teal
                )
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "Seamless clipboard sharing with your Mac",
                fontSize = 13.sp,
                color = if (isPaired) Teal.copy(alpha = 0.45f) else Color(0x66000000),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )

            HorizontalDivider(
                color = if (isPaired) Color(0x1400FFD5) else Color(0x0F00FFD5),
                thickness = 1.dp
            )
            Spacer(modifier = Modifier.height(16.dp))

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

            Spacer(modifier = Modifier.height(20.dp))

            // Action area
            if (state is AppState.Pairing) {
                PairingStatusRow(
                    stage = state.stage,
                    onCancelClick = onPairingCancelClick
                )
            } else if (state is AppState.Unpaired) {
                if (pairingFailed) {
                    PairingFailedCard(
                        onTryAgain = {
                            onPairingErrorDismiss()
                            onPairClick()
                        },
                        onDismiss = onPairingErrorDismiss
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                }
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
                if (pairingFailed) {
                    PairingFailedCard(
                        onTryAgain = {
                            onPairingErrorDismiss()
                            onPairClick()
                        },
                        onDismiss = onPairingErrorDismiss
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                }
                MacListSection(
                    macs = macs,
                    onForgetMacClick = onForgetMacClick,
                    onPairAnotherClick = onPairClick
                )
            }

            Spacer(modifier = Modifier.height(12.dp))
            AutoClearSettingRow(
                enabled = autoClearEnabled,
                onEnabledChange = onAutoClearSettingChanged
            )
            Spacer(modifier = Modifier.height(8.dp))
            HideClipboardSettingRow(
                enabled = hideClipboardEnabled,
                onEnabledChange = onHideClipboardSettingChanged
            )
            Spacer(modifier = Modifier.height(8.dp))
            ImageSyncSettingRow(
                enabled = imageSyncEnabled,
                onEnabledChange = onImageSyncSettingChanged
            )
            Spacer(modifier = Modifier.height(8.dp))
            OtpRelaySettingRow(
                enabled = otpRelayEnabled,
                onEnabledChange = onOtpRelaySettingChanged
            )
            Spacer(modifier = Modifier.height(8.dp))
            AutoCopySettingRow(
                enabled = autoCopyEnabled,
                accessibilityEnabled = autoCopyAccessibilityEnabled,
                onEnabledChange = onAutoCopySettingChanged,
                onFixClick = onAutoCopyFixClick
            )
            footer()
        }
    }
}

@Composable
private fun PairingStatusRow(
    stage: PairingStage,
    onCancelClick: () -> Unit
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0x1400FFD5))
                .border(1.dp, Color(0x2B00FFD5), RoundedCornerShape(18.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = Teal
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = when (stage) {
                    PairingStage.Connecting -> "Connecting to your Mac…"
                    PairingStage.ExchangingKeys -> "Exchanging keys…"
                },
                color = Teal,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium
            )
        }
        TextButton(onClick = onCancelClick) {
            Text(
                text = "Cancel",
                color = Teal.copy(alpha = 0.6f),
                fontSize = 13.sp
            )
        }
    }
}

// ─── Paired Mac List ─────────────────────────────────────────────────────────
@Composable
private fun MacListSection(
    macs: List<PairedMacUi>,
    onForgetMacClick: (String) -> Unit,
    onPairAnotherClick: () -> Unit
) {
    var macPendingForget by remember { mutableStateOf<PairedMacUi?>(null) }

    Column(modifier = Modifier.fillMaxWidth()) {
        macs.forEachIndexed { index, mac ->
            MacRow(mac = mac, onForgetClick = { macPendingForget = mac })
            if (index < macs.lastIndex) Spacer(modifier = Modifier.height(8.dp))
        }

        if (macs.size < org.cliprelay.pairing.PairingStore.MAX_PAIRED_MACS) {
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onPairAnotherClick,
                modifier = Modifier
                    .fillMaxWidth()
                    .border(1.dp, Color(0x1A00FFD5), RoundedCornerShape(28.dp)),
                shape = RoundedCornerShape(28.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0x0F00FFD5),
                    contentColor = Teal
                ),
                elevation = ButtonDefaults.buttonElevation(0.dp, 0.dp, 0.dp)
            ) {
                Text(
                    text = "+ Pair another Mac",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(vertical = 4.dp)
                )
            }
        }
    }

    macPendingForget?.let { mac ->
        AlertDialog(
            onDismissRequest = { macPendingForget = null },
            title = { Text("Forget ${mac.name ?: "this Mac"}?") },
            text = { Text("This Mac will no longer sync with your phone. You can pair it again anytime.") },
            confirmButton = {
                TextButton(onClick = {
                    onForgetMacClick(mac.id)
                    macPendingForget = null
                }) {
                    Text("Forget", color = Color(0xFFB71C1C), fontWeight = FontWeight.SemiBold)
                }
            },
            dismissButton = {
                TextButton(onClick = { macPendingForget = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun MacRow(mac: PairedMacUi, onForgetClick: () -> Unit) {
    val rowBg = if (mac.connected) Color(0x1400FFD5) else Color(0x08000000)
    val rowBorder = if (mac.connected) Color(0x2B00FFD5) else Color(0x14000000)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(rowBg)
            .border(1.dp, rowBorder, RoundedCornerShape(18.dp))
            .padding(start = 14.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (mac.connected) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(Aqua)
            )
        } else {
            BlinkingDot(color = Color(0xFFBDBDBD))
        }
        Spacer(modifier = Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = mac.name ?: "Mac",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000),
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
            Text(
                text = (if (mac.connected) "Connected" else "Searching") + " · ${mac.tagDisplay}",
                fontSize = 11.sp,
                color = Color(0x73000000)
            )
        }
        TextButton(onClick = onForgetClick) {
            Text(text = "Forget", fontSize = 12.sp, color = Color(0x80000000))
        }
    }
}

@Composable
private fun PairingFailedCard(
    onTryAgain: () -> Unit,
    onDismiss: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0x14FF5252))
            .border(1.dp, Color(0x29FF5252), RoundedCornerShape(18.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp)
    ) {
        Text(
            text = "Couldn't reach your Mac",
            color = Color(0xFFB71C1C),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "Make sure ClipRelay is open on your Mac and Bluetooth is on, then try again.",
            color = Color(0xCC7F0000),
            fontSize = 12.sp
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
            TextButton(onClick = onDismiss) {
                Text(text = "Dismiss", fontSize = 13.sp, color = Color(0x99000000))
            }
            TextButton(onClick = onTryAgain) {
                Text(text = "Try again", fontSize = 13.sp, color = Color(0xFFB71C1C), fontWeight = FontWeight.SemiBold)
            }
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
private fun HideClipboardSettingRow(
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
                text = stringResource(R.string.hide_clipboard_setting_title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = stringResource(R.string.hide_clipboard_setting_subtitle),
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

@Composable
private fun OtpRelaySettingRow(
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
                text = stringResource(R.string.otp_relay_setting_title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = stringResource(R.string.otp_relay_setting_subtitle),
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
private fun ImageSyncSettingRow(
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
                text = stringResource(R.string.image_sync_setting_title),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xCC000000)
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = stringResource(R.string.image_sync_setting_subtitle),
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

// ─── Device Node ─────────────────────────────────────────────────────────────
@Composable
private fun DeviceNode(
    isPhone: Boolean,
    state: AppState,
    label: String
) {
    val isPaired = state !is AppState.Unpaired
    val isConnected = state is AppState.Paired && state.anyConnected
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
private fun FooterSection(
    isPaired: Boolean,
    bleState: String = "unknown",
    onHelpClick: () -> Unit,
    onSupportLinkClick: (String) -> Unit,
    onShareLogsClick: (String) -> Unit
) {
    var showSupportDialog by remember { mutableStateOf(false) }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 16.dp)
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
        Button(
            onClick = { showSupportDialog = true },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(28.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Color(0x1400FFD5),
                contentColor = Teal
            ),
            elevation = ButtonDefaults.buttonElevation(0.dp, 0.dp, 0.dp)
        ) {
            Text(
                text = "💬 Feedback & Support",
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(vertical = 4.dp)
            )
        }
    }

    if (showSupportDialog) {
        SupportDialog(
            bleState = bleState,
            onDismiss = { showSupportDialog = false },
            onLinkClick = { url ->
                showSupportDialog = false
                onSupportLinkClick(url)
            },
            onShareLogsClick = {
                showSupportDialog = false
                onShareLogsClick(bleState)
            },
        )
    }
}

@Composable
private fun SupportDialog(
    bleState: String,
    onDismiss: () -> Unit,
    onLinkClick: (String) -> Unit,
    onShareLogsClick: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Feedback & Support") },
        text = {
            Column {
                TextButton(onClick = { onLinkClick(org.cliprelay.feedback.SupportLinks.gitHubIssueUrl(bleState)) }) {
                    Text("Report Issue on GitHub", modifier = Modifier.fillMaxWidth())
                }
                TextButton(onClick = { onLinkClick(org.cliprelay.feedback.SupportLinks.emailUrl(bleState)) }) {
                    Text("Email Support", modifier = Modifier.fillMaxWidth())
                }
                TextButton(onClick = { onLinkClick(org.cliprelay.feedback.SupportLinks.DISCUSSIONS_URL) }) {
                    Text("Community Discussions", modifier = Modifier.fillMaxWidth())
                }
                TextButton(onClick = { onLinkClick(org.cliprelay.feedback.SupportLinks.PLAY_STORE_URL) }) {
                    Text("Rate on Play Store", modifier = Modifier.fillMaxWidth())
                }
                TextButton(onClick = onShareLogsClick) {
                    Text(stringResource(R.string.support_share_logs), modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

// ─── Accessibility Disclosure Dialog ─────────────────────────────────────────
@Composable
fun AccessibilityDisclosureDialog(
    onAllow: () -> Unit,
    onDeny: () -> Unit
) {
    AlertDialog(
        onDismissRequest = { /* Do not dismiss on outside tap — require explicit button */ },
        title = { Text(stringResource(R.string.accessibility_disclosure_title)) },
        text = { Text(stringResource(R.string.accessibility_disclosure_body)) },
        confirmButton = {
            TextButton(onClick = onAllow) {
                Text(stringResource(R.string.accessibility_disclosure_allow))
            }
        },
        dismissButton = {
            TextButton(onClick = onDeny) {
                Text(stringResource(R.string.accessibility_disclosure_deny))
            }
        },
    )
}

// ─── BLE Permission Dialog ────────────────────────────────────────────────────
// Shown before pairing when the "Nearby devices" runtime permission is missing.
// Explains why the permission is needed; when Android no longer shows the system
// prompt (permanently denied), routes the user to the app settings instead.
@Composable
fun BlePermissionDialog(
    permanentlyDenied: Boolean,
    onContinue: () -> Unit,
    onCancel: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.ble_permission_title)) },
        text = {
            Text(
                stringResource(
                    if (permanentlyDenied) R.string.ble_permission_denied_body
                    else R.string.ble_permission_body
                )
            )
        },
        confirmButton = {
            TextButton(onClick = onContinue) {
                Text(
                    stringResource(
                        if (permanentlyDenied) R.string.ble_permission_open_settings
                        else R.string.ble_permission_continue
                    )
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text(stringResource(R.string.ble_permission_cancel))
            }
        },
    )
}

// ─── Version Mismatch Dialog ──────────────────────────────────────────────────
@Composable
fun VersionMismatchDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Update Required") },
        text = {
            Text("Your Mac app needs to be updated to continue syncing. Download the latest version at cliprelay.org.")
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("OK")
            }
        }
    )
}
