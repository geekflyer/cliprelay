package org.cliprelay.protocol

import org.cliprelay.crypto.E2ECrypto
import org.junit.Assert.*
import org.junit.Test
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONObject

/**
 * Tests for the Session protocol handler using piped in-memory streams.
 *
 * Each test creates two piped stream pairs wired together (A→B, B→A)
 * so two Session instances can talk to each other, simulating a real
 * L2CAP connection without any BLE hardware.
 */
class SessionTest {

    private val testSharedSecret = "b4e4716bc736cde97aa0b585beddab79e190a2531e21bdd410914aeec7a2a4e1"

    // ── Handshake tests ──────────────────────────────────────────────

    @Test
    fun `initiator sends HELLO and receives WELCOME - both sessions ready`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }

        startBothSessions(env)

        assertTrue("Both sessions should become ready", readyLatch.await(5, TimeUnit.SECONDS))
        cleanup(env)
    }

    @Test
    fun `handshake timeout when no WELCOME received`() {
        // Create a session that reads from an empty stream (no peer)
        val emptyInput = PipedInputStream()
        val dummyOutput = PipedOutputStream()
        // Connect them so the output doesn't throw on write
        val sinkInput = PipedInputStream(dummyOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = emptyInput,
            output = dummyOutput,
            isInitiator = true,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 200 // Short timeout for test speed
        )

        Thread { session.performHandshake() }.start()

        assertTrue("Should timeout", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention timeout", capturedError!!.message!!.contains("Timeout"))
        session.close()
        emptyInput.close()
        dummyOutput.close()
        sinkInput.close()
    }

    @Test
    fun `wrong message type during handshake causes error`() {
        // Set up streams where we manually write an OFFER instead of WELCOME
        val macInput = PipedInputStream()
        val toMac = PipedOutputStream(macInput)
        val macOutput = PipedOutputStream()
        val fromMac = PipedInputStream(macOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = macInput,
            output = macOutput,
            isInitiator = true,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        // Start initiator handshake (it will send HELLO, then wait for WELCOME)
        Thread { session.performHandshake() }.start()

        // Read the HELLO it sent
        MessageCodec.decode(fromMac)

        // Send an OFFER instead of WELCOME
        val wrongMsg = Message(MessageType.OFFER, """{"hash":"x","size":1,"type":"text/plain"}""".toByteArray())
        MessageCodec.write(toMac, wrongMsg)

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention WELCOME", capturedError!!.message!!.contains("WELCOME"))

        session.close()
        macInput.close()
        toMac.close()
        macOutput.close()
        fromMac.close()
    }

    @Test
    fun `version mismatch in HELLO causes responder error`() {
        val androidInput = PipedInputStream()
        val toAndroid = PipedOutputStream(androidInput)
        val androidOutput = PipedOutputStream()
        val fromAndroid = PipedInputStream(androidOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = androidInput,
            output = androidOutput,
            isInitiator = false,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread { session.performHandshake() }.start()

        // Send HELLO with wrong version
        val badHello = Message(MessageType.HELLO, """{"version":99}""".toByteArray())
        MessageCodec.write(toAndroid, badHello)

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention version", capturedError!!.message!!.contains("version"))

        session.close()
        androidInput.close()
        toAndroid.close()
        androidOutput.close()
        fromAndroid.close()
    }

    // ── Transfer tests ───────────────────────────────────────────────

    @Test
    fun `sender sends OFFER, gets ACCEPT, sends PAYLOAD, gets DONE`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        val transferLatch = CountDownLatch(1)
        val receivedLatch = CountDownLatch(1)

        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }

        val testData = "Hello from Mac!".toByteArray()
        val expectedHash = Session.sha256Hex(testData)

        env.macCallback.onTransfer = { hash ->
            assertEquals(expectedHash, hash)
            transferLatch.countDown()
        }
        env.androidCallback.onReceived = { blob, hash ->
            assertArrayEquals(testData, blob)
            assertEquals(expectedHash, hash)
            receivedLatch.countDown()
        }

        startBothSessions(env)
        assertTrue("Handshake should complete", readyLatch.await(5, TimeUnit.SECONDS))

        // Mac sends clipboard (plaintext)
        env.macSession.sendClipboard(testData)

        assertTrue("Receiver should get clipboard", receivedLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Sender should get transfer complete", transferLatch.await(5, TimeUnit.SECONDS))

        cleanup(env)
    }

    @Test
    fun `receiver gets OFFER, sends ACCEPT, gets PAYLOAD, sends DONE`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        val receivedLatch = CountDownLatch(1)
        var receivedBlob: ByteArray? = null
        var receivedHash: String? = null

        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }
        env.macCallback.onReceived = { blob, hash ->
            receivedBlob = blob
            receivedHash = hash
            receivedLatch.countDown()
        }

        startBothSessions(env)
        assertTrue("Handshake should complete", readyLatch.await(5, TimeUnit.SECONDS))

        // Android sends clipboard (plaintext)
        val testData = "Hello from Android!".toByteArray()
        env.androidSession.sendClipboard(testData)

        assertTrue("Mac should receive clipboard", receivedLatch.await(5, TimeUnit.SECONDS))
        assertArrayEquals(testData, receivedBlob)
        assertEquals(Session.sha256Hex(testData), receivedHash)

        cleanup(env)
    }

    @Test
    fun `duplicate OFFER - hasHash returns true - receiver sends DONE immediately`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        val transferLatch = CountDownLatch(1)

        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }

        val testData = "duplicate data".toByteArray()
        val hash = Session.sha256Hex(testData)

        // Android already has this hash
        env.androidCallback.knownHashes.add(hash)

        env.macCallback.onTransfer = { h ->
            assertEquals(hash, h)
            transferLatch.countDown()
        }

        // Android should NOT receive onClipboardReceived for a dedup
        env.androidCallback.onReceived = { _, _ ->
            fail("Should not receive clipboard for duplicate")
        }

        startBothSessions(env)
        assertTrue("Handshake should complete", readyLatch.await(5, TimeUnit.SECONDS))

        env.macSession.sendClipboard(testData)
        assertTrue("Sender should get transfer complete (dedup)", transferLatch.await(5, TimeUnit.SECONDS))

        cleanup(env)
    }

    @Test
    fun `transfer timeout when receiver never responds`() {
        // Set up manual streams — receiver never sends ACCEPT
        val macInput = PipedInputStream()
        val toMac = PipedOutputStream(macInput)
        val macOutput = PipedOutputStream()
        val fromMac = PipedInputStream(macOutput)

        val readyLatch = CountDownLatch(1)
        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onReady = { readyLatch.countDown() }
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = macInput,
            output = macOutput,
            isInitiator = true,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000,
            transferTimeoutMs = 300 // Short timeout for test
        )

        // Do handshake manually
        Thread {
            session.performHandshake()
            if (readyLatch.count > 0L) return@Thread
            session.listenForMessages()
        }.start()

        // Complete handshake from the other side — must send valid v2 WELCOME
        val hello = MessageCodec.decode(fromMac)
        assertEquals(MessageType.HELLO, hello.type)

        // Parse the HELLO to get the initiator's ek for ECDH
        val helloJson = JSONObject(String(hello.payload))
        val remoteEkHex = helloJson.getString("ek")

        // Generate our own ephemeral key pair for the response
        val responderKeyPair = E2ECrypto.generateX25519KeyPair()
        val responderEkBytes = E2ECrypto.x25519PublicKeyToRaw(responderKeyPair.public)
        val responderEkHex = responderEkBytes.joinToString("") { "%02x".format(it) }

        // Compute auth
        val authKey = E2ECrypto.deriveAuthKey(E2ECrypto.hexToBytes(testSharedSecret))
        val authBytes = E2ECrypto.hmacAuth(responderEkBytes, authKey)
        val authHex = authBytes.joinToString("") { "%02x".format(it) }

        val welcomeJson = JSONObject().apply {
            put("version", 2)
            put("ek", responderEkHex)
            put("auth", authHex)
        }
        val welcome = Message(MessageType.WELCOME, welcomeJson.toString().toByteArray())
        MessageCodec.write(toMac, welcome)

        assertTrue("Session should be ready", readyLatch.await(3, TimeUnit.SECONDS))

        // Send clipboard — it will send OFFER and then timeout waiting for ACCEPT
        session.sendClipboard("timeout test".toByteArray())

        assertTrue("Should timeout", errorLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Error should mention timeout", capturedError!!.message!!.contains("Timeout"))

        session.close()
        macInput.close()
        toMac.close()
        macOutput.close()
        fromMac.close()
    }

    // ── Edge case tests ──────────────────────────────────────────────

    @Test
    fun `stream closed during listen causes clean shutdown`() {
        val macInput = PipedInputStream()
        val toMac = PipedOutputStream(macInput)
        val macOutput = PipedOutputStream()
        val fromMac = PipedInputStream(macOutput)

        val readyLatch = CountDownLatch(1)
        val errorLatch = CountDownLatch(1)
        val callback = TestCallback()
        callback.onReady = { readyLatch.countDown() }
        callback.onError = { errorLatch.countDown() }

        val session = Session(
            input = macInput,
            output = macOutput,
            isInitiator = true,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread {
            session.performHandshake()
            session.listenForMessages()
        }.start()

        // Complete handshake with valid v2 WELCOME
        val hello = MessageCodec.decode(fromMac)
        assertEquals(MessageType.HELLO, hello.type)
        sendValidWelcome(toMac, hello)

        assertTrue("Session should be ready", readyLatch.await(3, TimeUnit.SECONDS))

        // Close the input stream from the other side — simulates disconnect
        toMac.close()

        // The listen loop should eventually notice and report an error or exit
        // With PipedInputStream, closing the writer causes reads to throw
        assertTrue("Should detect stream close", errorLatch.await(3, TimeUnit.SECONDS))

        session.close()
        macInput.close()
        macOutput.close()
        fromMac.close()
    }

    @Test
    fun `malformed message during listen causes error`() {
        val macInput = PipedInputStream()
        val toMac = PipedOutputStream(macInput)
        val macOutput = PipedOutputStream()
        val fromMac = PipedInputStream(macOutput)

        val readyLatch = CountDownLatch(1)
        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onReady = { readyLatch.countDown() }
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = macInput,
            output = macOutput,
            isInitiator = true,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread {
            session.performHandshake()
            session.listenForMessages()
        }.start()

        // Complete handshake with valid v2 WELCOME
        val hello = MessageCodec.decode(fromMac)
        sendValidWelcome(toMac, hello)
        assertTrue("Session should be ready", readyLatch.await(3, TimeUnit.SECONDS))

        // Send raw garbage (invalid message type 0xFF)
        toMac.write(byteArrayOf(0x00, 0x00, 0x00, 0x01, 0xFF.toByte()))
        toMac.flush()

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertNotNull(capturedError)

        session.close()
        macInput.close()
        toMac.close()
        macOutput.close()
        fromMac.close()
    }

    // ── V2 handshake tests ──────────────────────────────────────────

    @Test
    fun `v2 handshake succeeds`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }

        startBothSessions(env)

        assertTrue("Both sessions should become ready via v2 handshake", readyLatch.await(5, TimeUnit.SECONDS))
        cleanup(env)
    }

    @Test
    fun `v2 handshake rejects version 1`() {
        val androidInput = PipedInputStream()
        val toAndroid = PipedOutputStream(androidInput)
        val androidOutput = PipedOutputStream()
        val fromAndroid = PipedInputStream(androidOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = androidInput,
            output = androidOutput,
            isInitiator = false,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread { session.performHandshake() }.start()

        // Send v1 HELLO (no ek, no auth)
        val v1Hello = Message(MessageType.HELLO, """{"version":1,"name":"OldMac"}""".toByteArray())
        MessageCodec.write(toAndroid, v1Hello)

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention version", capturedError!!.message!!.contains("version"))

        session.close()
        androidInput.close()
        toAndroid.close()
        androidOutput.close()
        fromAndroid.close()
    }

    @Test
    fun `v2 handshake rejects bad auth`() {
        val androidInput = PipedInputStream()
        val toAndroid = PipedOutputStream(androidInput)
        val androidOutput = PipedOutputStream()
        val fromAndroid = PipedInputStream(androidOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = androidInput,
            output = androidOutput,
            isInitiator = false,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread { session.performHandshake() }.start()

        // Generate a valid ek but with wrong auth (using a different secret)
        val kp = E2ECrypto.generateX25519KeyPair()
        val ekBytes = E2ECrypto.x25519PublicKeyToRaw(kp.public)
        val ekHex = ekBytes.joinToString("") { "%02x".format(it) }
        // Use a wrong auth key (different shared secret)
        val wrongAuthKey = E2ECrypto.deriveAuthKey(ByteArray(32)) // zeros
        val wrongAuth = E2ECrypto.hmacAuth(ekBytes, wrongAuthKey)
        val wrongAuthHex = wrongAuth.joinToString("") { "%02x".format(it) }

        val badHello = JSONObject().apply {
            put("version", 2)
            put("ek", ekHex)
            put("auth", wrongAuthHex)
        }
        val msg = Message(MessageType.HELLO, badHello.toString().toByteArray())
        MessageCodec.write(toAndroid, msg)

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention authentication", capturedError!!.message!!.contains("Authentication failed"))

        session.close()
        androidInput.close()
        toAndroid.close()
        androidOutput.close()
        fromAndroid.close()
    }

    @Test
    fun `v2 handshake rejects missing ek`() {
        val androidInput = PipedInputStream()
        val toAndroid = PipedOutputStream(androidInput)
        val androidOutput = PipedOutputStream()
        val fromAndroid = PipedInputStream(androidOutput)

        val errorLatch = CountDownLatch(1)
        var capturedError: Exception? = null
        val callback = TestCallback()
        callback.onError = { e ->
            capturedError = e
            errorLatch.countDown()
        }

        val session = Session(
            input = androidInput,
            output = androidOutput,
            isInitiator = false,
            callback = callback,
            sharedSecretHex = testSharedSecret,
            handshakeTimeoutMs = 2000
        )

        Thread { session.performHandshake() }.start()

        // Send v2 HELLO without ek field
        val badHello = JSONObject().apply {
            put("version", 2)
            put("auth", "a".repeat(64))
        }
        val msg = Message(MessageType.HELLO, badHello.toString().toByteArray())
        MessageCodec.write(toAndroid, msg)

        assertTrue("Should get error", errorLatch.await(3, TimeUnit.SECONDS))
        assertTrue("Error should mention ephemeral key",
            capturedError!!.message!!.contains("ephemeral key", ignoreCase = true))

        session.close()
        androidInput.close()
        toAndroid.close()
        androidOutput.close()
        fromAndroid.close()
    }

    @Test
    fun `v2 end-to-end clipboard transfer`() {
        val (env) = createPairedSessions(testSharedSecret)
        val readyLatch = CountDownLatch(2)
        val receivedLatch = CountDownLatch(1)
        val transferLatch = CountDownLatch(1)

        env.macCallback.onReady = { readyLatch.countDown() }
        env.androidCallback.onReady = { readyLatch.countDown() }

        val plaintext = "Forward secrecy clipboard test!".toByteArray()
        val expectedHash = Session.sha256Hex(plaintext)

        env.macCallback.onTransfer = { hash ->
            assertEquals(expectedHash, hash)
            transferLatch.countDown()
        }
        env.androidCallback.onReceived = { received, hash ->
            assertArrayEquals("Plaintext should match", plaintext, received)
            assertEquals("Hash should match", expectedHash, hash)
            receivedLatch.countDown()
        }

        startBothSessions(env)
        assertTrue("Handshake should complete", readyLatch.await(5, TimeUnit.SECONDS))

        // Mac sends plaintext — Session encrypts internally
        env.macSession.sendClipboard(plaintext)

        assertTrue("Android should receive plaintext", receivedLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Mac should get transfer complete", transferLatch.await(5, TimeUnit.SECONDS))

        cleanup(env)
    }

    // ── Pairing + v2 handshake integration test ─────────────────────

    @Test
    fun `pairing followed by v2 handshake and clipboard transfer succeeds`() {
        // Android is always the pairing RESPONDER. Mac is the pairing INITIATOR.
        // Since we can only run Android Session objects here, we simulate the
        // Mac's pairing role manually (sending KEY_CONFIRM) and let the Android
        // Session handle the full pairing → v2 handshake transition.

        // Pipes: "Mac" (manual) ↔ Android (Session)
        val toAndroidOut = PipedOutputStream()
        val toAndroidIn = PipedInputStream(toAndroidOut)
        val fromAndroidOut = PipedOutputStream()
        val fromAndroidIn = PipedInputStream(fromAndroidOut)

        // Generate pairing key pairs (simulating QR code exchange)
        val macPairingKeyPair = E2ECrypto.generateX25519KeyPair()
        val androidPairingKeyPair = E2ECrypto.generateX25519KeyPair()
        val macPubRaw = E2ECrypto.x25519PublicKeyToRaw(macPairingKeyPair.public)
        val androidPubRaw = E2ECrypto.x25519PublicKeyToRaw(androidPairingKeyPair.public)

        val readyLatch = CountDownLatch(1)
        var pairingSecret: ByteArray? = null

        val callback = TestCallback()
        callback.onPairing = { secret, _ -> pairingSecret = secret }
        callback.onReady = { readyLatch.countDown() }

        // Android session in pairing responder mode
        val androidSession = Session(
            input = toAndroidIn,
            output = fromAndroidOut,
            isInitiator = false,
            callback = callback,
            mode = SessionMode.Pairing(
                ownPrivateKey = androidPairingKeyPair.private,
                ownPublicKeyRaw = androidPubRaw,
                remotePublicKeyRaw = macPubRaw
            )
        )

        val sessionThread = Thread {
            androidSession.performHandshake()
            androidSession.listenForMessages()
        }.apply { isDaemon = true; start() }

        // --- Simulate Mac pairing initiator ---

        // 1. Read KEY_EXCHANGE from Android
        val keyExchange = MessageCodec.decode(fromAndroidIn)
        assertEquals(MessageType.KEY_EXCHANGE, keyExchange.type)
        val exchangeJson = JSONObject(String(keyExchange.payload))
        val remotePubHex = exchangeJson.getString("pubkey")

        // 2. Compute ECDH shared secret (same as Mac would)
        val sharedSecret = E2ECrypto.ecdhSharedSecret(
            macPairingKeyPair.private, E2ECrypto.hexToBytes(remotePubHex)
        )

        // 3. Send KEY_CONFIRM (encrypted "cliprelay-paired")
        val encKey = E2ECrypto.deriveKey(sharedSecret)
        val confirmPayload = E2ECrypto.seal("cliprelay-paired".toByteArray(), encKey)
        MessageCodec.write(toAndroidOut, Message(MessageType.KEY_CONFIRM, confirmPayload))

        // --- Now simulate Mac v2 HELLO handshake ---

        // 4. Read Android's v2 HELLO (sent after pairing completes)
        //    Actually, Android is the responder, so it waits for HELLO first.
        //    We need to send a v2 HELLO and then read the v2 WELCOME.

        // Derive auth key from the shared secret (same as Mac would)
        val authKey = E2ECrypto.deriveAuthKey(sharedSecret)

        // Generate Mac ephemeral key for v2 handshake
        val macEphKeyPair = E2ECrypto.generateX25519KeyPair()
        val macEphPubRaw = E2ECrypto.x25519PublicKeyToRaw(macEphKeyPair.public)
        val macEphPubHex = macEphPubRaw.joinToString("") { "%02x".format(it) }
        val macAuthHex = E2ECrypto.hmacAuth(macEphPubRaw, authKey)
            .joinToString("") { "%02x".format(it) }

        val helloJson = JSONObject().apply {
            put("version", 2)
            put("ek", macEphPubHex)
            put("auth", macAuthHex)
        }
        MessageCodec.write(toAndroidOut, Message(MessageType.HELLO, helloJson.toString().toByteArray()))

        // 5. Read v2 WELCOME from Android
        val welcome = MessageCodec.decode(fromAndroidIn)
        assertEquals(MessageType.WELCOME, welcome.type)
        val welcomeJson = JSONObject(String(welcome.payload))
        assertEquals(2, welcomeJson.getInt("version"))
        assertTrue("WELCOME should have ek", welcomeJson.has("ek"))
        assertTrue("WELCOME should have auth", welcomeJson.has("auth"))

        // Verify Android's auth
        val androidEkHex = welcomeJson.getString("ek")
        val androidEkBytes = E2ECrypto.hexToBytes(androidEkHex)
        val androidAuthHex = welcomeJson.getString("auth")
        val androidAuthBytes = E2ECrypto.hexToBytes(androidAuthHex)
        assertTrue("Android auth should verify",
            E2ECrypto.verifyAuth(androidEkBytes, authKey, androidAuthBytes))

        // Wait for Android session to be ready
        assertTrue("Android session should become ready after pairing + v2 handshake",
            readyLatch.await(10, TimeUnit.SECONDS))

        // Verify pairing secret was derived
        assertNotNull("Android should have pairing secret", pairingSecret)

        // 6. Send encrypted clipboard to verify session key works
        // Derive session key (same as Mac would)
        val ecdhResult = E2ECrypto.rawX25519(macEphKeyPair.private, androidEkBytes)
        val sessionKey = E2ECrypto.deriveSessionKey(sharedSecret, ecdhResult)

        // Send OFFER + PAYLOAD
        val plaintext = "Pairing test clipboard".toByteArray()
        val plaintextHash = Session.sha256Hex(plaintext)
        val encrypted = E2ECrypto.seal(plaintext, sessionKey)
        val offerJson = JSONObject().apply {
            put("hash", plaintextHash)
            put("size", plaintext.size)
            put("type", "text/plain")
        }
        MessageCodec.write(toAndroidOut, Message(MessageType.OFFER, offerJson.toString().toByteArray()))

        // Read ACCEPT
        val accept = MessageCodec.decode(fromAndroidIn)
        assertEquals(MessageType.ACCEPT, accept.type)

        // Send PAYLOAD
        MessageCodec.write(toAndroidOut, Message(MessageType.PAYLOAD, encrypted))

        // Read DONE
        val done = MessageCodec.decode(fromAndroidIn)
        assertEquals(MessageType.DONE, done.type)

        androidSession.close()
        sessionThread.join(2000)
    }

    // ── Test infrastructure ──────────────────────────────────────────

    data class SessionEnv(
        val macSession: Session,
        val androidSession: Session,
        val macCallback: TestCallback,
        val androidCallback: TestCallback,
        val threads: MutableList<Thread> = mutableListOf()
    )

    /** Wraps the env in a data class so we can destructure it. */
    data class SessionEnvHolder(val env: SessionEnv)

    private fun createPairedSessions(sharedSecretHex: String): SessionEnvHolder {
        // Mac → Android pipe
        val macToAndroidOut = PipedOutputStream()
        val macToAndroidIn = PipedInputStream(macToAndroidOut)

        // Android → Mac pipe
        val androidToMacOut = PipedOutputStream()
        val androidToMacIn = PipedInputStream(androidToMacOut)

        val macCallback = TestCallback()
        val androidCallback = TestCallback()

        val macSession = Session(
            input = androidToMacIn,
            output = macToAndroidOut,
            isInitiator = true,
            callback = macCallback,
            sharedSecretHex = sharedSecretHex
        )

        val androidSession = Session(
            input = macToAndroidIn,
            output = androidToMacOut,
            isInitiator = false,
            callback = androidCallback,
            sharedSecretHex = sharedSecretHex
        )

        return SessionEnvHolder(SessionEnv(macSession, androidSession, macCallback, androidCallback))
    }

    private fun startBothSessions(env: SessionEnv) {
        val macThread = Thread {
            env.macSession.performHandshake()
            env.macSession.listenForMessages()
        }
        val androidThread = Thread {
            env.androidSession.performHandshake()
            env.androidSession.listenForMessages()
        }
        env.threads.add(macThread)
        env.threads.add(androidThread)
        macThread.start()
        androidThread.start()
    }

    private fun cleanup(env: SessionEnv) {
        env.macSession.close()
        env.androidSession.close()
        env.threads.forEach { it.join(2000) }
    }

    /**
     * Helper to send a valid v2 WELCOME response given a received HELLO message.
     * Used in manual-stream tests that need to complete the handshake.
     */
    private fun sendValidWelcome(toMac: PipedOutputStream, hello: Message) {
        // Generate responder ephemeral key pair
        val responderKeyPair = E2ECrypto.generateX25519KeyPair()
        val responderEkBytes = E2ECrypto.x25519PublicKeyToRaw(responderKeyPair.public)
        val responderEkHex = responderEkBytes.joinToString("") { "%02x".format(it) }

        // Compute auth
        val authKey = E2ECrypto.deriveAuthKey(E2ECrypto.hexToBytes(testSharedSecret))
        val authBytes = E2ECrypto.hmacAuth(responderEkBytes, authKey)
        val authHex = authBytes.joinToString("") { "%02x".format(it) }

        val welcomeJson = JSONObject().apply {
            put("version", 2)
            put("ek", responderEkHex)
            put("auth", authHex)
        }
        val welcome = Message(MessageType.WELCOME, welcomeJson.toString().toByteArray())
        MessageCodec.write(toMac, welcome)
    }

    class TestCallback : SessionCallback {
        var onReady: () -> Unit = {}
        var onReceived: (ByteArray, String) -> Unit = { _, _ -> }
        var onTransfer: (String) -> Unit = {}
        var onError: (Exception) -> Unit = {}
        var onPairing: (ByteArray, String?) -> Unit = { _, _ -> }
        val knownHashes = CopyOnWriteArrayList<String>()

        override fun onSessionReady() = onReady()
        override fun onClipboardReceived(plaintext: ByteArray, hash: String) =
            onReceived(plaintext, hash)
        override fun onTransferComplete(hash: String) = onTransfer(hash)
        override fun onSessionError(error: Exception) = onError(error)
        override fun hasHash(hash: String): Boolean = hash in knownHashes
        override fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?) =
            onPairing(sharedSecret, remoteName)
    }
}
