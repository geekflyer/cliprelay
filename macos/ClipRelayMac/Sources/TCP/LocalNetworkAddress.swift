import Foundation

enum LocalNetworkAddress {
    /// Returns the local IPv4 address on Wi-Fi (en0/en1) or nil if unavailable.
    static func getLocalIPv4Address() -> String? {
        getAllLocalIPv4Addresses().first
    }

    /// Returns all non-loopback IPv4 addresses, with en0/en1 interfaces listed first.
    static func getAllLocalIPv4Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var preferred: [String] = []
        var others: [String] = []

        var current = ifaddr
        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }

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
            if address.hasPrefix("127.") { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("en0") || name.hasPrefix("en1") {
                preferred.append(address)
            } else {
                others.append(address)
            }
        }

        // Deduplicate while preserving order (preferred first)
        var seen = Set<String>()
        return (preferred + others).filter { seen.insert($0).inserted }
    }
}
