package org.cliprelay.ui

// Main activity: handles permissions, QR scanning results, and hosts the Compose UI.

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import org.cliprelay.R
import org.cliprelay.feedback.LogShareExporter
import org.cliprelay.pairing.PairingStore
import org.cliprelay.permissions.BlePermissions
import org.cliprelay.review.ReviewPromptStore
import org.cliprelay.service.ClipboardAccessibilityService
import org.cliprelay.service.ClipRelayService
import org.cliprelay.settings.ClipboardSettingsStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {

    private val viewModel: MainViewModel by viewModels()
    private lateinit var clipboardSettingsStore: ClipboardSettingsStore
    private val reviewPromptStore by lazy { ReviewPromptStore(this) }

    // Pairing is gated on the BLE ("Nearby devices") runtime permission: without it
    // the connectedDevice foreground service cannot start and pairing would fail.
    private var showBlePermissionDialog by mutableStateOf(false)
    private var blePermissionPermanentlyDenied by mutableStateOf(false)

    // Play In-App Updates (immediate flow): Play runs the whole update fullscreen —
    // download, install, automatic app restart — so the user never keeps using a
    // stale version after accepting. BootCompletedReceiver restarts the sync
    // service after the install.
    private val appUpdateManager by lazy { AppUpdateManagerFactory.create(this) }
    private val updateFlowLauncher = registerForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult()
    ) { /* User accepted or declined Play's update screen — nothing to do either way. */ }

    private val connectionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ClipRelayService.ACTION_CONNECTION_STATE -> {
                    val connectedIds =
                        intent.getStringArrayListExtra(ClipRelayService.EXTRA_CONNECTED_IDS)
                            ?: arrayListOf()
                    viewModel.onMacsChanged(loadMacsForUi(connectedIds.toSet()))
                }
                ClipRelayService.ACTION_PAIRING_COMPLETE -> {
                    viewModel.onPaired(loadMacsForUi(emptySet()))
                    requestBatteryOptimizationAndOnboarding()
                }
                ClipRelayService.ACTION_PAIRING_STATUS -> {
                    when (intent.getStringExtra(ClipRelayService.EXTRA_PAIRING_STAGE)) {
                        ClipRelayService.PAIRING_STAGE_CONNECTING ->
                            viewModel.onPairingStatus(PairingStage.Connecting)
                        ClipRelayService.PAIRING_STAGE_EXCHANGING_KEYS ->
                            viewModel.onPairingStatus(PairingStage.ExchangingKeys)
                        ClipRelayService.PAIRING_STAGE_FAILED ->
                            viewModel.onPairingFailed()
                    }
                }
                ClipRelayService.ACTION_CLIPBOARD_TRANSFER -> {
                    val fromMac = intent.getBooleanExtra(ClipRelayService.EXTRA_FROM_MAC, true)
                    viewModel.onClipboardTransfer(fromMac)
                    maybeAskForReview()
                }
                ClipRelayService.ACTION_VERSION_MISMATCH -> {
                    viewModel.onVersionMismatch()
                }
                ClipRelayService.ACTION_RICH_MEDIA_SETTING_CHANGED -> {
                    val enabled = intent.getBooleanExtra(ClipRelayService.EXTRA_RICH_MEDIA_ENABLED, false)
                    viewModel.onImageSyncSettingChanged(enabled)
                }
            }
        }
    }

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        ensureServiceRunning()
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    // Set when a cliprelay://pair deep link arrives before BLE permission is granted, so the
    // post-grant callback resumes pairing from the link instead of opening the camera scanner.
    private var pendingDeepLinkInfo: org.cliprelay.pairing.PairingInfo? = null

    private val pairPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        if (BlePermissions.hasRequiredRuntimePermissions(this)) {
            ensureServiceRunning()
            val deepLink = pendingDeepLinkInfo
            if (deepLink != null) {
                pendingDeepLinkInfo = null
                startPairingFromInfo(deepLink)
            } else {
                launchQrScanner()
            }
        } else {
            // Denied again — re-show the explanation. If Android will no longer
            // show the system prompt, the dialog routes to app settings instead.
            blePermissionPermanentlyDenied = BlePermissions.requiredRuntimePermissions()
                .none { shouldShowRequestPermissionRationale(it) }
            showBlePermissionDialog = true
        }
    }

    private val scannerLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            // The service broadcasts pairing progress (CONNECTING → EXCHANGING_KEYS →
            // PAIRING_COMPLETE/FAILED); set Connecting optimistically since the
            // CONNECTING broadcast may fire before this activity resumes.
            viewModel.onPairingStarted()
        }
    }

    private val batteryOptLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        // Battery optimization dialog dismissed — now show onboarding
        launchOnboardingIfNeeded()
    }

    private val onboardingLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) {
            // Refresh auto-copy state after onboarding
            viewModel.onAutoCopySettingChanged(clipboardSettingsStore.isAutoCopyEnabled())
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableLightEdgeToEdge()

        requestRuntimePermissions()
        ensureServiceRunning()
        clipboardSettingsStore = ClipboardSettingsStore(this)

        // Second review-prompt trigger: the app has been open for a while (syncs that
        // satisfied the gate may all have happened in the background). Cancelled on
        // pause, restarted on resume, so it's 15s of continuous foreground time.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                delay(15_000)
                if (reviewPromptAllowedNow()) {
                    reviewPromptStore.maybeLaunchReviewFlow(this@MainActivity)
                }
            }
        }

        val pairingStore = PairingStore(this)
        val autoClearEnabled = clipboardSettingsStore.isAutoClearSyncedClipboardEnabled()
        val autoCopyEnabled = clipboardSettingsStore.isAutoCopyEnabled()
        val imageSyncEnabled = pairingStore.isRichMediaEnabled()
        val hideClipboardEnabled = clipboardSettingsStore.isHideSyncedClipboardEnabled()
        viewModel.initState(loadMacsForUi(emptySet()), autoClearEnabled, autoCopyEnabled, imageSyncEnabled, hideClipboardEnabled)

        setContent {
            val state by viewModel.state.collectAsState()
            val showBurst by viewModel.showBurst.collectAsState()
            val autoClearEnabled by viewModel.autoClearEnabled.collectAsState()
            val hideClipboardEnabled by viewModel.hideClipboardEnabled.collectAsState()
            val autoCopyEnabled by viewModel.autoCopyEnabled.collectAsState()
            val autoCopyAccessibilityEnabled by viewModel.autoCopyAccessibilityEnabled.collectAsState()
            val imageSyncEnabled by viewModel.imageSyncEnabled.collectAsState()
            val showVersionMismatch by viewModel.showVersionMismatch.collectAsState()
            val pairingFailed by viewModel.pairingFailed.collectAsState()
            var showAccessibilityDisclosure by remember { mutableStateOf(false) }

            if (showVersionMismatch) {
                VersionMismatchDialog(onDismiss = { viewModel.onVersionMismatchDismissed() })
            }

            if (showBlePermissionDialog) {
                BlePermissionDialog(
                    permanentlyDenied = blePermissionPermanentlyDenied,
                    onContinue = {
                        showBlePermissionDialog = false
                        if (blePermissionPermanentlyDenied) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        } else {
                            pairPermissionLauncher.launch(
                                BlePermissions.requiredRuntimePermissions().toTypedArray()
                            )
                        }
                    },
                    onCancel = { showBlePermissionDialog = false }
                )
            }

            if (showAccessibilityDisclosure) {
                AccessibilityDisclosureDialog(
                    onAllow = {
                        showAccessibilityDisclosure = false
                        viewModel.onAutoCopySettingChanged(true)
                        clipboardSettingsStore.setAutoCopyEnabled(true)
                        startActivity(Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    },
                    onDeny = {
                        showAccessibilityDisclosure = false
                        viewModel.onAutoCopySettingChanged(false)
                        clipboardSettingsStore.setAutoCopyEnabled(false)
                    }
                )
            }

            ClipRelayScreen(
                state = state,
                showBurst = showBurst,
                clipboardTransferFlow = viewModel.clipboardTransfer,
                autoClearEnabled = autoClearEnabled,
                hideClipboardEnabled = hideClipboardEnabled,
                autoCopyEnabled = autoCopyEnabled,
                autoCopyAccessibilityEnabled = autoCopyAccessibilityEnabled,
                imageSyncEnabled = imageSyncEnabled,
                pairingFailed = pairingFailed,
                onPairingCancelClick = {
                    viewModel.onPairingCancelled()
                    val cancelIntent = Intent(this, ClipRelayService::class.java)
                    cancelIntent.action = ClipRelayService.ACTION_CANCEL_PAIRING
                    startServiceSafely(cancelIntent)
                },
                onPairingErrorDismiss = {
                    viewModel.onPairingFailedDismissed()
                },
                onPairClick = {
                    if (BlePermissions.hasRequiredRuntimePermissions(this)) {
                        launchQrScanner()
                    } else {
                        blePermissionPermanentlyDenied =
                            BlePermissions.requiredRuntimePermissions()
                                .none { shouldShowRequestPermissionRationale(it) }
                        showBlePermissionDialog = true
                    }
                },
                onForgetMacClick = { macId ->
                    val forgetIntent = Intent(this, ClipRelayService::class.java)
                    forgetIntent.action = ClipRelayService.ACTION_FORGET_DEVICE
                    forgetIntent.putExtra(ClipRelayService.EXTRA_DEVICE_ID, macId)
                    if (!startServiceSafely(forgetIntent)) {
                        // Service unavailable (e.g. missing BLE permissions) — remove directly.
                        val store = PairingStore(this)
                        store.loadPairedMacs().firstOrNull { it.id == macId }
                            ?.let { store.removePairedMac(it.secretHex) }
                    }
                    // The service removes the pairing asynchronously — drop it
                    // from the UI immediately rather than waiting for the broadcast.
                    viewModel.onMacForgotten(loadMacsForUi(emptySet()).filterNot { it.id == macId })
                },
                onBurstShown = {
                    viewModel.onBurstShown()
                },
                onAutoClearSettingChanged = { enabled ->
                    viewModel.onAutoClearSettingChanged(enabled)
                    clipboardSettingsStore.setAutoClearSyncedClipboardEnabled(enabled)
                },
                onHideClipboardSettingChanged = { enabled ->
                    viewModel.onHideClipboardSettingChanged(enabled)
                    clipboardSettingsStore.setHideSyncedClipboardEnabled(enabled)
                },
                onAutoCopySettingChanged = { enabled ->
                    if (enabled && !isAccessibilityServiceEnabled()) {
                        showAccessibilityDisclosure = true
                    } else {
                        viewModel.onAutoCopySettingChanged(enabled)
                        clipboardSettingsStore.setAutoCopyEnabled(enabled)
                    }
                },
                onImageSyncSettingChanged = { enabled ->
                    viewModel.onImageSyncSettingChanged(enabled)
                    PairingStore(this).setRichMediaEnabled(enabled, System.currentTimeMillis() / 1000)
                    val configIntent = Intent(this, ClipRelayService::class.java)
                    configIntent.action = ClipRelayService.ACTION_SEND_CONFIG_UPDATE
                    startServiceSafely(configIntent)
                },
                onAutoCopyFixClick = {
                    showAccessibilityDisclosure = true
                },
                onHelpClick = {
                    onboardingLauncher.launch(Intent(this, AutoCopyOnboardingActivity::class.java))
                },
                onSupportLinkClick = { url ->
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    } catch (e: ActivityNotFoundException) {
                        Toast.makeText(this, "No app available to open this link", Toast.LENGTH_SHORT).show()
                    }
                },
                onShareLogsClick = { bleState ->
                    shareLogs(bleState)
                },
            )
        }

        // A cliprelay://pair link may have launched us (e.g. from a system QR scanner).
        if (savedInstanceState == null) handlePairingDeepLink(intent)

        // savedInstanceState guard: don't re-show Play's update screen on rotation.
        if (savedInstanceState == null) checkForAppUpdate(resumeOnly = false)
    }

    /**
     * Start (or, on resume, re-attach to) Play's immediate update flow. With
     * [resumeOnly], only re-enter a flow the user already accepted — never start
     * a new prompt, so backing out of the update isn't met with an instant re-ask.
     * On failure (no Play Store, offline): stays silent.
     */
    private fun checkForAppUpdate(resumeOnly: Boolean) {
        appUpdateManager.appUpdateInfo.addOnSuccessListener { info ->
            val shouldLaunch = when (info.updateAvailability()) {
                UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS -> true
                UpdateAvailability.UPDATE_AVAILABLE ->
                    !resumeOnly && info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)
                else -> false
            }
            if (shouldLaunch) {
                appUpdateManager.startUpdateFlowForResult(
                    info,
                    updateFlowLauncher,
                    AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE)
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingDeepLink(intent)
    }

    override fun onResume() {
        super.onResume()
        // If the user backed out mid-install (e.g. switched apps during Play's
        // update screen), re-attach to the in-progress update.
        checkForAppUpdate(resumeOnly = true)
        val filter = IntentFilter(ClipRelayService.ACTION_CONNECTION_STATE).also {
            it.addAction(ClipRelayService.ACTION_PAIRING_COMPLETE)
            it.addAction(ClipRelayService.ACTION_PAIRING_STATUS)
            it.addAction(ClipRelayService.ACTION_CLIPBOARD_TRANSFER)
            it.addAction(ClipRelayService.ACTION_VERSION_MISMATCH)
            it.addAction(ClipRelayService.ACTION_RICH_MEDIA_SETTING_CHANGED)
        }
        ContextCompat.registerReceiver(
            this,
            connectionReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        viewModel.onAccessibilityStateChanged(isAccessibilityServiceEnabled())
        viewModel.onImageSyncSettingChanged(PairingStore(this).isRichMediaEnabled())
        val queryIntent = Intent(this, ClipRelayService::class.java)
        queryIntent.action = ClipRelayService.ACTION_QUERY_CONNECTION
        startServiceSafely(queryIntent)
    }

    override fun onPause() {
        super.onPause()
        unregisterReceiver(connectionReceiver)
    }

    /**
     * Ask for a Play Store review right after a successful sync (the user just saw
     * the app work), if the [ReviewPromptStore] gate allows. Delayed slightly so the
     * transfer beam animation finishes before the dialog appears.
     */
    private fun maybeAskForReview() {
        lifecycleScope.launch {
            delay(1_500)
            if (reviewPromptAllowedNow()) {
                reviewPromptStore.maybeLaunchReviewFlow(this@MainActivity)
            }
        }
    }

    /** UI-state guard shared by both review triggers: never prompt over an in-progress pairing. */
    private fun reviewPromptAllowedNow(): Boolean =
        lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
            viewModel.state.value !is AppState.Pairing

    /** Read the paired Macs from the store and apply per-Mac connection flags. */
    private fun loadMacsForUi(connectedIds: Set<String>): List<PairedMacUi> =
        PairingStore(this).loadPairedMacs().map { mac ->
            PairedMacUi(id = mac.id, name = mac.name, connected = mac.id in connectedIds)
        }

    private fun launchQrScanner() {
        scannerLauncher.launch(Intent(this, QrScannerActivity::class.java))
    }

    /**
     * Handle a cliprelay://pair?k=…&n=… deep link (e.g. opened from a regular QR scanner).
     * Consumes the intent's data so a config-change recreate doesn't re-trigger pairing.
     */
    private fun handlePairingDeepLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val info = intent.data?.toString()?.let { org.cliprelay.pairing.PairingUriParser.parse(it) }
        intent.data = null
        if (info == null) return
        if (BlePermissions.hasRequiredRuntimePermissions(this)) {
            startPairingFromInfo(info)
        } else {
            pendingDeepLinkInfo = info
            blePermissionPermanentlyDenied = BlePermissions.requiredRuntimePermissions()
                .none { shouldShowRequestPermissionRationale(it) }
            showBlePermissionDialog = true
        }
    }

    /** Store the Mac's key/name and signal the service to begin pairing — same path as the scanner. */
    private fun startPairingFromInfo(info: org.cliprelay.pairing.PairingInfo) {
        getSharedPreferences(ClipRelayService.PREFS_NAME, MODE_PRIVATE).edit()
            .putString("pending_pairing_pubkey", info.publicKeyHex)
            .putString(ClipRelayService.KEY_PENDING_PAIRING_NAME, info.deviceName ?: "")
            .apply()
        val pairIntent = Intent(this, ClipRelayService::class.java).apply {
            action = ClipRelayService.ACTION_START_PAIRING
        }
        if (startServiceSafely(pairIntent)) {
            viewModel.onPairingStarted()
            Toast.makeText(this, "Pairing…", Toast.LENGTH_SHORT).show()
        }
    }

    private fun ensureServiceRunning() {
        startServiceSafely(Intent(this, ClipRelayService::class.java))
    }

    private fun startServiceSafely(intent: Intent): Boolean {
        if (!BlePermissions.hasRequiredRuntimePermissions(this)) return false
        val started = runCatching {
            ContextCompat.startForegroundService(this, intent)
        }.isSuccess
        if (!started) {
            Toast.makeText(this, "Could not start ClipRelay service", Toast.LENGTH_SHORT).show()
        }
        return started
    }

    private fun requestBatteryOptimizationAndOnboarding() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) {
            // Already exempt — go straight to onboarding
            launchOnboardingIfNeeded()
            return
        }

        // Launch battery optimization dialog; onboarding follows in the result callback
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        batteryOptLauncher.launch(intent)
    }

    private fun launchOnboardingIfNeeded() {
        if (clipboardSettingsStore.isAutoCopyOnboardingShown()) return
        onboardingLauncher.launch(Intent(this, AutoCopyOnboardingActivity::class.java))
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val service = "${packageName}/${ClipboardAccessibilityService::class.java.canonicalName}"
        val enabledServices = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabledServices.contains(service)
    }

    private fun requestRuntimePermissions() {
        val permissions = BlePermissions.requiredRuntimePermissions().toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (permissions.isEmpty()) return
        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        }
    }

    private fun shareLogs(bleState: String) {
        // lifecycleScope auto-cancels if the activity is destroyed during the
        // capture, so the UI callback never touches a finishing activity.
        lifecycleScope.launch(Dispatchers.IO) {
            val result = runCatching {
                LogShareExporter.createShareIntent(applicationContext, bleState)
            }
            withContext(Dispatchers.Main) {
                result.onSuccess { shareIntent ->
                    val chooser = Intent.createChooser(
                        shareIntent,
                        getString(R.string.share_logs_chooser_title)
                    )
                    startActivity(chooser)
                }.onFailure { error ->
                    val reason = error.message ?: error.javaClass.simpleName
                    Toast.makeText(
                        this@MainActivity,
                        getString(R.string.share_logs_failed, reason),
                        Toast.LENGTH_LONG
                    ).show()
                }
            }
        }
    }
}
