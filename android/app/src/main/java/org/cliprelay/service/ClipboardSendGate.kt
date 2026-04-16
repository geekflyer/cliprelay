package org.cliprelay.service

internal class ClipboardSendGate(
    private val nowMs: () -> Long = { System.currentTimeMillis() },
    private val suppressionWindowMs: Long = DEFAULT_SUPPRESSION_WINDOW_MS
) {
    private var lastSentHash: String? = null
    private var lastSentAtMs: Long = 0L

    fun shouldSend(hash: String): Boolean {
        val now = nowMs()
        if (hash == lastSentHash && now - lastSentAtMs < suppressionWindowMs) {
            return false
        }
        lastSentHash = hash
        lastSentAtMs = now
        return true
    }

    fun reset() {
        lastSentHash = null
        lastSentAtMs = 0L
    }

    companion object {
        const val DEFAULT_SUPPRESSION_WINDOW_MS = 1_500L
    }
}
