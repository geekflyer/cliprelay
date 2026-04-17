package org.cliprelay.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class MainViewModelTest {
    @Test
    fun onConnectionChanged_preservesExistingNameWhenBroadcastOmitsIt() {
        val viewModel = MainViewModel()
        viewModel.initState(isPaired = true, deviceName = "Chen's MacBook Pro", deviceTag = "9A93 227C")

        viewModel.onConnectionChanged(connected = false, deviceName = null)

        assertEquals(
            AppState.Searching(deviceName = "Chen's MacBook Pro", deviceTag = "9A93 227C"),
            viewModel.state.value
        )
    }

    @Test
    fun onConnectionChanged_updatesConnectedStateWithoutDroppingKnownName() {
        val viewModel = MainViewModel()
        viewModel.onPaired(deviceName = "Chen's MacBook Pro", deviceTag = "9A93 227C")

        viewModel.onConnectionChanged(connected = true, deviceName = null)

        assertEquals(
            AppState.Connected(deviceName = "Chen's MacBook Pro", deviceTag = "9A93 227C"),
            viewModel.state.value
        )
    }
}
