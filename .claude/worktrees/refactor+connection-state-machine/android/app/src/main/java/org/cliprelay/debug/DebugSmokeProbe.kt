package org.cliprelay.debug

// Records internal state to a JSON file for automated smoke test assertions (debug builds only).

import android.content.Context
import android.content.pm.ApplicationInfo
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

object DebugSmokeProbe {
    private const val FILE_NAME = "debug-smoke-state.json"
    private val lock = Any()

    fun reset(context: Context) {
        if (!isDebuggable(context)) return
        synchronized(lock) {
            writeState(context) {
                JSONObject()
                    .put("version", 1)
                    .put("updated_at_ms", System.currentTimeMillis())
                    .put("event_counter", 0)
                    .put("connected", false)
            }
        }
    }

    fun onPairingImported(context: Context, token: String, deviceName: String?) {
        if (!isDebuggable(context)) return
        synchronized(lock) {
            writeState(context) { current ->
                incremented(current)
                    .put("pairing_token_tail", token.takeLast(8))
                    .put("pairing_device_name", deviceName ?: JSONObject.NULL)
            }
        }
    }

    fun onConnectionChanged(context: Context, connected: Boolean) {
        if (!isDebuggable(context)) return
        synchronized(lock) {
            writeState(context) { current ->
                incremented(current)
                    .put("connected", connected)
            }
        }
    }

    fun onInboundClipboardApplied(context: Context, text: String) {
        if (!isDebuggable(context)) return
        synchronized(lock) {
            writeState(context) { current ->
                incremented(current)
                    .put("last_inbound_text", text)
                    .put("last_inbound_sha256", sha256Hex(text.toByteArray(Charsets.UTF_8)))
                    .put("last_inbound_at_ms", System.currentTimeMillis())
            }
        }
    }

    fun onOutboundClipboardPublished(context: Context, text: String) {
        if (!isDebuggable(context)) return
        synchronized(lock) {
            writeState(context) { current ->
                incremented(current)
                    .put("last_outbound_text", text)
                    .put("last_outbound_sha256", sha256Hex(text.toByteArray(Charsets.UTF_8)))
                    .put("last_outbound_at_ms", System.currentTimeMillis())
            }
        }
    }

    private fun incremented(current: JSONObject): JSONObject {
        val nextCounter = current.optInt("event_counter", 0) + 1
        current.put("event_counter", nextCounter)
        current.put("updated_at_ms", System.currentTimeMillis())
        return current
    }

    private fun readStateFile(context: Context): JSONObject {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.exists()) {
            return JSONObject()
                .put("version", 1)
                .put("event_counter", 0)
                .put("connected", false)
        }

        val text = runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
        if (text.isNullOrBlank()) {
            return JSONObject()
                .put("version", 1)
                .put("event_counter", 0)
                .put("connected", false)
        }
        return runCatching { JSONObject(text) }.getOrElse {
            JSONObject()
                .put("version", 1)
                .put("event_counter", 0)
                .put("connected", false)
        }
    }

    private fun writeState(context: Context, mutate: (JSONObject) -> JSONObject) {
        val file = File(context.filesDir, FILE_NAME)
        val current = readStateFile(context)
        val updated = mutate(current)
        runCatching {
            file.writeText(updated.toString(), Charsets.UTF_8)
        }
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { "%02x".format(it) }
    }

    private fun isDebuggable(context: Context): Boolean {
        return (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }
}
