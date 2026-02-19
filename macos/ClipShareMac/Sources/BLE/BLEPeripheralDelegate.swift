import CoreBluetooth

protocol BLEPeripheralDelegate: AnyObject {
    func didReceiveClipboardPushChunk(_ data: Data)
    func didUpdateConnectionState(_ connected: Bool)
}
