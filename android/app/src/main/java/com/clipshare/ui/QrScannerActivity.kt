package com.clipshare.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.appcompat.app.AppCompatActivity
import com.clipshare.R
import com.clipshare.pairing.PairingStore
import com.clipshare.pairing.PairingUriParser
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class QrScannerActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_SERVICE_UUID = "extra_service_uuid"
    }

    private lateinit var previewView: PreviewView
    private lateinit var statusText: TextView
    private lateinit var analysisExecutor: ExecutorService
    private val barcodeScanner by lazy {
        BarcodeScanning.getClient(
            com.google.mlkit.vision.barcode.BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build()
        )
    }

    @Volatile
    private var handledResult = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_qr_scanner)

        previewView = findViewById(R.id.previewView)
        statusText = findViewById(R.id.scannerStatusText)
        analysisExecutor = Executors.newSingleThreadExecutor()

        findViewById<Button>(R.id.closeScannerButton).setOnClickListener {
            finish()
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            statusText.text = getString(R.string.camera_permission_required)
            return
        }

        bindCamera()
    }

    override fun onDestroy() {
        barcodeScanner.close()
        analysisExecutor.shutdown()
        super.onDestroy()
    }

    private fun bindCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener(
            {
                val cameraProvider = cameraProviderFuture.get()

                val preview = Preview.Builder().build().apply {
                    surfaceProvider = previewView.surfaceProvider
                }

                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()

                analysis.setAnalyzer(analysisExecutor, ::analyzeFrame)

                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis
                )
            },
            ContextCompat.getMainExecutor(this)
        )
    }

    private fun analyzeFrame(imageProxy: ImageProxy) {
        if (handledResult) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val inputImage = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

        barcodeScanner.process(inputImage)
            .addOnSuccessListener { barcodes ->
                val rawValue = barcodes.firstNotNullOfOrNull { it.rawValue }
                if (!rawValue.isNullOrBlank()) {
                    onQrDetected(rawValue)
                }
            }
            .addOnFailureListener {
                statusText.text = getString(R.string.qr_scan_failed)
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    }

    private fun onQrDetected(rawValue: String) {
        if (handledResult) {
            return
        }

        val pairingPayload = PairingUriParser.parse(rawValue)
        if (pairingPayload == null) {
            statusText.text = getString(R.string.invalid_pairing_qr)
            return
        }

        handledResult = true
        PairingStore(this).save(pairingPayload)
        statusText.text = getString(R.string.pairing_saved)

        val data = Intent().putExtra(EXTRA_SERVICE_UUID, pairingPayload.serviceUUID)
        setResult(RESULT_OK, data)
        finish()
    }
}
