# BLE Protocol: clipboard-sync v1 (MVP)

## UUIDs

- Service: `c10b0001-1234-5678-9abc-def012345678`
- Clipboard Available: `c10b0002-1234-5678-9abc-def012345678`
- Clipboard Data: `c10b0003-1234-5678-9abc-def012345678`

## Characteristic usage

- `Clipboard Available` (READ/WRITE/NOTIFY): transfer metadata
- `Clipboard Data` (READ/WRITE/NOTIFY): chunk header + chunk payload frames

## Payload format

- Available metadata JSON:
  - `{"hash":"<sha256>","size":123,"type":"text/plain","tx_id":"<id>"}`
- Chunk header JSON:
  - `{"tx_id":"<id>","total_chunks":N,"total_bytes":M,"encoding":"utf-8"}`
- Chunk frame:
  - `[2-byte big-endian index][payload bytes]`

Maximum payload: 100 KiB UTF-8 text.

## Reliability rules

- Transfer is atomic.
- If disconnect occurs before all chunks arrive, partial data is discarded.
- On reconnect, sender publishes the next full transfer.

## Security model (MVP)

- Pairing is QR-based using a shared 64-char hex token (`cliprelay://pair?t=<token>&n=<name>`).
- Application-layer encryption is always enabled with AES-256-GCM.
- Key derivation uses HKDF-SHA256 with the token bytes as input key material:
  - Encryption key: `HKDF(ikm=token, info="cliprelay-enc-v1", len=32)`
  - Device tag: `HKDF(ikm=token, info="cliprelay-tag-v1", len=8)`
- AAD is fixed to `cliprelay-v1`.
- Ciphertext wire format is `[12-byte nonce][ciphertext + 16-byte GCM tag]`.
