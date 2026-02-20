package com.clipshare.pairing

import android.net.Uri

object PairingUriParser {
    /**
     * Parse a greenpaste://pair?t=<hex-token> URI and return the token.
     */
    fun parse(rawValue: String): String? {
        val uri = Uri.parse(rawValue.trim())
        if (uri.scheme != "greenpaste" || uri.host != "pair") return null
        val token = uri.getQueryParameter("t") ?: return null
        if (token.length != 64) return null
        if (!token.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return token.lowercase()
    }
}
