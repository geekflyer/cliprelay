# Findings Tracker

> Combined from Claude and Codex reviews. Only unresolved items remain.

## Do Now

- [ ] **BLE abuse guardrails (Claude #10)**
  No BLE-level access control — any device can write to characteristics. Any BLE scanner can connect and write arbitrary bytes; AES-GCM decryption is the only defense, but the service still processes every write (JSON parsing, reassembly).
  - `android/.../ble/GattServerManager.kt`
  - Action: implement strict frame limits, fail-fast parsing, and rate limits while keeping app-layer pairing.

- [ ] **Reduce production logging verbosity (Codex)**
  Mac BLE includes detailed manufacturer/tag diagnostics and high-frequency event logs, increasing noise and leaking pairing metadata into logs.
  - `macos/ClipShareMac/Sources/BLE/BLECentralManager.swift`
  - Action: redact release logging; keep verbose diagnostics in debug builds only.

- [ ] **Improve tooling maturity and doc alignment (Codex)**
  CI/lint pipeline missing; protocol and security docs can drift from implementation.
  - `README.md`, `docs/protocol.md`
  - `android/.../crypto/E2ECrypto.kt`, `macos/.../Crypto/E2ECrypto.swift`
  - Action: add lightweight CI checks and keep docs aligned with implemented crypto/protocol behavior.

## Accept Risk

- [ ] **`ChunkHeader.encoding` decoded but never validated or used (Claude #27)**
  Both platforms store the `encoding` field but always hardcode UTF-8.
  - Rationale: kept for protocol forward compatibility.

- [ ] **`tx_id` parsed but never used on either platform (Claude #28)**
  Both platforms decode `tx_id` and discard it.
  - Rationale: kept for protocol compliance and future compatibility.

- [ ] **Metadata `size` and `type` fields ignored on receipt (Claude #29)**
  Both platforms extract only `hash` from `Available` metadata.
  - Rationale: kept until non-text payload handling is implemented.

- [ ] **`security-crypto:1.1.0-alpha06` is an alpha dependency (Claude #34)**
  Stable `1.0.0` has an incompatible API (`MasterKeys` vs `MasterKey.Builder`). The alpha release is the de-facto standard.
  - Rationale: keep until Google ships a stable version with the `MasterKey.Builder` API.

- [ ] **`sha256Hex` duplicated between BLECentralManager and ClipboardMonitor (Claude #37)**
  Two-line duplication across `macos/.../BLE/BLECentralManager.swift` and `macos/.../Clipboard/ClipboardMonitor.swift`.
  - Rationale: extracting to a shared utility adds more complexity than it saves.

## Defer (Refactor Cycle)

- [ ] **Reduce complexity in `BLECentralManager` (Codex)**
  Single file handles scan/connect/reconnect/chunking/crypto/dispatch/UI notifications.
  - `macos/ClipShareMac/Sources/BLE/BLECentralManager.swift`

- [ ] **Split large orchestrators into smaller responsibilities (Codex)**
  - `android/.../service/ClipShareService.kt`
  - `macos/ClipShareMac/Sources/BLE/BLECentralManager.swift`

- [ ] **Reduce protocol/chunking duplication across platforms (Codex)**
  Parallel implementations risk drift.
  - `android/.../ble/ChunkTransfer.kt`, `android/.../ble/ChunkReassembler.kt`
  - `macos/.../BLE/ChunkAssembler.swift`, `macos/.../BLE/BLECentralManager.swift`

- [ ] **Improve concurrency/control-flow scalability (Codex)**
  Android worker thread blocking and macOS main queue centralization could become bottlenecks.
  - `android/.../ble/GattServerManager.kt`, `android/.../service/ClipShareService.kt`
  - `macos/ClipShareMac/Sources/BLE/BLECentralManager.swift`
  - Defer unless profiling indicates pressure.
