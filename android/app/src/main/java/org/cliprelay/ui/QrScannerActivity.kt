package org.cliprelay.ui

// QR-based pairing scanner built on Quickie (CameraX + bundled ML Kit), so pairing works
// without Google Play services. The old GMS code scanner needed an on-demand "barcode module"
// download that could stall forever, leaving pairing stuck (issue #56).
//
// Also decodes the pairing QR from a saved image (Photo Picker + the same bundled ML Kit),
// as a fallback for devices without a usable camera (e.g. gaming handhelds).

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.github.g00fy2.quickie.QRResult
import io.github.g00fy2.quickie.ScanCustomCode
import io.github.g00fy2.quickie.config.BarcodeFormat
import io.github.g00fy2.quickie.config.ScannerConfig
import org.cliprelay.R
import org.cliprelay.pairing.PairingUriParser
import org.cliprelay.permissions.BlePermissions
import org.cliprelay.service.ClipRelayService

class QrScannerActivity : AppCompatActivity() {

    private val scanLauncher = registerForActivityResult(ScanCustomCode()) { result ->
        when (result) {
            is QRResult.QRSuccess -> handleScannedValue(result.content.rawValue)
            QRResult.QRUserCanceled -> finish()
            QRResult.QRMissingPermission -> {
                Toast.makeText(
                    this,
                    "Camera permission is needed to scan the pairing QR code",
                    Toast.LENGTH_LONG
                ).show()
                finish()
            }
            is QRResult.QRError -> {
                Toast.makeText(this, "Scan failed: ${result.exception.message}", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
    }

    private var imageErrorRes by mutableStateOf<Int?>(null)
    private var decodingImage by mutableStateOf(false)

    private val pickImageLauncher = registerForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        // null = the user backed out of the picker; stay here so they can retry or cancel.
        if (uri != null) decodeImage(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Pairing needs the BLE foreground service, which cannot start without the
        // "Nearby devices" runtime permission — bail out instead of letting the
        // service crash after the scan.
        if (!BlePermissions.hasRequiredRuntimePermissions(this)) {
            Toast.makeText(this, R.string.ble_permission_required_toast, Toast.LENGTH_LONG).show()
            finish()
            return
        }
        // Without a camera the live scanner is a dead end (CameraX retries against a
        // black screen for ~6s, then fails) — route those devices to the image picker.
        val scanFromImage =
            intent.getBooleanExtra(EXTRA_SCAN_FROM_IMAGE, false) || !deviceHasCamera(this)
        if (scanFromImage) {
            setContent {
                ImagePairingScreen(
                    errorRes = imageErrorRes,
                    decoding = decodingImage,
                    onChooseImageClick = ::launchImagePicker,
                    onCancelClick = { finish() }
                )
            }
        }
        // Launch once; avoid relaunching if the activity is recreated while the scanner is open.
        if (savedInstanceState == null) {
            if (scanFromImage) {
                launchImagePicker()
            } else {
                scanLauncher.launch(
                    ScannerConfig.build {
                        setBarcodeFormats(listOf(BarcodeFormat.FORMAT_QR_CODE))
                        setOverlayStringRes(R.string.qr_scan_prompt)
                        setShowTorchToggle(true)
                        setShowCloseButton(true)
                        setHapticSuccessFeedback(true)
                        setKeepScreenOn(true)
                    }
                )
            }
        }
    }

    private fun launchImagePicker() {
        pickImageLauncher.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        )
    }

    /**
     * Decode a QR code from [uri] with the same bundled ML Kit the live scanner uses,
     * then feed the decoded string into [handleScannedValue] — the same handler as a
     * live scan. Decode failures keep the screen up so the user can pick another image.
     */
    private fun decodeImage(uri: Uri) {
        decodingImage = true
        imageErrorRes = null
        val image = runCatching { InputImage.fromFilePath(this, uri) }.getOrElse {
            decodingImage = false
            imageErrorRes = R.string.pair_from_image_unreadable
            return
        }
        val scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        )
        scanner.process(image)
            .addOnSuccessListener { barcodes: List<Barcode> ->
                val pairingValue = barcodes.mapNotNull { it.rawValue }
                    .firstOrNull { PairingUriParser.parse(it) != null }
                when {
                    pairingValue != null -> handleScannedValue(pairingValue)
                    barcodes.isEmpty() -> imageErrorRes = R.string.pair_from_image_no_code
                    else -> imageErrorRes = R.string.pair_from_image_not_pairing
                }
            }
            .addOnFailureListener { imageErrorRes = R.string.pair_from_image_unreadable }
            .addOnCompleteListener {
                decodingImage = false
                scanner.close()
            }
    }

    private fun handleScannedValue(rawValue: String?) {
        val info = rawValue?.let { PairingUriParser.parse(it) }
        if (info == null) {
            Toast.makeText(this, "Invalid pairing QR code", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        // Store Mac's public key and device name for the service to use
        val prefs = getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
        prefs.edit()
            .putString("pending_pairing_pubkey", info.publicKeyHex)
            .putString(ClipRelayService.KEY_PENDING_PAIRING_NAME, info.deviceName ?: "")
            .apply()

        // Signal the service to start pairing mode
        val intent = Intent(this, ClipRelayService::class.java)
        intent.action = ClipRelayService.ACTION_START_PAIRING
        if (!BlePermissions.hasRequiredRuntimePermissions(this) ||
            runCatching { startForegroundService(intent) }.isFailure
        ) {
            Toast.makeText(this, R.string.ble_permission_required_toast, Toast.LENGTH_LONG).show()
            finish()
            return
        }

        Toast.makeText(this, "Pairing…", Toast.LENGTH_SHORT).show()
        setResult(RESULT_OK)
        finish()
    }

    companion object {
        const val EXTRA_SCAN_FROM_IMAGE = "scan_from_image"

        /**
         * FEATURE_CAMERA_ANY alone can't be trusted: some devices (e.g. the AYN Thor
         * handheld) report it while exposing zero actual cameras, so also check that
         * the camera service knows about at least one device.
         */
        fun deviceHasCamera(context: Context): Boolean {
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
                return false
            }
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            return runCatching { manager.cameraIdList.isNotEmpty() }.getOrDefault(true)
        }
    }
}

// ─── Pair-from-image screen ──────────────────────────────────────────────────
@Composable
private fun ImagePairingScreen(
    errorRes: Int?,
    decoding: Boolean,
    onChooseImageClick: () -> Unit,
    onCancelClick: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFE8F5F3))
            .systemBarsPadding()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Column(
            modifier = Modifier.widthIn(max = 400.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = stringResource(R.string.pair_from_image_title),
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = Teal
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(R.string.pair_from_image_instructions),
                fontSize = 14.sp,
                color = Color(0x99000000),
                textAlign = TextAlign.Center,
                lineHeight = 20.sp
            )
            if (errorRes != null) {
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = stringResource(errorRes),
                    color = Color(0xFFB71C1C),
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    lineHeight = 18.sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(18.dp))
                        .background(Color(0x14FF5252))
                        .border(1.dp, Color(0x29FF5252), RoundedCornerShape(18.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                )
            }
            Spacer(modifier = Modifier.height(20.dp))
            Button(
                onClick = onChooseImageClick,
                enabled = !decoding,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(28.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Aqua,
                    contentColor = Teal
                )
            ) {
                if (decoding) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = Teal
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                }
                Text(
                    text = stringResource(
                        if (decoding) R.string.pair_from_image_decoding
                        else R.string.pair_from_image_choose
                    ),
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(vertical = 4.dp)
                )
            }
            TextButton(onClick = onCancelClick) {
                Text(
                    text = stringResource(R.string.pair_from_image_cancel),
                    color = Teal.copy(alpha = 0.6f),
                    fontSize = 13.sp
                )
            }
        }
    }
}
