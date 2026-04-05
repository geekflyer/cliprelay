import Foundation

enum TcpImageSender {
    /// Connects to a TCP server and sends the given data.
    static func send(host: String, port: UInt16, data: Data, connectTimeoutMs: Int = 3000) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TcpTransferError.sendFailed("socket() failed: \(errno)")
        }

        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw TcpTransferError.sendFailed("Invalid host address: \(host)")
        }

        // Set send timeout
        var tv = timeval()
        tv.tv_sec = connectTimeoutMs / 1000
        tv.tv_usec = Int32((connectTimeoutMs % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw TcpTransferError.sendFailed("connect() failed: \(errno)")
        }

        try data.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if n < 0 {
                    throw TcpTransferError.sendFailed("write() failed: \(errno)")
                }
                offset += n
            }
        }
    }
}
