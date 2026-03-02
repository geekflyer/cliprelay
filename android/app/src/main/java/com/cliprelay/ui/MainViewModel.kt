package com.cliprelay.ui

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class AppState {
    object Unpaired : AppState()
    data class Searching(val deviceName: String? = null) : AppState()
    data class Connected(val deviceName: String?) : AppState()
}

class MainViewModel : ViewModel() {
    private val _state = MutableStateFlow<AppState>(AppState.Unpaired)
    val state: StateFlow<AppState> = _state.asStateFlow()

    private val _showBurst = MutableStateFlow(false)
    val showBurst: StateFlow<Boolean> = _showBurst.asStateFlow()

    private val _autoClearEnabled = MutableStateFlow(false)
    val autoClearEnabled: StateFlow<Boolean> = _autoClearEnabled.asStateFlow()

    // Emits true = Mac→Android, false = Android→Mac
    private val _clipboardTransfer = MutableSharedFlow<Boolean>(extraBufferCapacity = 1)
    val clipboardTransfer: SharedFlow<Boolean> = _clipboardTransfer

    fun initState(isPaired: Boolean, deviceName: String? = null, autoClearEnabled: Boolean = false) {
        _state.value = if (isPaired) AppState.Searching(deviceName) else AppState.Unpaired
        _autoClearEnabled.value = autoClearEnabled
    }

    fun onPaired() {
        _state.value = AppState.Searching()
        _showBurst.value = true
    }

    fun onBurstShown() {
        _showBurst.value = false
    }

    fun onUnpaired() {
        _state.value = AppState.Unpaired
    }

    fun onConnectionChanged(connected: Boolean, deviceName: String?) {
        // Don't let stale connection broadcasts override the Unpaired state.
        if (_state.value is AppState.Unpaired) return
        _state.value = if (connected) AppState.Connected(deviceName) else AppState.Searching(deviceName)
    }

    fun onClipboardTransfer(fromMac: Boolean) {
        _clipboardTransfer.tryEmit(fromMac)
    }

    fun onAutoClearSettingChanged(enabled: Boolean) {
        _autoClearEnabled.value = enabled
    }
}
