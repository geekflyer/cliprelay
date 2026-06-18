package org.cliprelay.ble

// Listens for incoming BLE L2CAP connections and hands off connected sockets to a callback.

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.IOException

interface L2capServerCallback {
    fun onClientConnected(socket: BluetoothSocket)
    fun onAcceptError(error: IOException)
}

class L2capServer(
    private val adapter: BluetoothAdapter,
    private val callback: L2capServerCallback
) {
    companion object {
        private const val TAG = "L2capServer"
    }

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
        Log.i(TAG, "L2CAP server listening (psm=$psm), waiting for central to connect")

        acceptThread = Thread({
            while (!Thread.currentThread().isInterrupted) {
                try {
                    val client = socket.accept() // blocks until connection
                    Log.i(TAG, "Accepted incoming L2CAP connection from ${client.remoteDevice?.address ?: "unknown"}")
                    callback.onClientConnected(client)
                } catch (e: IOException) {
                    if (!Thread.currentThread().isInterrupted) {
                        Log.w(TAG, "L2CAP accept error: ${e.message}")
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
        Log.i(TAG, "L2CAP server stopped")
    }
}
