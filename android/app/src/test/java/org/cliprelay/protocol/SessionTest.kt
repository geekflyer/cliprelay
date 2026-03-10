package org.cliprelay.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Tests for the Session protocol handler using piped in-memory streams.
 *
 * Each test creates two piped stream pairs wired together (A→B, B→A)
 * so two Session instances can talk to each other, simulating a real
 * L2CAP connection without any BLE hardware.
 */
class SessionTest {

    // ── Handshake tests ──────────────────────────────────────────────

    @Test
    fun `initiator sends HELLO and receives WELCOME - both sessions ready`() {
        val (env) = createPairedSessions()
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
        val (env) = createPairedSessions()
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

        // Mac sends clipboard
        env.macSession.sendClipboard(testData)

        assertTrue("Receiver should get clipboard", receivedLatch.await(5, TimeUnit.SECONDS))
        assertTrue("Sender should get transfer complete", transferLatch.await(5, TimeUnit.SECONDS))

        cleanup(env)
    }

    @Test
    fun `receiver gets OFFER, sends ACCEPT, gets PAYLOAD, sends DONE`() {
        val (env) = createPairedSessions()
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

        // Android sends clipboard
        val testData = "Hello from Android!".toByteArray()
        env.androidSession.sendClipboard(testData)

        assertTrue("Mac should receive clipboard", receivedLatch.await(5, TimeUnit.SECONDS))
        assertArrayEquals(testData, receivedBlob)
        assertEquals(Session.sha256Hex(testData), receivedHash)

        cleanup(env)
    }

    @Test
    fun `duplicate OFFER - hasHash returns true - receiver sends DONE immediately`() {
        val (env) = createPairedSessions()
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
            handshakeTimeoutMs = 2000,
            transferTimeoutMs = 300 // Short timeout for test
        )

        // Do handshake manually
        Thread {
            session.performHandshake()
            if (readyLatch.count > 0L) return@Thread
            session.listenForMessages()
        }.start()

        // Complete handshake from the other side
        val hello = MessageCodec.decode(fromMac)
        assertEquals(MessageType.HELLO, hello.type)
        val welcome = Message(MessageType.WELCOME, """{"version":1}""".toByteArray())
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
            handshakeTimeoutMs = 2000
        )

        Thread {
            session.performHandshake()
            session.listenForMessages()
        }.start()

        // Complete handshake
        val hello = MessageCodec.decode(fromMac)
        assertEquals(MessageType.HELLO, hello.type)
        MessageCodec.write(toMac, Message(MessageType.WELCOME, """{"version":1}""".toByteArray()))

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
            handshakeTimeoutMs = 2000
        )

        Thread {
            session.performHandshake()
            session.listenForMessages()
        }.start()

        // Complete handshake
        MessageCodec.decode(fromMac)
        MessageCodec.write(toMac, Message(MessageType.WELCOME, """{"version":1}""".toByteArray()))
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

    private fun createPairedSessions(): SessionEnvHolder {
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
            callback = macCallback
        )

        val androidSession = Session(
            input = macToAndroidIn,
            output = androidToMacOut,
            isInitiator = false,
            callback = androidCallback
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

    class TestCallback : SessionCallback {
        var onReady: () -> Unit = {}
        var onReceived: (ByteArray, String) -> Unit = { _, _ -> }
        var onTransfer: (String) -> Unit = {}
        var onError: (Exception) -> Unit = {}
        var onPairing: (ByteArray, String?) -> Unit = { _, _ -> }
        val knownHashes = CopyOnWriteArrayList<String>()

        override fun onSessionReady() = onReady()
        override fun onClipboardReceived(encryptedBlob: ByteArray, hash: String) =
            onReceived(encryptedBlob, hash)
        override fun onTransferComplete(hash: String) = onTransfer(hash)
        override fun onSessionError(error: Exception) = onError(error)
        override fun hasHash(hash: String): Boolean = hash in knownHashes
        override fun onPairingComplete(sharedSecret: ByteArray, remoteName: String?) =
            onPairing(sharedSecret, remoteName)
    }
}
