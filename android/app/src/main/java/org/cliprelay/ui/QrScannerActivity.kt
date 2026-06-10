package org.cliprelay.ui

// QR-based pairing scanner built on Quickie (CameraX + bundled ML Kit), so pairing works
// without Google Play services. The old GMS code scanner needed an on-demand "barcode module"
// download that could stall forever, leaving pairing stuck (issue #56).

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import io.github.g00fy2.quickie.QRResult
import io.github.g00fy2.quickie.ScanCustomCode
import io.github.g00fy2.quickie.config.BarcodeFormat
import io.github.g00fy2.quickie.config.ScannerConfig
import org.cliprelay.R
import org.cliprelay.pairing.PairingUriParser
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Launch once; avoid relaunching if the activity is recreated while the scanner is open.
        if (savedInstanceState == null) {
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
        startForegroundService(intent)

        Toast.makeText(this, "Pairing…", Toast.LENGTH_SHORT).show()
        setResult(RESULT_OK)
        finish()
    }
}
