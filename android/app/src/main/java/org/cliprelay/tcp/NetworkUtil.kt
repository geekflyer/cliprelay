package org.cliprelay.tcp

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUtil {
    fun getLocalIpAddress(): String? = getAllLocalIpAddresses().firstOrNull()

    /**
     * Returns all non-loopback IPv4 addresses, with wlan/eth interfaces listed first.
     */
    fun getAllLocalIpAddresses(): List<String> {
        val interfaces = NetworkInterface.getNetworkInterfaces()?.asSequence()
            ?.filter { it.isUp && !it.isLoopback }
            ?.toList() ?: return emptyList()

        // Prefer wlan/eth interfaces (typical Android Wi-Fi/Ethernet)
        val preferred = interfaces
            .filter { it.name.startsWith("wlan") || it.name.startsWith("eth") }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }

        val others = interfaces
            .filter { !it.name.startsWith("wlan") && !it.name.startsWith("eth") }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }

        return (preferred + others).distinct()
    }
}
