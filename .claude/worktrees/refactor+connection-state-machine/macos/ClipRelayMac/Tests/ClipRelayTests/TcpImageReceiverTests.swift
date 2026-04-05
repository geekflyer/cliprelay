import XCTest
@testable import ClipRelay

final class TcpImageReceiverTests: XCTestCase {

    func testAcceptsConnectionAndReceivesExactBytes() throws {
        let payload = Data((0..<1024).map { UInt8($0 % 256) })
        let receiver = TcpImageReceiver(
            expectedSize: payload.count,
            allowedSenderIp: nil
        )

        let info = try receiver.start()
        defer { receiver.closeServer() }

        let expectation = self.expectation(description: "data received")
        var received: Data?
        var receiveError: Error?

        DispatchQueue.global().async {
            do {
                received = try receiver.receive()
            } catch {
                receiveError = error
            }
            expectation.fulfill()
        }

        // Give receiver time to start accepting
        Thread.sleep(forTimeInterval: 0.05)

        try TcpImageSender.send(host: "127.0.0.1", port: info.port, data: payload)

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNil(receiveError, "Unexpected error: \(receiveError!)")
        XCTAssertEqual(received, payload)
    }

    func testRejectsConnectionFromWrongIp() throws {
        let payload = Data(repeating: 0x42, count: 64)
        let receiver = TcpImageReceiver(
            expectedSize: payload.count,
            allowedSenderIp: "10.0.0.99", // won't match 127.0.0.1
            noConnectionTimeoutMs: 2000,
            maxConnections: 1
        )

        let info = try receiver.start()
        defer { receiver.closeServer() }

        let expectation = self.expectation(description: "receive completes")
        var receiveError: Error?

        DispatchQueue.global().async {
            do {
                _ = try receiver.receive()
            } catch {
                receiveError = error
            }
            expectation.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.05)

        // Connect from localhost (127.0.0.1) which doesn't match allowed IP
        try? TcpImageSender.send(host: "127.0.0.1", port: info.port, data: payload)

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(receiveError)
        XCTAssertTrue(receiveError is TcpTransferError, "Expected TcpTransferError, got \(type(of: receiveError!))")
    }

    func testTimesOutWhenNoConnection() throws {
        let receiver = TcpImageReceiver(
            expectedSize: 100,
            allowedSenderIp: nil,
            noConnectionTimeoutMs: 300
        )

        _ = try receiver.start()
        defer { receiver.closeServer() }

        XCTAssertThrowsError(try receiver.receive()) { error in
            guard case TcpTransferError.noConnection = error else {
                XCTFail("Expected noConnection error, got \(error)")
                return
            }
        }
    }
}
