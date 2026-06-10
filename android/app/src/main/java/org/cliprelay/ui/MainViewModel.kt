package org.cliprelay.ui

// ViewModel exposing app state (pairing, per-Mac connection, transfer events) to the Compose UI.

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class PairingStage { Connecting, ExchangingKeys }

/** One paired Mac as shown in the UI. [id] is PairedMac.id (device-tag hex). */
data class PairedMacUi(
    val id: String,
    val name: String?,
    val connected: Boolean = false
) {
    /** Short human-checkable pairing code, e.g. "AB12 CD34". */
    val tagDisplay: String get() = id.take(8).uppercase().chunked(4).joinToString(" ")
}

sealed class AppState {
    object Unpaired : AppState()
    data class Pairing(val stage: PairingStage) : AppState()
    data class Paired(val macs: List<PairedMacUi>) : AppState() {
        val anyConnected: Boolean get() = macs.any { it.connected }
        val connectedCount: Int get() = macs.count { it.connected }
    }
}

class MainViewModel : ViewModel() {
    private val _state = MutableStateFlow<AppState>(AppState.Unpaired)
    val state: StateFlow<AppState> = _state.asStateFlow()

    /** Last known paired Macs (with connection flags), kept across Pairing state. */
    private var macs: List<PairedMacUi> = emptyList()

    private val _showBurst = MutableStateFlow(false)
    val showBurst: StateFlow<Boolean> = _showBurst.asStateFlow()

    private val _autoClearEnabled = MutableStateFlow(false)
    val autoClearEnabled: StateFlow<Boolean> = _autoClearEnabled.asStateFlow()

    private val _autoCopyEnabled = MutableStateFlow(false)
    val autoCopyEnabled: StateFlow<Boolean> = _autoCopyEnabled.asStateFlow()

    private val _imageSyncEnabled = MutableStateFlow(false)
    val imageSyncEnabled: StateFlow<Boolean> = _imageSyncEnabled.asStateFlow()

    private val _autoCopyAccessibilityEnabled = MutableStateFlow(false)
    val autoCopyAccessibilityEnabled: StateFlow<Boolean> = _autoCopyAccessibilityEnabled.asStateFlow()

    private val _showVersionMismatch = MutableStateFlow(false)
    val showVersionMismatch: StateFlow<Boolean> = _showVersionMismatch.asStateFlow()

    private val _pairingFailed = MutableStateFlow(false)
    val pairingFailed: StateFlow<Boolean> = _pairingFailed.asStateFlow()

    // Emits true = Mac→Android, false = Android→Mac
    private val _clipboardTransfer = MutableSharedFlow<Boolean>(extraBufferCapacity = 1)
    val clipboardTransfer: SharedFlow<Boolean> = _clipboardTransfer

    fun initState(
        macs: List<PairedMacUi>,
        autoClearEnabled: Boolean = false,
        autoCopyEnabled: Boolean = false,
        imageSyncEnabled: Boolean = false
    ) {
        this.macs = macs
        refreshPairedState()
        _autoClearEnabled.value = autoClearEnabled
        _autoCopyEnabled.value = autoCopyEnabled
        _imageSyncEnabled.value = imageSyncEnabled
    }

    /** Paired list or per-Mac connection flags changed (store re-read / connection broadcast). */
    fun onMacsChanged(macs: List<PairedMacUi>) {
        this.macs = macs
        // Don't let connection broadcasts kick us out of an in-progress pairing.
        if (_state.value is AppState.Pairing) return
        refreshPairedState()
    }

    fun onPaired(macs: List<PairedMacUi>) {
        this.macs = macs
        refreshPairedState()
        _pairingFailed.value = false
        _showBurst.value = true
    }

    fun onPairingStarted() {
        _state.value = AppState.Pairing(PairingStage.Connecting)
        _pairingFailed.value = false
    }

    fun onPairingStatus(stage: PairingStage) {
        if (_state.value !is AppState.Pairing) return
        _state.value = AppState.Pairing(stage)
    }

    fun onPairingFailed() {
        if (_state.value !is AppState.Pairing) return
        refreshPairedState()
        _pairingFailed.value = true
    }

    fun onPairingCancelled() {
        refreshPairedState()
        _pairingFailed.value = false
    }

    fun onPairingFailedDismissed() {
        _pairingFailed.value = false
    }

    fun onBurstShown() {
        _showBurst.value = false
    }

    fun onUnpaired() {
        macs = emptyList()
        _state.value = AppState.Unpaired
        _autoCopyEnabled.value = false
    }

    fun onMacForgotten(remaining: List<PairedMacUi>) {
        macs = remaining
        refreshPairedState()
        if (remaining.isEmpty()) {
            _autoCopyEnabled.value = false
        }
    }

    private fun refreshPairedState() {
        _state.value = if (macs.isEmpty()) AppState.Unpaired else AppState.Paired(macs)
    }

    fun onClipboardTransfer(fromMac: Boolean) {
        _clipboardTransfer.tryEmit(fromMac)
    }

    fun onAutoClearSettingChanged(enabled: Boolean) {
        _autoClearEnabled.value = enabled
    }

    fun onAutoCopySettingChanged(enabled: Boolean) {
        _autoCopyEnabled.value = enabled
    }

    fun onImageSyncSettingChanged(enabled: Boolean) {
        _imageSyncEnabled.value = enabled
    }

    fun onAccessibilityStateChanged(enabled: Boolean) {
        _autoCopyAccessibilityEnabled.value = enabled
    }

    fun onVersionMismatch() {
        _showVersionMismatch.value = true
    }

    fun onVersionMismatchDismissed() {
        _showVersionMismatch.value = false
    }
}
