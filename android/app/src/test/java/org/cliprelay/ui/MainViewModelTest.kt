package org.cliprelay.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainViewModelTest {

    private val macA = PairedMacUi(id = "aabbccdd00112233", name = "Mac A")
    private val macB = PairedMacUi(id = "eeff445566778899", name = "Mac B")

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
        vm.initState(macs = listOf(macA))
        vm.onPairingStatus(PairingStage.ExchangingKeys)
        assertTrue(vm.state.value is AppState.Paired)
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
    fun pairingFailed_withExistingMacs_revertsToPairedAndSetsFlag() {
        val vm = MainViewModel()
        vm.initState(macs = listOf(macA))
        vm.onPairingStarted()
        vm.onPairingFailed()
        assertEquals(AppState.Paired(listOf(macA)), vm.state.value)
        assertTrue(vm.pairingFailed.value)
    }

    @Test
    fun pairingFailed_afterPairingComplete_isIgnored() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(listOf(macA))
        vm.onPairingFailed()
        assertTrue(vm.state.value is AppState.Paired)
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
        // Service answers ACTION_QUERY_CONNECTION with no connected Macs on resume
        vm.onMacsChanged(emptyList())
        assertEquals(AppState.Pairing(PairingStage.Connecting), vm.state.value)
    }

    @Test
    fun pairedThenConnected_reachesConnectedState() {
        val vm = MainViewModel()
        vm.onPairingStarted()
        vm.onPaired(listOf(macA))
        vm.onMacsChanged(listOf(macA.copy(connected = true)))
        val state = vm.state.value
        assertTrue(state is AppState.Paired && state.anyConnected)
    }

    @Test
    fun multipleMacs_partialConnection_reportsCounts() {
        val vm = MainViewModel()
        vm.initState(macs = listOf(macA, macB))
        vm.onMacsChanged(listOf(macA.copy(connected = true), macB))
        val state = vm.state.value as AppState.Paired
        assertTrue(state.anyConnected)
        assertEquals(1, state.connectedCount)
        assertEquals(2, state.macs.size)
    }

    @Test
    fun forgettingLastMac_returnsToUnpaired_andDisablesAutoCopy() {
        val vm = MainViewModel()
        vm.initState(macs = listOf(macA), autoCopyEnabled = true)
        vm.onMacForgotten(emptyList())
        assertEquals(AppState.Unpaired, vm.state.value)
        assertFalse(vm.autoCopyEnabled.value)
    }

    @Test
    fun forgettingOneOfTwoMacs_staysPaired() {
        val vm = MainViewModel()
        vm.initState(macs = listOf(macA, macB), autoCopyEnabled = true)
        vm.onMacForgotten(listOf(macB))
        assertEquals(AppState.Paired(listOf(macB)), vm.state.value)
        assertTrue(vm.autoCopyEnabled.value)
    }

    @Test
    fun tagDisplay_formatsFirstFourBytes() {
        assertEquals("AABB CCDD", macA.tagDisplay)
    }
}
