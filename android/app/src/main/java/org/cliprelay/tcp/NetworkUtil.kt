package org.cliprelay.tcp

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUtil {
    fun getLocalIpAddress(): String? {
        return NetworkInterface.getNetworkInterfaces()?.asSequence()
            ?.filter { it.isUp && !it.isLoopback }
            ?.filter { it.name.startsWith("wlan") || it.name.startsWith("eth") }
            ?.flatMap { it.inetAddresses.asSequence() }
            ?.filterIsInstance<Inet4Address>()
            ?.firstOrNull()
            ?.hostAddress
    }
}
