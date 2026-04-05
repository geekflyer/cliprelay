import Foundation

enum TcpTransferError: Error, LocalizedError {
    case serverNotStarted
    case noConnection(timeoutMs: Int)
    case noValidConnection(maxAttempts: Int)
    case transferCancelled
    case streamClosed(received: Int, expected: Int)
    case sendFailed(String)
    case receiveFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverNotStarted:
            return "TCP server not started"
        case .noConnection(let ms):
            return "No connection within \(ms)ms"
        case .noValidConnection(let n):
            return "No valid connection after \(n) attempts"
        case .transferCancelled:
            return "Transfer cancelled"
        case .streamClosed(let received, let expected):
            return "Stream closed after \(received) bytes, expected \(expected)"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        }
    }
}
