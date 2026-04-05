package org.cliprelay.ble

// Listens for incoming BLE L2CAP connections and hands off connected sockets to a callback.

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import java.io.IOException

interface L2capServerCallback {
    fun onClientConnected(socket: BluetoothSocket)
    fun onAcceptError(error: IOException)
}

class L2capServer(
    private val adapter: BluetoothAdapter,
    private val callback: L2capServerCallback
) {
    private var serverSocket: BluetoothServerSocket? = null
    private var acceptThread: Thread? = null

    /**
     * Start listening for L2CAP connections.
     * Returns the PSM (Protocol Service Multiplexer) value assigned by the OS.
     * The PSM must be exposed via GATT so the central can discover it.
     */
    fun start(): Int {
        // Use INSECURE L2CAP — no BLE-level encryption.
        // App-layer AES-256-GCM provides encryption.
        val socket = adapter.listenUsingInsecureL2capChannel()
        serverSocket = socket
        val psm = socket.psm

        acceptThread = Thread({
            while (!Thread.currentThread().isInterrupted) {
                try {
                    val client = socket.accept() // blocks until connection
                    callback.onClientConnected(client)
                } catch (e: IOException) {
                    if (!Thread.currentThread().isInterrupted) {
                        callback.onAcceptError(e)
                    }
                    break
                }
            }
        }, "L2CAP-Accept").apply { isDaemon = true }
        acceptThread?.start()

        return psm
    }

    fun stop() {
        acceptThread?.interrupt()
        try { serverSocket?.close() } catch (_: IOException) {}
        acceptThread = null
        serverSocket = null
    }
}
