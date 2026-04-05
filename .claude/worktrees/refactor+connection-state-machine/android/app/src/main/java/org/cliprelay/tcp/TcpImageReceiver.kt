package org.cliprelay.tcp

import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

data class ServerInfo(val host: String, val port: Int)

class TcpImageReceiver(
    private val expectedSize: Int,
    private val allowedSenderIp: String?,
    private val noConnectionTimeoutMs: Int = 30_000,
    private val transferTimeoutMs: Int = 120_000,
    private val maxConnections: Int = 2,
) {
    private val cancelled = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null

    fun start(): ServerInfo {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress("0.0.0.0", 0))
        serverSocket = server

        val localIp = NetworkUtil.getLocalIpAddress() ?: "0.0.0.0"
        return ServerInfo(localIp, server.localPort)
    }

    /**
     * Blocks until [expectedSize] bytes are received from an allowed sender,
     * or throws [TcpTransferException] on error/timeout/cancel.
     */
    fun receive(): ByteArray {
        val server = serverSocket ?: throw TcpTransferException("Server not started")

        try {
            server.soTimeout = noConnectionTimeoutMs

            var attemptsLeft = maxConnections
            while (attemptsLeft > 0 && !cancelled.get()) {
                attemptsLeft--

                val client: Socket
                try {
                    client = server.accept()
                } catch (e: SocketTimeoutException) {
                    throw TcpTransferException("No connection within ${noConnectionTimeoutMs}ms", e)
                }

                try {
                    val remoteIp = (client.remoteSocketAddress as? InetSocketAddress)
                        ?.address?.hostAddress

                    if (allowedSenderIp != null && remoteIp != allowedSenderIp) {
                        client.close()
                        continue
                    }

                    client.soTimeout = transferTimeoutMs
                    val data = readExactly(client.getInputStream(), expectedSize)
                    return data
                } finally {
                    try { client.close() } catch (_: Exception) {}
                }
            }

            throw TcpTransferException("No valid connection after $maxConnections attempts")
        } catch (e: TcpTransferException) {
            throw e
        } catch (e: Exception) {
            if (cancelled.get()) {
                throw TcpTransferException("Transfer cancelled")
            }
            throw TcpTransferException("Receive failed: ${e.message}", e)
        }
    }

    fun cancel() {
        cancelled.set(true)
        close()
    }

    fun close() {
        try { serverSocket?.close() } catch (_: Exception) {}
    }

    private fun readExactly(input: InputStream, size: Int): ByteArray {
        val buffer = ByteArray(size)
        var offset = 0
        while (offset < size) {
            if (cancelled.get()) throw TcpTransferException("Transfer cancelled")
            val read = input.read(buffer, offset, size - offset)
            if (read == -1) {
                throw TcpTransferException(
                    "Stream closed after $offset bytes, expected $size"
                )
            }
            offset += read
        }
        return buffer
    }
}
