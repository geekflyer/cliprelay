package com.clipshare.ui

import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.clipshare.pairing.PairingStore
import com.clipshare.pairing.PairingUriParser
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode

class QrScannerActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchScanner()
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
                finish()
            }
            .addOnFailureListener { e ->
                Toast.makeText(this, "Scan failed: ${e.message}", Toast.LENGTH_SHORT).show()
                finish()
            }
    }

    private fun handleScannedValue(rawValue: String) {
        val token = PairingUriParser.parse(rawValue)
        if (token == null) {
            Toast.makeText(this, "Invalid pairing QR code", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        val store = PairingStore(this)
        store.saveToken(token)
        Toast.makeText(this, "Paired successfully!", Toast.LENGTH_SHORT).show()

        setResult(RESULT_OK)
        finish()
    }
}
