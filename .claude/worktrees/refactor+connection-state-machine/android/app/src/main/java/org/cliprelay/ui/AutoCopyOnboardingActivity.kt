package org.cliprelay.ui

// Post-pairing onboarding screen explaining clipboard sharing options.
// Shows manual options (always available) and optional auto-copy with caveats.

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.cliprelay.R
import org.cliprelay.service.ClipRelayService
import org.cliprelay.settings.ClipboardSettingsStore

class AutoCopyOnboardingActivity : ComponentActivity() {

    private lateinit var settingsStore: ClipboardSettingsStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settingsStore = ClipboardSettingsStore(this)

        setContent {
            OnboardingScreen(
                onEnableAutoCopy = { enableAutoCopy() },
                onDismiss = { dismiss() }
            )
        }
    }

    private fun enableAutoCopy() {
        settingsStore.setAutoCopyEnabled(true)
        settingsStore.setAutoCopyOnboardingShown(true)

        // Guide user to enable accessibility service
        val accessibilityIntent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
        startActivity(accessibilityIntent)

        setResult(RESULT_OK)
        finish()
    }

    private fun dismiss() {
        settingsStore.setAutoCopyOnboardingShown(true)
        setResult(RESULT_OK)
        finish()
    }
}

@Composable
private fun OnboardingScreen(
    onEnableAutoCopy: () -> Unit,
    onDismiss: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xFFE8F5F3), Color(0xFFF5F5F5), Color(0xFFF0F7F5))
                )
            )
            .statusBarsPadding()
            .navigationBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = stringResource(R.string.onboarding_title),
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            color = Teal,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(32.dp))

        // ── Always available section ──
        Text(
            text = stringResource(R.string.onboarding_always_available),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0x99000000),
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(12.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(Color.White)
                .border(1.dp, Color(0x1F00FFD5), RoundedCornerShape(20.dp))
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            // ── Share menu option ──
            ShareMenuOption()

            // ── Quick Settings tile option ──
            TileOption()
        }

        Spacer(modifier = Modifier.height(24.dp))

        HorizontalDivider(color = Color(0x1400FFD5), thickness = 1.dp)

        Spacer(modifier = Modifier.height(24.dp))

        // ── Auto-copy section ──
        Text(
            text = stringResource(R.string.onboarding_auto_section),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0x99000000),
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(12.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(Color.White)
                .border(1.dp, Color(0x1F00FFD5), RoundedCornerShape(20.dp))
                .clickable(onClick = onEnableAutoCopy)
                .padding(20.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0x1400FFD5)),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "\u21C4",
                        fontSize = 22.sp,
                        color = Teal,
                        fontWeight = FontWeight.Bold
                    )
                }

                Spacer(modifier = Modifier.width(14.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = stringResource(R.string.onboarding_auto_title),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Teal
                    )
                    Spacer(modifier = Modifier.height(2.dp))
                    Text(
                        text = stringResource(R.string.onboarding_auto_subtitle),
                        fontSize = 12.sp,
                        color = Color(0x80000000),
                        lineHeight = 16.sp
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            Column(modifier = Modifier.padding(start = 58.dp)) {
                CaveatItem(stringResource(R.string.onboarding_auto_caveat_accessibility))
                CaveatItem(stringResource(R.string.onboarding_auto_caveat_notification))
                CaveatItem(stringResource(R.string.onboarding_auto_caveat_reliability))
            }
        }

        Spacer(modifier = Modifier.height(32.dp))

        Button(
            onClick = onDismiss,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(28.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Aqua,
                contentColor = Teal
            )
        ) {
            Text(
                text = stringResource(R.string.onboarding_got_it),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(vertical = 4.dp)
            )
        }
    }
}

// ── Share menu option with inline icons ──
@Composable
private fun ShareMenuOption() {
    Column {
        Text(
            text = stringResource(R.string.onboarding_share_sheet_title),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xCC000000)
        )
        Spacer(modifier = Modifier.height(6.dp))

        // Instruction text with inline icons
        val moreIconId = "moreIcon"
        val shareIconId = "shareIcon"
        val cliprelayIconId = "cliprelayIcon"
        val text = buildAnnotatedString {
            append("Select text, tap ")
            appendInlineContent(moreIconId, "[⋮]")
            append(" then ")
            appendInlineContent(shareIconId, "[share]")
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = Teal)) {
                append(" Share")
            }
            append(", and choose ")
            appendInlineContent(cliprelayIconId, "[icon]")
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = Teal)) {
                append(" ClipRelay")
            }
        }
        Text(
            text = text,
            inlineContent = mapOf(
                moreIconId to InlineTextContent(
                    Placeholder(22.sp, 22.sp, PlaceholderVerticalAlign.TextCenter)
                ) {
                    // Three vertical dots (⋮)
                    Canvas(modifier = Modifier.fillMaxSize()) {
                        val dotRadius = 2.dp.toPx()
                        val cx = size.width / 2f
                        val spacing = size.height / 4f
                        drawCircle(Color(0xCC000000), dotRadius, Offset(cx, spacing))
                        drawCircle(Color(0xCC000000), dotRadius, Offset(cx, spacing * 2))
                        drawCircle(Color(0xCC000000), dotRadius, Offset(cx, spacing * 3))
                    }
                },
                shareIconId to InlineTextContent(
                    Placeholder(22.sp, 22.sp, PlaceholderVerticalAlign.TextCenter)
                ) {
                    Icon(
                        imageVector = Icons.Default.Share,
                        contentDescription = null,
                        tint = Teal,
                        modifier = Modifier.fillMaxSize().padding(2.dp)
                    )
                },
                cliprelayIconId to InlineTextContent(
                    Placeholder(22.sp, 22.sp, PlaceholderVerticalAlign.TextCenter)
                ) {
                    Image(
                        painter = painterResource(R.mipmap.ic_launcher_foreground),
                        contentDescription = null,
                        modifier = Modifier
                            .fillMaxSize()
                            .clip(CircleShape)
                            .background(Aqua)
                    )
                }
            ),
            fontSize = 14.sp,
            color = Color(0x80000000),
            lineHeight = 24.sp
        )
    }
}

// ── Quick Settings tile option with mock tile ──
@Composable
private fun TileOption() {
    Column {
        Text(
            text = stringResource(R.string.onboarding_tile_title),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color(0xCC000000)
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = stringResource(R.string.onboarding_tile_desc),
            fontSize = 12.sp,
            color = Color(0x80000000),
            lineHeight = 16.sp
        )

        Spacer(modifier = Modifier.height(10.dp))

        // Mock Quick Settings tiles — compact + expanded
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Compact tile (icon only)
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color(0xFF3C3C3E)),
                contentAlignment = Alignment.Center
            ) {
                TileClipboardIcon(size = 18.dp)
            }

            Spacer(modifier = Modifier.width(12.dp))

            Text(
                text = "or",
                fontSize = 12.sp,
                color = Color(0x66000000)
            )

            Spacer(modifier = Modifier.width(12.dp))

            // Expanded tile (icon + text)
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(24.dp))
                    .background(Color(0xFF3C3C3E))
                    .padding(horizontal = 14.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF5A5A5C)),
                    contentAlignment = Alignment.Center
                ) {
                    TileClipboardIcon(size = 14.dp)
                }
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = "Send to Mac",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = Color.White
                )
            }
        }
    }
}

@Composable
private fun TileClipboardIcon(size: androidx.compose.ui.unit.Dp) {
    Canvas(modifier = Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val c = Color.White
        // Body
        drawRoundRect(
            color = c,
            topLeft = Offset(w * 0.12f, h * 0.22f),
            size = androidx.compose.ui.geometry.Size(w * 0.56f, h * 0.72f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f)
        )
        // Clip
        drawRoundRect(
            color = c,
            topLeft = Offset(w * 0.24f, h * 0.08f),
            size = androidx.compose.ui.geometry.Size(w * 0.32f, h * 0.2f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f)
        )
        // Wireless arcs
        drawArc(
            color = c,
            startAngle = -45f, sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(w * 0.58f, h * 0.28f),
            size = androidx.compose.ui.geometry.Size(w * 0.22f, h * 0.32f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.2f.dp.toPx())
        )
        drawArc(
            color = c,
            startAngle = -45f, sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(w * 0.68f, h * 0.18f),
            size = androidx.compose.ui.geometry.Size(w * 0.28f, h * 0.52f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.2f.dp.toPx())
        )
    }
}

@Composable
private fun CaveatItem(text: String) {
    Row(
        modifier = Modifier.padding(vertical = 2.dp),
        verticalAlignment = Alignment.Top
    ) {
        Text(
            text = "•",
            fontSize = 12.sp,
            color = Color(0x66000000),
            modifier = Modifier.padding(end = 6.dp, top = 1.dp)
        )
        Text(
            text = text,
            fontSize = 12.sp,
            color = Color(0x66000000),
            lineHeight = 16.sp
        )
    }
}
