package org.cliprelay.ui

// Launches the ML Kit barcode scanner for QR-based pairing with the Mac app.

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import org.cliprelay.R
import org.cliprelay.pairing.PairingStore
import org.cliprelay.pairing.PairingUriParser
import org.cliprelay.service.ClipRelayService
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode

class QrScannerActivity : AppCompatActivity() {
    companion object {
        private const val MODULE_RETRY_DELAY_MS = 1_500L
        private const val MAX_MODULE_RETRIES = 20
    }

    private val handler = Handler(Looper.getMainLooper())
    private var moduleRetryCount = 0

    private lateinit var loadingTitle: TextView
    private lateinit var loadingSubtitle: TextView
    private lateinit var loadingRetry: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_qr_scanner_loading)
        loadingTitle = findViewById(R.id.qrLoadingTitle)
        loadingSubtitle = findViewById(R.id.qrLoadingSubtitle)
        loadingRetry = findViewById(R.id.qrLoadingRetry)
        launchScanner()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun launchScanner() {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()

        val scanner = GmsBarcodeScanning.getClient(this, options)
        scanner.startScan()
            .addOnSuccessListener { barcode ->
                val rawValue = barcode.rawValue
                if (rawValue != null) {
                    handleScannedValue(rawValue)
                } else {
                    Toast.makeText(this, "No data in QR code", Toast.LENGTH_SHORT).show()
                    finish()
                }
            }
            .addOnCanceledListener {
                handler.removeCallbacksAndMessages(null)
                finish()
            }
            .addOnFailureListener { e ->
                if (isBarcodeModulePendingError(e)) {
                    retryWhenBarcodeModuleReady()
                    return@addOnFailureListener
                }
                Toast.makeText(this, "Scan failed: ${e.message}", Toast.LENGTH_SHORT).show()
                finish()
            }
    }

    private fun retryWhenBarcodeModuleReady() {
        loadingTitle.text = getString(R.string.qr_loading_title)
        loadingSubtitle.text = getString(R.string.qr_loading_subtitle)

        if (moduleRetryCount >= MAX_MODULE_RETRIES) {
            Toast.makeText(
                this,
                getString(R.string.qr_module_still_downloading),
                Toast.LENGTH_LONG
            ).show()
            finish()
            return
        }

        moduleRetryCount += 1
        loadingRetry.text = getString(R.string.qr_loading_retry, moduleRetryCount, MAX_MODULE_RETRIES)
        loadingRetry.visibility = View.VISIBLE
        handler.postDelayed({ launchScanner() }, MODULE_RETRY_DELAY_MS)
    }

    private fun isBarcodeModulePendingError(error: Exception): Boolean {
        val message = error.message ?: return false
        return message.contains("barcode module", ignoreCase = true) &&
            message.contains("download", ignoreCase = true)
    }

    private fun handleScannedValue(rawValue: String) {
        val info = PairingUriParser.parse(rawValue)
        if (info == null) {
            Toast.makeText(this, "Invalid pairing QR code", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        val stored = runCatching {
            if (!PairingStore(this).saveToken(info.token)) return@runCatching false

            if (info.deviceName != null) {
                getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE)
                    .edit()
                    .putString(ClipRelayService.KEY_CONNECTED_DEVICE, info.deviceName)
                    .apply()
            }
            true
        }.getOrDefault(false)

        if (!stored) {
            Toast.makeText(this, "Pairing failed. Please try again.", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        Toast.makeText(this, "Paired successfully!", Toast.LENGTH_SHORT).show()
        setResult(RESULT_OK)
        finish()
    }
}
