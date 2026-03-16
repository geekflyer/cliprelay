package org.cliprelay.protocol

// Manages a single L2CAP protocol session: handshake, clipboard offer/accept, and payload transfer.

import org.cliprelay.crypto.E2ECrypto
import org.json.JSONObject
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyPair
import java.security.PrivateKey
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.SecretKey

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
    private var sharedSecretHex: String? = null,
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

    /** Auth key derived from the shared secret, used for HMAC authentication during handshake. */
    private var authKey: SecretKey? = sharedSecretHex?.let {
        E2ECrypto.deriveAuthKey(E2ECrypto.hexToBytes(it))
    }

    /** Session key derived during v2 handshake. Used for encrypting/decrypting clipboard payloads. */
    private var sessionKey: SecretKey? = null

    /** Ephemeral key pair, generated at handshake start and dropped after session key derivation. */
    private var ephemeralKeyPair: KeyPair? = null

    /** Queue of outbound clipboard transfers (plaintext). */
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
                    if (sharedSecretHex == null) {
                        throw ProtocolException("Shared secret required for Normal mode")
                    }
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
        // Generate ephemeral key pair
        ephemeralKeyPair = E2ECrypto.generateX25519KeyPair()

        // Send HELLO with ephemeral key and auth
        val hello = Message(MessageType.HELLO, helloPayload())
        MessageCodec.write(output, hello)

        // Wait for WELCOME
        val welcome = readWithTimeout(handshakeTimeoutMs)
        if (welcome.type != MessageType.WELCOME) {
            throw ProtocolException("Expected WELCOME, got ${welcome.type}")
        }
        val remoteEkBytes = validateVersion(welcome.payload)

        // Compute ECDH and derive session key
        deriveSessionKeyAndCleanup(remoteEkBytes)
    }

    private fun responderHandshake() {
        // Wait for HELLO
        val hello = readWithTimeout(handshakeTimeoutMs)
        if (hello.type != MessageType.HELLO) {
            throw ProtocolException("Expected HELLO, got ${hello.type}")
        }
        val remoteEkBytes = validateVersion(hello.payload)

        // Generate ephemeral key pair
        ephemeralKeyPair = E2ECrypto.generateX25519KeyPair()

        // Send WELCOME with ephemeral key and auth
        val welcome = Message(MessageType.WELCOME, helloPayload())
        MessageCodec.write(output, welcome)

        // Compute ECDH and derive session key
        deriveSessionKeyAndCleanup(remoteEkBytes)
    }

    /**
     * Compute ECDH shared secret and derive session key, then drop ephemeral private key.
     */
    private fun deriveSessionKeyAndCleanup(remoteEkBytes: ByteArray) {
        val ephPriv = ephemeralKeyPair?.private
            ?: throw ProtocolException("No ephemeral key pair available")
        val secretHex = sharedSecretHex
            ?: throw ProtocolException("No shared secret available for session key derivation")
        val ecdhResult = E2ECrypto.rawX25519(ephPriv, remoteEkBytes)
        val sharedSecretBytes = E2ECrypto.hexToBytes(secretHex)
        sessionKey = E2ECrypto.deriveSessionKey(sharedSecretBytes, ecdhResult)
        // Drop ephemeral private key
        ephemeralKeyPair = null
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

        // Update shared secret and auth key for the subsequent v2 handshake
        val secretHex = sharedSecret.joinToString("") { "%02x".format(it) }
        this.sharedSecretHex = secretHex
        this.authKey = E2ECrypto.deriveAuthKey(sharedSecret)

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
     * Queue plaintext clipboard data for sending. Thread-safe.
     * The actual transfer happens in the listen loop.
     * Session encrypts the data internally using the session key.
     */
    fun sendClipboard(plaintext: ByteArray) {
        if (closed.get()) return
        outboundQueue.put(plaintext)
    }

    private fun doSendClipboard(plaintext: ByteArray) {
        // Hash is computed over plaintext (for dedup across sessions)
        val key = sessionKey ?: throw ProtocolException("No session key available")
        val hash = sha256Hex(plaintext)
        val encryptedBlob = E2ECrypto.seal(plaintext, key)
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

        // Decrypt payload
        val key = sessionKey ?: throw ProtocolException("No session key available")
        val plaintext = E2ECrypto.open(payload.payload, key)

        // Verify hash against plaintext
        val actualHash = sha256Hex(plaintext)
        if (actualHash != hash) {
            throw ProtocolException("Hash mismatch: expected $hash, got $actualHash")
        }

        // Notify callback with plaintext
        callback.onClipboardReceived(plaintext, hash)

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
            // Clear any ephemeral key material
            ephemeralKeyPair = null
            sessionKey = null
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
        json.put("version", 2)
        localName?.let { json.put("name", it) }

        // Include ephemeral key and auth for v2 handshake (Normal mode only)
        val ak = authKey
        val ekp = ephemeralKeyPair
        if (ak != null && ekp != null) {
            val ekBytes = E2ECrypto.x25519PublicKeyToRaw(ekp.public)
            val ekHex = ekBytes.joinToString("") { "%02x".format(it) }
            json.put("ek", ekHex)
            val authBytes = E2ECrypto.hmacAuth(ekBytes, ak)
            val authHex = authBytes.joinToString("") { "%02x".format(it) }
            json.put("auth", authHex)
        }

        return json.toString().toByteArray()
    }

    /**
     * Validate handshake payload: version must be 2, ek must be valid, auth must verify.
     * Returns the remote ephemeral public key bytes.
     */
    private fun validateVersion(payload: ByteArray): ByteArray {
        val json = JSONObject(String(payload))
        val version = json.optInt("version", 0)
        if (version != 2) {
            throw VersionMismatchException(version)
        }
        remoteName = if (json.has("name")) json.getString("name") else null

        // Validate ephemeral key
        val ekHex = json.optString("ek", "")
        if (ekHex.length != 64 || !ekHex.matches(Regex("[0-9a-fA-F]{64}"))) {
            throw ProtocolException("Invalid ephemeral key")
        }
        val remoteEkBytes = E2ECrypto.hexToBytes(ekHex)

        // Validate auth HMAC
        val authHex = json.optString("auth", "")
        if (authHex.isEmpty()) {
            throw ProtocolException("Authentication failed")
        }
        val authBytes = E2ECrypto.hexToBytes(authHex)
        val ak = authKey ?: throw ProtocolException("Authentication failed")
        if (!E2ECrypto.verifyAuth(remoteEkBytes, ak, authBytes)) {
            throw ProtocolException("Authentication failed")
        }

        return remoteEkBytes
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
    fun onClipboardReceived(plaintext: ByteArray, hash: String)
    fun onTransferComplete(hash: String)
    fun onSessionError(error: Exception)
    fun hasHash(hash: String): Boolean
    fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?) {}
}
