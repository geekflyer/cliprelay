package org.cliprelay.tcp

import java.net.InetSocketAddress
import java.net.Socket

object TcpImageSender {
    fun send(host: String, port: Int, data: ByteArray, connectTimeoutMs: Int = 3000) {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.getOutputStream().write(data)
            socket.getOutputStream().flush()
        } catch (e: Exception) {
            throw TcpTransferException("Failed to send: ${e.message}", e)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
