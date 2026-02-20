package com.clipshare.pairing

import android.net.Uri

data class PairingInfo(val token: String, val deviceName: String?)

object PairingUriParser {
    fun parse(rawValue: String): PairingInfo? {
        val uri = Uri.parse(rawValue.trim())
        if (uri.scheme != "greenpaste" || uri.host != "pair") return null
        val token = uri.getQueryParameter("t") ?: return null
        if (token.length != 64) return null
        if (!token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        val deviceName = uri.getQueryParameter("n")?.takeIf { it.isNotBlank() }
        return PairingInfo(token.lowercase(), deviceName)
    }
}
