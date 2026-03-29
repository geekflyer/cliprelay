import Foundation

struct TcpServerInfo {
    let host: String
    let port: UInt16
}

final class TcpImageReceiver {
    private let expectedSize: Int
    private let allowedSenderIp: String?
    private let tcpNonce: Data?
    private let noConnectionTimeoutMs: Int
    private let transferTimeoutMs: Int
    private let maxConnections: Int

    private var serverFd: Int32 = -1
    private var cancelled = false
    private let lock = NSLock()

    init(
        expectedSize: Int,
        allowedSenderIp: String?,
        tcpNonce: Data? = nil,
        noConnectionTimeoutMs: Int = 30_000,
        transferTimeoutMs: Int = 120_000,
        maxConnections: Int = 2
    ) {
        self.expectedSize = expectedSize
        self.allowedSenderIp = allowedSenderIp
        self.tcpNonce = tcpNonce
        self.noConnectionTimeoutMs = noConnectionTimeoutMs
        self.transferTimeoutMs = transferTimeoutMs
        self.maxConnections = maxConnections
    }

    func start() throws -> TcpServerInfo {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw TcpTransferError.receiveFailed("socket() failed: \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(serverFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-assigned
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw TcpTransferError.receiveFailed("bind() failed: \(errno)")
        }

        guard listen(serverFd, 2) == 0 else {
            close(serverFd)
            throw TcpTransferError.receiveFailed("listen() failed: \(errno)")
        }

        // Get assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(serverFd, sa, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        let localIp = LocalNetworkAddress.getLocalIPv4Address() ?? "0.0.0.0"
        return TcpServerInfo(host: localIp, port: port)
    }

    func receive() throws -> Data {
        guard serverFd >= 0 else {
            throw TcpTransferError.serverNotStarted
        }

        var attemptsLeft = maxConnections
        while attemptsLeft > 0 {
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            if isCancelled { throw TcpTransferError.transferCancelled }

            attemptsLeft -= 1

            // Use poll() for accept timeout since SO_RCVTIMEO doesn't affect accept() on macOS
            var pfd = pollfd(fd: serverFd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(noConnectionTimeoutMs))
            if pollResult == 0 {
                throw TcpTransferError.noConnection(timeoutMs: noConnectionTimeoutMs)
            }
            if pollResult < 0 {
                lock.lock()
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { throw TcpTransferError.transferCancelled }
                throw TcpTransferError.receiveFailed("poll() failed: \(errno)")
            }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverFd, sa, &clientAddrLen)
                }
            }

            if clientFd < 0 {
                lock.lock()
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { throw TcpTransferError.transferCancelled }
                throw TcpTransferError.receiveFailed("accept() failed: \(errno)")
            }

            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            // Validate connection
            if let nonce = tcpNonce {
                // Nonce-based validation: read first 16 bytes and constant-time compare
                setReceiveTimeout(fd: clientFd, ms: transferTimeoutMs)
                do {
                    let receivedNonce = try readExactly(fd: clientFd, size: 16)
                    // Constant-time comparison to prevent timing attacks
                    var mismatch: UInt8 = 0
                    for i in 0..<16 {
                        mismatch |= receivedNonce[i] ^ nonce[i]
                    }
                    if mismatch != 0 {
                        close(clientFd)
                        continue
                    }
                } catch {
                    close(clientFd)
                    continue
                }
            } else {
                // TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now
                if let allowed = allowedSenderIp {
                    var remoteHostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    withUnsafePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = getnameinfo(sa, clientAddrLen, &remoteHostname,
                                            socklen_t(remoteHostname.count), nil, 0, NI_NUMERICHOST)
                        }
                    }
                    let remoteIp = String(cString: remoteHostname)
                    if remoteIp != allowed {
                        close(clientFd)
                        continue
                    }
                }
            }

            // Set transfer timeout
            setReceiveTimeout(fd: clientFd, ms: transferTimeoutMs)

            do {
                let data = try readExactly(fd: clientFd, size: expectedSize)
                close(clientFd)
                return data
            } catch {
                close(clientFd)
                throw error
            }
        }

        throw TcpTransferError.noValidConnection(maxAttempts: maxConnections)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        closeServer()
    }

    func closeServer() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }

    // MARK: - Private

    private func setReceiveTimeout(fd: Int32, ms: Int) {
        var tv = timeval()
        tv.tv_sec = ms / 1000
        tv.tv_usec = Int32((ms % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readExactly(fd: Int32, size: Int) throws -> Data {
        var buffer = Data(count: size)
        var offset = 0
        while offset < size {
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            if isCancelled { throw TcpTransferError.transferCancelled }

            let n = buffer.withUnsafeMutableBytes { rawPtr in
                let ptr = rawPtr.baseAddress!.advanced(by: offset)
                return read(fd, ptr, size - offset)
            }
            if n == 0 {
                throw TcpTransferError.streamClosed(received: offset, expected: size)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw TcpTransferError.receiveFailed("Transfer timed out after \(transferTimeoutMs)ms")
                }
                throw TcpTransferError.receiveFailed("read() failed: \(errno)")
            }
            offset += n
        }
        return buffer
    }
}
