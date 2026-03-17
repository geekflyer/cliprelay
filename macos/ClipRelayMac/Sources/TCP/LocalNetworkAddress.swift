import Foundation

enum LocalNetworkAddress {
    /// Returns the local IPv4 address on Wi-Fi (en0/en1) or nil if unavailable.
    static func getLocalIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }

            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en0") || name.hasPrefix("en1") else { continue }

            let family = ifa.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                ifa.pointee.ifa_addr,
                socklen_t(ifa.pointee.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: hostname)
            // Skip loopback
            if address.hasPrefix("127.") { continue }
            return address
        }
        return nil
    }
}
