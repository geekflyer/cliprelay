package com.cliprelay.ui

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class AppState {
    object Unpaired : AppState()
    object Searching : AppState()
    data class Connected(val deviceName: String?) : AppState()
}

class MainViewModel : ViewModel() {
    private val _state = MutableStateFlow<AppState>(AppState.Unpaired)
    val state: StateFlow<AppState> = _state.asStateFlow()

    private val _showBurst = MutableStateFlow(false)
    val showBurst: StateFlow<Boolean> = _showBurst.asStateFlow()

    // Emits true = Mac→Android, false = Android→Mac
    private val _clipboardTransfer = MutableSharedFlow<Boolean>(extraBufferCapacity = 1)
    val clipboardTransfer: SharedFlow<Boolean> = _clipboardTransfer

    fun initState(isPaired: Boolean) {
        _state.value = if (isPaired) AppState.Searching else AppState.Unpaired
    }

    fun onPaired() {
        _state.value = AppState.Searching
        _showBurst.value = true
    }

    fun onBurstShown() {
        _showBurst.value = false
    }

    fun onUnpaired() {
        _state.value = AppState.Unpaired
    }

    fun onConnectionChanged(connected: Boolean, deviceName: String?) {
        _state.value = if (connected) AppState.Connected(deviceName) else AppState.Searching
    }

    fun onClipboardTransfer(fromMac: Boolean) {
        _clipboardTransfer.tryEmit(fromMac)
    }
}
