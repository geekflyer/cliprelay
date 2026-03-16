package org.cliprelay.tcp

import java.io.InputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket

object TcpRelay {
    class TcpServer(private val serverSocket: ServerSocket) {
        val port: Int = serverSocket.localPort

        fun sendAndClose(data: ByteArray) {
            serverSocket.use { server ->
                val client = server.accept()
                client.use { socket ->
                    socket.getOutputStream().write(data)
                    socket.getOutputStream().flush()
                }
            }
        }

        fun close() {
            runCatching { serverSocket.close() }
        }
    }

    fun serve(timeoutMs: Long = 30_000): TcpServer {
        val server = ServerSocket(0)
        server.soTimeout = timeoutMs.toInt()
        return TcpServer(server)
    }

    fun fetch(host: String, port: Int, size: Int, timeoutMs: Long = 30_000): ByteArray {
        val socket = Socket()
        socket.connect(InetSocketAddress(host, port), timeoutMs.toInt())
        socket.soTimeout = timeoutMs.toInt()
        socket.use {
            return readExactly(it.getInputStream(), size)
        }
    }

    fun getLocalIpAddress(): String? {
        return NetworkInterface.getNetworkInterfaces()?.toList()
            ?.flatMap { it.inetAddresses.toList() }
            ?.firstOrNull { !it.isLoopbackAddress && it is Inet4Address }
            ?.hostAddress
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray {
        val buffer = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(buffer, offset, count - offset)
            if (read == -1) throw java.io.IOException("Stream closed after $offset/$count bytes")
            offset += read
        }
        return buffer
    }
}
