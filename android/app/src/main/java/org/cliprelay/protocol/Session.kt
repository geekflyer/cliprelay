package org.cliprelay.protocol

// Manages a single L2CAP protocol session: handshake, clipboard offer/accept, and payload transfer.

import org.cliprelay.crypto.E2ECrypto
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.security.PrivateKey
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

// ── Session Mode ──────────────────────────────────────────────────────

sealed class SessionMode {
    object Normal : SessionMode()
    class Pairing(
        val ownPrivateKey: PrivateKey,
        val ownPublicKeyRaw: ByteArray,
        val remotePublicKeyRaw: ByteArray
    ) : SessionMode()
}

/**
 * Session manages the L2CAP protocol conversation over a pair of streams.
 *
 * It handles:
 *   - Handshake (HELLO / WELCOME)
 *   - Outbound clipboard transfer (OFFER → ACCEPT → PAYLOAD → DONE)
 *   - Inbound clipboard transfer (OFFER → ACCEPT → PAYLOAD → DONE, with dedup)
 *   - Continuous message listening
 *
 * Session is single-use: once closed or errored, it cannot be reused.
 * Threading: call [listenForMessages] on a background thread. Use [sendClipboard]
 * from any thread — it queues the transfer for the listen loop to pick up.
 */
class Session(
    private val input: InputStream,
    private val output: OutputStream,
    private val isInitiator: Boolean,
    private val callback: SessionCallback,
    val mode: SessionMode = SessionMode.Normal,
    internal var handshakeTimeoutMs: Long = 5_000L,
    internal var transferTimeoutMs: Long = 30_000L,
    internal var pairingTimeoutMs: Long = 60_000L
) {
    private val closed = AtomicBoolean(false)

    /** Local device name sent during handshake. Set before calling performHandshake(). */
    var localName: String? = null

    /** Remote device name received during handshake. Available after onSessionReady. */
    var remoteName: String? = null
        private set

    /** Queue of outbound clipboard transfers (encrypted blob). */
    private val outboundQueue = LinkedBlockingQueue<ByteArray>()

    /**
     * Queue of inbound messages, populated by the reader thread.
     * A null sentinel value signals that the stream was closed.
     */
    private val inboundQueue = LinkedBlockingQueue<Any>()

    /** Reader thread that blocks on stream reads. */
    private var readerThread: Thread? = null

    // Sentinel to signal stream closure in the inbound queue
    private object StreamClosed

    // ── Handshake ────────────────────────────────────────────────────

    /**
     * Perform the handshake. Blocks until complete or timeout.
     * Must be called before [listenForMessages].
     */
    fun performHandshake() {
        try {
            when (val m = mode) {
                is SessionMode.Normal -> {
                    if (isInitiator) {
                        initiatorHandshake()
                    } else {
                        responderHandshake()
                    }
                }
                is SessionMode.Pairing -> {
                    if (isInitiator) {
                        throw ProtocolException("Android cannot be pairing initiator")
                    } else {
                        pairingResponderHandshake(m)
                    }
                }
            }
            callback.onSessionReady()
        } catch (e: Exception) {
            if (closed.compareAndSet(false, true)) {
                try { input.close() } catch (_: Exception) {}
                try { output.close() } catch (_: Exception) {}
                callback.onSessionError(e)
            }
        }
    }

    private fun initiatorHandshake() {
        // Send HELLO
        val hello = Message(MessageType.HELLO, helloPayload())
        MessageCodec.write(output, hello)

        // Wait for WELCOME
        val welcome = readWithTimeout(handshakeTimeoutMs)
        if (welcome.type != MessageType.WELCOME) {
            throw ProtocolException("Expected WELCOME, got ${welcome.type}")
        }
        validateVersion(welcome.payload)
    }

    private fun responderHandshake() {
        // Wait for HELLO
        val hello = readWithTimeout(handshakeTimeoutMs)
        if (hello.type != MessageType.HELLO) {
            throw ProtocolException("Expected HELLO, got ${hello.type}")
        }
        validateVersion(hello.payload)

        // Send WELCOME
        val welcome = Message(MessageType.WELCOME, helloPayload())
        MessageCodec.write(output, welcome)
    }

    // ── Pairing handshake ────────────────────────────────────────────

    private fun pairingResponderHandshake(pairing: SessionMode.Pairing) {
        // Send KEY_EXCHANGE with our public key (and optional name)
        val pubkeyHex = pairing.ownPublicKeyRaw.joinToString("") { "%02x".format(it) }
        val exchangeJson = JSONObject().apply {
            put("pubkey", pubkeyHex)
            localName?.let { put("name", it) }
        }
        val keyExchange = Message(MessageType.KEY_EXCHANGE, exchangeJson.toString().toByteArray())
        MessageCodec.write(output, keyExchange)

        // Compute ECDH shared secret
        val sharedSecret = E2ECrypto.ecdhSharedSecret(pairing.ownPrivateKey, pairing.remotePublicKeyRaw)

        // Wait for KEY_CONFIRM from Mac (60s pairing timeout)
        val confirm = readWithTimeout(pairingTimeoutMs)
        if (confirm.type != MessageType.KEY_CONFIRM) {
            throw ProtocolException("Expected KEY_CONFIRM, got ${confirm.type}")
        }

        // Derive encryption key and verify confirmation
        val encKey = E2ECrypto.deriveKey(sharedSecret)
        val decrypted = try {
            E2ECrypto.open(confirm.payload, encKey)
        } catch (e: Exception) {
            throw ProtocolException("KEY_CONFIRM decryption failed: ${e.message}")
        }

        val expected = "cliprelay-paired".toByteArray()
        if (!decrypted.contentEquals(expected)) {
            throw ProtocolException("KEY_CONFIRM verification failed: unexpected plaintext")
        }

        // Notify callback of completed pairing
        callback.onPairingComplete(sharedSecret, remoteName = null)

        // Continue with normal HELLO/WELCOME handshake
        responderHandshake()
    }

    // ── Message loop ─────────────────────────────────────────────────

    /**
     * Blocking read loop. Call on a dedicated background thread after handshake.
     * Returns when the session is closed (either normally or on error).
     */
    fun listenForMessages() {
        // Start a reader thread that does blocking reads and enqueues messages
        startReaderThread()

        try {
            while (!closed.get()) {
                // Check for queued outbound transfers (short poll)
                val outbound = outboundQueue.poll(50, TimeUnit.MILLISECONDS)
                if (outbound != null) {
                    doSendClipboard(outbound)
                    continue
                }

                // Check for inbound messages (non-blocking)
                val item = inboundQueue.poll()
                if (item != null) {
                    when (item) {
                        is Message -> handleInbound(item)
                        is StreamClosed -> throw ProtocolException("Stream closed")
                        is Exception -> throw item
                    }
                }
            }
        } catch (e: Exception) {
            if (closed.compareAndSet(false, true)) {
                try { input.close() } catch (_: Exception) {}
                try { output.close() } catch (_: Exception) {}
                callback.onSessionError(e)
            }
        }
    }

    /** Start a background thread that blocks on stream reads. */
    private fun startReaderThread() {
        readerThread = Thread({
            try {
                while (!closed.get()) {
                    val msg = MessageCodec.decode(input)
                    inboundQueue.put(msg)
                }
            } catch (e: Exception) {
                if (!closed.get()) {
                    inboundQueue.put(e)
                }
            }
        }, "session-reader").apply {
            isDaemon = true
            start()
        }
    }

    private fun handleInbound(msg: Message) {
        when (msg.type) {
            MessageType.OFFER -> handleInboundOffer(msg)
            else -> throw ProtocolException("Unexpected message type: ${msg.type}")
        }
    }

    // ── Outbound transfer ────────────────────────────────────────────

    /**
     * Queue a clipboard blob for sending. Thread-safe.
     * The actual transfer happens in the listen loop.
     */
    fun sendClipboard(encryptedBlob: ByteArray) {
        if (closed.get()) return
        outboundQueue.put(encryptedBlob)
    }

    private fun doSendClipboard(encryptedBlob: ByteArray) {
        val hash = sha256Hex(encryptedBlob)
        val offerJson = JSONObject().apply {
            put("hash", hash)
            put("size", encryptedBlob.size)
            put("type", "text/plain")
        }
        val offer = Message(MessageType.OFFER, offerJson.toString().toByteArray())
        MessageCodec.write(output, offer)

        // Wait for ACCEPT or DONE
        val response = readWithTimeout(transferTimeoutMs)
        when (response.type) {
            MessageType.ACCEPT -> {
                // Send PAYLOAD
                val payload = Message(MessageType.PAYLOAD, encryptedBlob)
                MessageCodec.write(output, payload)

                // Wait for DONE
                val done = readWithTimeout(transferTimeoutMs)
                if (done.type != MessageType.DONE) {
                    throw ProtocolException("Expected DONE, got ${done.type}")
                }
                callback.onTransferComplete(hash)
            }
            MessageType.DONE -> {
                // Receiver already had this hash — transfer complete (dedup)
                callback.onTransferComplete(hash)
            }
            else -> throw ProtocolException("Expected ACCEPT or DONE, got ${response.type}")
        }
    }

    // ── Inbound transfer ─────────────────────────────────────────────

    private fun handleInboundOffer(msg: Message) {
        val json = JSONObject(String(msg.payload))
        val hash = json.getString("hash")

        if (callback.hasHash(hash)) {
            // Already have this — skip PAYLOAD, send DONE immediately
            val doneJson = JSONObject().apply {
                put("hash", hash)
                put("ok", true)
            }
            val done = Message(MessageType.DONE, doneJson.toString().toByteArray())
            MessageCodec.write(output, done)
            return
        }

        // Send ACCEPT
        val accept = Message(MessageType.ACCEPT, ByteArray(0))
        MessageCodec.write(output, accept)

        // Wait for PAYLOAD
        val payload = readWithTimeout(transferTimeoutMs)
        if (payload.type != MessageType.PAYLOAD) {
            throw ProtocolException("Expected PAYLOAD, got ${payload.type}")
        }

        // Verify hash
        val actualHash = sha256Hex(payload.payload)
        if (actualHash != hash) {
            throw ProtocolException("Hash mismatch: expected $hash, got $actualHash")
        }

        // Notify callback
        callback.onClipboardReceived(payload.payload, hash)

        // Send DONE
        val doneJson = JSONObject().apply {
            put("hash", hash)
            put("ok", true)
        }
        val done = Message(MessageType.DONE, doneJson.toString().toByteArray())
        MessageCodec.write(output, done)
    }

    // ── Lifecycle ────────────────────────────────────────────────────

    /**
     * Close the session. Can be called from any thread.
     * Interrupts any blocking reads.
     */
    fun close() {
        if (closed.compareAndSet(false, true)) {
            try { input.close() } catch (_: Exception) {}
            try { output.close() } catch (_: Exception) {}
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /**
     * Read a message with timeout. Used during handshake and within transfer flows.
     * During the listen loop, messages come from the inbound queue instead.
     */
    private fun readWithTimeout(timeoutMs: Long): Message {
        // If the reader thread is running, read from the inbound queue
        if (readerThread != null) {
            return readFromQueueWithTimeout(timeoutMs)
        }
        // Otherwise (during handshake), read directly from the stream
        return readDirectWithTimeout(timeoutMs)
    }

    private fun readDirectWithTimeout(timeoutMs: Long): Message {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!closed.get()) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) {
                throw ProtocolException("Timeout waiting for message (${timeoutMs}ms)")
            }
            if (input.available() > 0) {
                return MessageCodec.decode(input)
            }
            Thread.sleep(10.coerceAtMost(remaining.toInt()).toLong())
        }
        throw ProtocolException("Session closed while waiting for message")
    }

    private fun readFromQueueWithTimeout(timeoutMs: Long): Message {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (!closed.get()) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) {
                throw ProtocolException("Timeout waiting for message (${timeoutMs}ms)")
            }
            val waitMs = remaining.coerceAtMost(50)
            val item = inboundQueue.poll(waitMs, TimeUnit.MILLISECONDS)
            if (item != null) {
                return when (item) {
                    is Message -> item
                    is Exception -> throw item
                    else -> throw ProtocolException("Stream closed")
                }
            }
        }
        throw ProtocolException("Session closed while waiting for message")
    }

    private fun helloPayload(): ByteArray {
        val json = JSONObject()
        json.put("version", 1)
        localName?.let { json.put("name", it) }
        return json.toString().toByteArray()
    }

    private fun validateVersion(payload: ByteArray) {
        val json = JSONObject(String(payload))
        val version = json.getInt("version")
        if (version != 1) {
            throw ProtocolException("Unsupported protocol version: $version")
        }
        remoteName = if (json.has("name")) json.getString("name") else null
    }

    companion object {
        internal fun sha256Hex(data: ByteArray): String {
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            return digest.digest(data).joinToString("") { "%02x".format(it) }
        }
    }
}

interface SessionCallback {
    fun onSessionReady()
    fun onClipboardReceived(encryptedBlob: ByteArray, hash: String)
    fun onTransferComplete(hash: String)
    fun onSessionError(error: Exception)
    fun hasHash(hash: String): Boolean
    fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?) {}
}
