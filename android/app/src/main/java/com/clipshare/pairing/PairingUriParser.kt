package com.clipshare.pairing

import android.net.Uri
import android.util.Base64
import org.json.JSONObject

object PairingUriParser {
    fun parse(rawValue: String): PairingPayload? {
        val uri = Uri.parse(rawValue.trim())
        if (uri.scheme != "clipshare" || uri.host != "pair") {
            return null
        }

        val encodedPayload = uri.getQueryParameter("data") ?: return null
        val jsonBytes = decodePayload(encodedPayload) ?: return null
        val json = JSONObject(String(jsonBytes, Charsets.UTF_8))

        val token = json.optString("token")
        val serviceUuid = json.optString("serviceUUID")
            .ifBlank { json.optString("service_uuid") }
            .ifBlank { json.optString("serviceUuid") }
        val macPublicKey = json.optString("macPublicKey")
            .ifBlank { json.optString("mac_public_key") }

        if (token.isBlank() || serviceUuid.isBlank() || macPublicKey.isBlank()) {
            return null
        }

        return PairingPayload(
            token = token,
            serviceUUID = serviceUuid,
            macPublicKey = macPublicKey
        )
    }

    private fun decodePayload(encodedPayload: String): ByteArray? {
        val normalized = encodedPayload.replace(' ', '+')
        val flags = listOf(
            Base64.NO_WRAP,
            Base64.DEFAULT,
            Base64.URL_SAFE or Base64.NO_WRAP,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
        )

        flags.forEach { flag ->
            val decoded = runCatching { Base64.decode(normalized, flag) }.getOrNull()
            if (decoded != null) {
                return decoded
            }
        }

        return null
    }
}
