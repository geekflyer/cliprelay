package org.cliprelay.tcp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.fail
import org.junit.Test
import java.net.ServerSocket

class TcpImageSenderTest {

    @Test
    fun senderConnectsAndPushesData() {
        val payload = ByteArray(2048) { (it % 256).toByte() }
        val server = ServerSocket(0)

        try {
            val received = ByteArray(payload.size)
            val serverThread = Thread {
                val client = server.accept()
                val input = client.getInputStream()
                var offset = 0
                while (offset < received.size) {
                    val n = input.read(received, offset, received.size - offset)
                    if (n == -1) break
                    offset += n
                }
                client.close()
            }
            serverThread.start()

            TcpImageSender.send("127.0.0.1", server.localPort, payload)

            serverThread.join(5000)
            assertArrayEquals(payload, received)
        } finally {
            server.close()
        }
    }

    @Test
    fun senderThrowsOnConnectionRefused() {
        // Use a port that is not listening
        try {
            TcpImageSender.send("127.0.0.1", 1, ByteArray(10), connectTimeoutMs = 500)
            fail("Expected TcpTransferException")
        } catch (e: TcpTransferException) {
            // expected
        }
    }
}
