package org.cliprelay.tcp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.net.InetSocketAddress
import java.net.Socket

class TcpImageReceiverTest {

    @Test
    fun acceptsConnectionAndReceivesExactBytes() {
        val payload = ByteArray(1024) { it.toByte() }
        val receiver = TcpImageReceiver(
            expectedSize = payload.size,
            allowedSenderIp = null, // accept any
        )

        val info = receiver.start()
        try {
            val thread = Thread {
                Thread.sleep(50)
                val socket = Socket()
                socket.connect(InetSocketAddress("127.0.0.1", info.port), 1000)
                socket.getOutputStream().write(payload)
                socket.getOutputStream().flush()
                socket.close()
            }
            thread.start()

            val received = receiver.receive()
            assertArrayEquals(payload, received)
            thread.join(2000)
        } finally {
            receiver.close()
        }
    }

    @Test
    fun rejectsConnectionFromWrongIp() {
        val payload = ByteArray(64) { 0x42 }
        val receiver = TcpImageReceiver(
            expectedSize = payload.size,
            allowedSenderIp = "10.0.0.99", // won't match 127.0.0.1
            maxConnections = 1,
            noConnectionTimeoutMs = 2000,
        )

        val info = receiver.start()
        try {
            val thread = Thread {
                Thread.sleep(50)
                try {
                    val socket = Socket()
                    socket.connect(InetSocketAddress("127.0.0.1", info.port), 1000)
                    socket.getOutputStream().write(payload)
                    socket.getOutputStream().flush()
                    socket.close()
                } catch (_: Exception) {}
            }
            thread.start()

            try {
                receiver.receive()
                fail("Expected TcpTransferException")
            } catch (e: TcpTransferException) {
                // expected: no valid connection
            }
            thread.join(2000)
        } finally {
            receiver.close()
        }
    }

    @Test
    fun timesOutWhenNoConnection() {
        val receiver = TcpImageReceiver(
            expectedSize = 100,
            allowedSenderIp = null,
            noConnectionTimeoutMs = 300,
        )

        receiver.start()
        try {
            try {
                receiver.receive()
                fail("Expected TcpTransferException for timeout")
            } catch (e: TcpTransferException) {
                // expected
            }
        } finally {
            receiver.close()
        }
    }
}
