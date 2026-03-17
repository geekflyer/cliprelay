package org.cliprelay.tcp

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUtil {
    fun getLocalIpAddress(): String? {
        val interfaces = NetworkInterface.getNetworkInterfaces()?.asSequence()
            ?.filter { it.isUp && !it.isLoopback }
            ?.toList() ?: return null

        // Prefer wlan/eth interfaces (typical Android Wi-Fi/Ethernet)
        val preferred = interfaces
            .filter { it.name.startsWith("wlan") || it.name.startsWith("eth") }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
            ?.hostAddress

        if (preferred != null) return preferred

        // Fallback: any non-loopback IPv4 address (e.g. en0 on macOS/desktop)
        return interfaces
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
            ?.hostAddress
    }
}
