package org.cliprelay.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainViewModelTest {

    @Test
    fun pairingStarted_entersConnectingState_andClearsFailedFlag() {
        val vm = MainViewModel()
        vm.onPairingFailed() // not in Pairing state, so flag must stay false
        vm.onPairingStarted()
        assertEquals(AppState.Pairing(PairingStage.Connecting), vm.state.value)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingStatus_exchangingKeys_advancesStage() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingStatus(PairingStage.ExchangingKeys)
        assertEquals(AppState.Pairing(PairingStage.ExchangingKeys), vm.state.value)
    }

    @Test
    fun pairingStatus_ignoredWhenNotPairing() {
        val vm = MainViewModel()
        vm.initState(isPaired = true, deviceName = "Mac")
        vm.onPairingStatus(PairingStage.ExchangingKeys)
        assertTrue(vm.state.value is AppState.Searching)
    }

    @Test
    fun pairingFailed_whilePairing_revertsToUnpairedAndSetsFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingFailed()
        assertEquals(AppState.Unpaired, vm.state.value)
        assertTrue(vm.pairingFailed.value)
    }

    @Test
    fun pairingFailed_afterPairingComplete_isIgnored() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(deviceTag = "AB12 CD34")
        vm.onPairingFailed()
        assertTrue(vm.state.value is AppState.Searching)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingCancelled_revertsToUnpairedWithoutFailedFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingCancelled()
        assertEquals(AppState.Unpaired, vm.state.value)
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun pairingFailedDismissed_clearsFlag() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPairingFailed()
        vm.onPairingFailedDismissed()
        assertFalse(vm.pairingFailed.value)
    }

    @Test
    fun disconnectedBroadcast_doesNotKickOutOfPairingState() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        // Service answers ACTION_QUERY_CONNECTION with connected=false on resume
        vm.onConnectionChanged(connected = false, deviceName = null)
        assertEquals(AppState.Pairing(PairingStage.Connecting), vm.state.value)
    }

    @Test
    fun pairedThenConnected_reachesConnectedState() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(deviceTag = "AB12 CD34")
        vm.onConnectionChanged(connected = true, deviceName = "Mac")
        assertTrue(vm.state.value is AppState.Connected)
    }
}
