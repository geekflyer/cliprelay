# Limitations and Known Issues

## Single Active Connection

The Mac app maintains only one active BLE connection at a time. If multiple paired Android devices are in range, the Mac connects to whichever device it discovers first during the BLE scan. The other devices are ignored until the active connection drops, at which point scanning resumes and connects to the next available device.

There is no priority, round-robin, or multi-device connection support.

## Rich Media Transfer

### Same Network Required

Image transfer uses TCP over the local network. Both devices must be on the same Wi-Fi network (or otherwise IP-reachable). There is no relay/cloud fallback — if the TCP connection fails, the transfer is dropped silently (auto-sync) or an error is shown (share sheet).

### Single-Blob Encryption

Images are encrypted as a single AES-256-GCM blob, requiring the entire image to be held in memory on both sides. This is acceptable for the current 10 MB limit but must be replaced with streaming/chunked encryption before supporting video or larger files.

### Images Only

Rich media transfer currently supports PNG and JPEG images only. TIFF images on macOS are converted to PNG before sending (Android has no native TIFF support). Other file types (PDF, video, documents) are not supported. The transport layer is content-agnostic and can be extended to other types in the future.

### No Progress Indication

There is no transfer progress UI. For large images on slow networks, the transfer may take several seconds with no visual feedback.

### IPv4 Only

The TCP transfer uses IPv4 addresses only. IPv6 LAN support is not implemented.
