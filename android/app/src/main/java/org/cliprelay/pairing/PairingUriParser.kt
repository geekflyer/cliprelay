package org.cliprelay.pairing

// Parses cliprelay:// pairing URIs from QR codes into a public key hex and optional device name.

import java.net.URI
import java.net.URLDecoder

data class PairingInfo(val publicKeyHex: String, val deviceName: String?)

object PairingUriParser {
    fun parse(rawValue: String): PairingInfo? {
        val uri = runCatching { URI(rawValue.trim()) }.getOrNull() ?: return null
        if (!uri.scheme.equals("cliprelay", ignoreCase = true)) return null
        if (!uri.host.equals("pair", ignoreCase = true)) return null

        val params = parseQuery(uri.rawQuery ?: return null)
        val publicKeyHex = params["k"] ?: return null
        if (publicKeyHex.length != 64) return null
        if (!publicKeyHex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        val deviceName = params["n"]?.takeIf { it.isNotBlank() }
        return PairingInfo(publicKeyHex.lowercase(), deviceName)
    }

    private fun parseQuery(rawQuery: String): Map<String, String> {
        if (rawQuery.isBlank()) return emptyMap()
        val params = linkedMapOf<String, String>()
        rawQuery.split("&").forEach { pair ->
            if (pair.isBlank()) return@forEach
            val idx = pair.indexOf('=')
            if (idx <= 0) return@forEach
            val rawKey = pair.substring(0, idx)
            val rawValue = pair.substring(idx + 1)
            val key = decodeQueryComponent(rawKey)
            val value = decodeQueryComponent(rawValue)
            params[key] = value
        }
        return params
    }

    private fun decodeQueryComponent(value: String): String {
        return runCatching {
            URLDecoder.decode(value, "UTF-8")
        }.getOrElse {
            value.replace('+', ' ')
        }
    }
}
