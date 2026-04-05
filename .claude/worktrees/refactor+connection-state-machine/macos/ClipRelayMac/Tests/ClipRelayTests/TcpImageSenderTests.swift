import XCTest
@testable import ClipRelay

final class TcpImageSenderTests: XCTestCase {

    func testSenderConnectsAndPushesData() throws {
        let payload = Data((0..<2048).map { UInt8($0 % 256) })

        // Start a simple TCP server using BSD sockets
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFd, 0)
        defer { close(serverFd) }

        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = Darwin.bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = listen(serverFd, 1)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(serverFd, sa, &addrLen)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        let expectation = self.expectation(description: "data received by server")
        var receivedData = Data()

        DispatchQueue.global().async {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else { return }
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(clientFd, &buffer, buffer.count)
                if n <= 0 { break }
                receivedData.append(contentsOf: buffer[0..<n])
            }
            expectation.fulfill()
        }

        try TcpImageSender.send(host: "127.0.0.1", port: port, data: payload)

        // Close our end so the server's read loop terminates
        // (sender already closed the socket in its defer)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(receivedData, payload)
    }

    func testSenderThrowsOnConnectionRefused() {
        XCTAssertThrowsError(
            try TcpImageSender.send(host: "127.0.0.1", port: 1, data: Data(repeating: 0, count: 10), connectTimeoutMs: 500)
        ) { error in
            XCTAssertTrue(error is TcpTransferError, "Expected TcpTransferError, got \(type(of: error))")
        }
    }
}
