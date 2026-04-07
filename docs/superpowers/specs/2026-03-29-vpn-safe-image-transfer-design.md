# VPN-Safe TCP Image Transfer

**Date:** 2026-03-29
**Status:** Approved

## Problem

When a VPN (NordVPN, Tailscale, etc.) is active on either device, TCP image transfers fail. The VPN installs a default route that captures all IP traffic, routing connections to LAN peer IPs through the VPN tunnel where they're unreachable.

Both sides correctly discover their WiFi LAN IPs (Mac filters to `en0`/`en1`, Android to `wlan*`/`eth*`), but the OS routes the TCP `connect()` call through the VPN interface instead of WiFi.

## Solution

Two changes:

### 1. Bind outbound TCP sockets to the LAN IP

Before calling `connect()`, call `bind()` on the socket to the local WiFi IP. This forces the OS to route via the WiFi interface regardless of VPN routing table entries.

- **Mac (`TcpImageSender.swift`):** After `socket()`, bind to `LocalNetworkAddress.getLocalIPv4Address()` before `connect()`. If bind fails (no WiFi IP), skip binding (graceful degradation).
- **Android (`TcpImageSender.kt`):** Before `socket.connect()`, call `socket.bind(InetSocketAddress(NetworkUtil.getLocalIpAddress(), 0))`. Same graceful fallback.

### 2. Replace IP validation with a per-transfer TCP nonce

Current IP-based sender validation is fragile with VPNs. Replace it with a cryptographic challenge:

1. Receiver generates 16 random bytes when starting the TCP server.
2. Receiver includes `"tcpNonce"` (hex-encoded) in the BLE ACCEPT message (already encrypted end-to-end).
3. Sender writes the 16-byte nonce as the first bytes of the TCP stream, before the encrypted image data.
4. Receiver reads the first 16 bytes, constant-time compares against the expected nonce:
   - **Match:** proceed to read image data.
   - **Mismatch:** close connection, accept next attempt (up to `maxConnections`).

**Why per-transfer random (not derived from session key):** The nonce is visible on the WiFi network as the first 16 bytes of the TCP stream. A random nonce is single-use — by the time an attacker sniffs it, the real sender has already connected and the nonce will never be reused. A session-key-derived value would be the same every transfer, allowing replay-based DoS.

### Backward compatibility

No protocol version bump. The change is backward-compatible:

- **OFFER:** Keep sending `senderIp` (for old receivers that still check it).
- **ACCEPT:** Add optional `tcpNonce` field.
- **Sender:** If `tcpNonce` is present in ACCEPT, send it as TCP preamble. If absent (old receiver), skip it.
- **Receiver:** If it generated a `tcpNonce`, validate it. If the connecting sender doesn't send a valid nonce (old sender), fall back to IP validation using `senderIp` from the OFFER.

When both clients are updated, the nonce path is always used and IP validation is never reached. An attacker cannot force the fallback — they don't control the ACCEPT message (encrypted BLE channel).

**Deprecation:** The IP validation fallback MUST be removed on or after May 1st 2026. Add `// TODO(2026-05-01): Remove IP validation fallback — all clients should support tcpNonce by now` in all relevant code paths.

## Files changed

1. `macos/.../TCP/TcpImageSender.swift` — source bind + send nonce prefix
2. `macos/.../TCP/TcpImageReceiver.swift` — verify nonce, IP validation fallback (deprecated)
3. `android/.../tcp/TcpImageSender.kt` — source bind + send nonce prefix
4. `android/.../tcp/TcpImageReceiver.kt` — verify nonce, IP validation fallback (deprecated)
5. `macos/.../Protocol/Session.swift` — generate nonce in accept, parse nonce from accept
6. `android/.../protocol/Session.kt` — same

## What stays the same

- IP discovery logic (still needed for `tcpHost`/`tcpPort` in ACCEPT)
- BLE signaling flow (OFFER -> ACCEPT -> TCP transfer -> DONE)
- AES-256-GCM encryption of image data
- SHA-256 hash verification after decryption
- Size limits (10 MB), timeouts, retry logic
