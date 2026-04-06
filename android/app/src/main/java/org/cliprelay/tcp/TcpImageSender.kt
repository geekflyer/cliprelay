package org.cliprelay.tcp

import java.net.InetSocketAddress
import java.net.Socket

object TcpImageSender {
    /**
     * Connects to a TCP server and sends the given data, optionally prefixed with a nonce.
     * When [sourceIp] is provided, binds the socket to that local address before connecting
     * (forces routing over the LAN interface even when a VPN is active).
     */
    fun send(
        host: String,
        port: Int,
        data: ByteArray,
        nonce: ByteArray? = null,
        sourceIp: String? = null,
        connectTimeoutMs: Int = 3000,
    ) {
        val socket = Socket()
        try {
            // Bind to LAN interface to bypass VPN routing
            if (sourceIp != null) {
                try {
                    socket.bind(InetSocketAddress(sourceIp, 0))
                } catch (_: Exception) {
                    // If bind fails, proceed without binding (graceful degradation)
                }
            }
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            val out = socket.getOutputStream()
            if (nonce != null) {
                out.write(nonce)
            }
            out.write(data)
            out.flush()
        } catch (e: Exception) {
            throw TcpTransferException("Failed to send: ${e.message}", e)
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
