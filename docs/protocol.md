# BLE Protocol: clipboard-sync v1

## UUIDs

- Service: `c10b0001-1234-5678-9abc-def012345678`
- Clipboard Available: `c10b0002-1234-5678-9abc-def012345678`
- Clipboard Data: `c10b0003-1234-5678-9abc-def012345678`
- Clipboard Push: `c10b0004-1234-5678-9abc-def012345678`
- Device Info: `c10b0005-1234-5678-9abc-def012345678`

## Payload format

- `Clipboard Available`: UTF-8 JSON `{"hash":"...","size":123,"type":"text/plain"}`
- Chunk header (first message): UTF-8 JSON `{"total_chunks":N,"total_bytes":M,"encoding":"utf-8"}`
- Chunk frame: `[2-byte big-endian index][payload bytes]`

Maximum plaintext payload is 100 KiB.

## Encryption

- Key agreement: X25519
- AEAD: AES-256-GCM
- Per-message random 12-byte nonce
- AAD: UTF-8 string `clipboard-sync-v1`
