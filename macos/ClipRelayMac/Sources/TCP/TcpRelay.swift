// TCP helper for rich media transfer: server (send) and client (fetch) operations.

import Foundation

enum TcpRelay {
    class TcpServer {
        let port: UInt16
        private let socketFD: Int32

        init(timeoutSeconds: TimeInterval = 30) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TcpError.socketCreationFailed }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0  // random port
            addr.sin_addr.s_addr = INADDR_ANY

            var bindResult: Int32 = -1
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindResult = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bindResult == 0 else { Darwin.close(fd); throw TcpError.bindFailed }

            listen(fd, 1)

            // Get assigned port
            var boundAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &boundAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
            }

            // Set timeout
            var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            // Assign stored properties last (after all failable operations)
            self.socketFD = fd
            self.port = UInt16(bigEndian: boundAddr.sin_port)
        }

        func sendAndClose(_ data: Data) throws {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { Darwin.close(socketFD); throw TcpError.acceptFailed }
            defer { Darwin.close(clientFD); Darwin.close(socketFD) }

            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let n = send(clientFD, base + sent, data.count - sent, 0)
                    guard n > 0 else { throw TcpError.sendFailed }
                    sent += n
                }
            }
        }

        func close() {
            Darwin.close(socketFD)
        }
    }

    static func fetch(host: String, port: UInt16, size: Int, timeoutSeconds: TimeInterval = 30) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TcpError.socketCreationFailed }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connectResult == 0 else { throw TcpError.connectFailed }

        var buffer = Data(count: size)
        var received = 0
        while received < size {
            let n = buffer.withUnsafeMutableBytes { rawBuffer in
                recv(fd, rawBuffer.baseAddress! + received, size - received, 0)
            }
            guard n > 0 else { throw TcpError.receiveFailed }
            received += n
        }
        return buffer
    }

    static func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            return String(cString: hostname)
        }
        return nil
    }

    enum TcpError: Error {
        case socketCreationFailed, bindFailed, acceptFailed, sendFailed
        case connectFailed, receiveFailed
    }
}
