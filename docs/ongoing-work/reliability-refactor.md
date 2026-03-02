# BLE Reliability Refactor + Protocol V2 Plan

## Decision Summary

- We will do a full reliability refactor of BLE transport and orchestration.
- We will do a clean protocol cutover to v2 (no backward compatibility fallback).
- Work will happen on a dedicated branch:
  - `refactor/ble-protocol-v2-reliability`
- Goal is to stop patch churn and move to explicit, testable state machines.
- We will keep app-level `PING`/`PONG` in v2 as a session-health signal with conservative escalation (not a hair-trigger disconnect).

## Why We Are Doing This

Recent connection and transfer regressions show recurring instability in both directions (especially Mac -> Android).
Current BLE orchestration is overly centralized and stateful, with multiple timers, watchdogs, and reconnect paths interacting in non-obvious ways.

Observed symptoms:
- Transfer regressions reappear after seemingly unrelated BLE changes.
- Connection flapping and multiple competing peripheral identities.
- Hard-to-debug outcomes where writes are attempted but not observed on receiver callbacks.
- Reliability depends on side-effect timing rather than explicit protocol/session state.

## Goals

1. Deterministic connection lifecycle
   - Exactly one active session per paired token.
   - No competing reconnect loops.
2. Deterministic transfer lifecycle
   - Explicit start/chunk/end/result semantics.
   - Idempotent transfer IDs and dedupe.
3. Deterministic failure semantics
   - Explicit terminal errors (`timeout`, `out_of_order`, `decrypt_fail`, `peer_reset`, etc.).
4. Operational reliability
   - Pass repeated hardware stress and reconnect cycles consistently.
5. Observability
   - Session/transfer-correlated logs and automatic diagnostics on failure.

## Non-Goals

- Preserving protocol v1 compatibility in runtime.
- Shipping incremental one-off fixes to existing v1 architecture during this effort.
- UI redesign (only minimal UI/service behavior changes required for protocol/cutover support).

## Scope

### In Scope
- macOS BLE architecture refactor.
- Android BLE architecture refactor.
- New protocol v2 framing and state machines.
- New service/characteristic UUID set for v2.
- Pairing reset strategy for clean cutover.
- Test and stress gate upgrades.

### Out of Scope
- Cross-version interop.
- Background sync policy redesign beyond what is required for reliable transport.
- Unrelated feature work.

## First Principles and Invariants

1. One paired token maps to one canonical peer identity.
2. One canonical peer identity has at most one active session.
3. Session handshake must complete before any clipboard payload transfer.
4. Every transfer has a unique transfer ID and a terminal result.
5. No implicit success by absence of error.
6. Reconnect attempts are single-owner, bounded, and observable.
7. Recovery behavior is explicit and state-driven, not timer-race-driven.

## Target Architecture

### macOS

Initial split (keep this lean for a two-device app):

- `BleConnectionController`
  - Discovery + connection lifecycle + reconnect policy ownership.
- `BleSessionTransferEngine`
  - Session FSM + transfer FSM + framing/retry/timeout handling.
- `BlePeerRegistry`
  - Token/tag/canonical peer mapping and persistence bridge.

`BLECentralManager` becomes a thin orchestrator/composition root.

### Android

Initial split (avoid over-fragmentation):

- `ClipRelayService` (thinner shell)
  - Process lifecycle, permissions, foreground service responsibilities.
- `GattRuntime`
  - GATT server and advertiser lifecycle.
- `SessionTransferEngine`
  - Session FSM + transfer FSM + clipboard bridge.

Further decomposition is allowed later if complexity still grows.

## Protocol V2 (Clean Cutover)

### Transport Surface

- New BLE service UUID and characteristic UUIDs for v2.
- Separate control and data channels (logical separation; physical chars as appropriate).
- No v1 UUID reuse to avoid accidental mixed behavior.

### Message Types (Draft)

Control:
- `HELLO`
- `READY`
- `PING`
- `PONG`
- `ABORT`

Transfer:
- `TX_START`
- `TX_ACCEPT`
- `TX_REJECT`
- `TX_CHUNK`
- `TX_END`
- `TX_RESULT`

### Wire Format V2 (Lock Early)

Use one canonical binary frame format on both platforms:

- Header (fixed 16 bytes):
  - `version` (u8)
  - `type` (u8)
  - `flags` (u8)
  - `header_len` (u8, always `16`)
  - `session_id` (u32, big-endian)
  - `transfer_id` (u32, big-endian)
  - `sequence` (u16, big-endian)
  - `payload_len` (u16, big-endian)
- Payload (`payload_len` bytes)
- Trailer:
  - `frame_crc32` (u32, big-endian) over `header + payload`

Rules:
- Endianness is always big-endian (network order).
- Unknown `type` is rejected with protocol error.
- `payload_len` over configured max is rejected immediately.

### Required Fields

- `protocol_version` (fixed to v2)
- `session_id`
- `transfer_id`
- `sequence` (for chunks)
- `payload_length`
- `checksum/hash` (chunk or whole-transfer integrity marker as needed)
- `error_code` (for `TX_RESULT` failures)
- `reject_reason` (for `TX_REJECT`)

### Transfer Contract

1. Sender sends `TX_START`.
2. Receiver responds with `TX_ACCEPT` or `TX_REJECT(reason)`.
3. Sender sends ordered chunks (`TX_CHUNK`) only after `TX_ACCEPT`.
4. Sender sends `TX_END`.
5. Receiver validates and returns `TX_RESULT(ok|error_code)`.
6. Sender treats transfer as successful only on `TX_RESULT(ok)`.
7. Duplicate `transfer_id` handling is idempotent (same outcome, no double-apply).

### Timeouts and Retry

- Session handshake timeout.
- Per-transfer timeout.
- Per-chunk send window/timeout.
- Bounded retry budget; terminal failure on exhaustion.
- Explicit abort path resets transfer FSM safely.

### Session Liveness (`PING`/`PONG`) Policy

`PING`/`PONG` is useful for detecting protocol/session stalls that BLE link supervision does not always expose quickly.

Policy:
- Idle heartbeat cadence: every 25-30s when no active transfer.
- One missed pong: mark session `degraded` (observe only, no disconnect).
- Repeated misses (for example 3 consecutive) plus no session progress: trigger controlled session reset/reconnect.
- Suppress heartbeat escalation during active transfer.
- Never force disconnect on a single missed pong.

## Clean Cutover Plan

1. Implement protocol v2 on both platforms behind compile/runtime flag.
2. Add v2 UUIDs and switch both sides to v2 as default.
3. On release cut, apply explicit re-pair UX flow:
   - On startup, if only v1 pairing state exists, show "Re-pair required" state.
   - Auto-clear v1 pairing/runtime BLE state.
   - Enter pairing mode immediately on both apps.
   - Do not attempt mixed v1/v2 transport.
4. Require one-time re-pair for all users.
5. Remove v1 code paths after stabilization window.

## Test Strategy

### Unit and Component

- FSM transition tests (session + transfer) for legal/illegal transitions.
- Parser/encoder tests for all v2 frame types.
- Retry/timeout and dedupe behavior tests.
- Error code propagation tests.
- Wire-format round-trip tests for endianness and CRC correctness.

### Cross-Platform Compatibility

- Shared protocol fixtures (golden frames) validated by:
  - macOS tests
  - Android tests
- Include negative fixtures:
  - bad CRC
  - unknown type
  - invalid length
  - out-of-order sequence

### Hardware E2E Gates

Must pass before merge:
1. Standard smoke test.
2. Mac -> Android stress loop (`hardware-m2a-stress-test.sh`) at target iteration count.
3. Reconnect-cycle stress.
4. Consecutive pass threshold (for example, 3 clean consecutive runs).

## Observability and Diagnostics

- Structured logs must include:
  - `peer_token_suffix`, `session_id`, `transfer_id`, `state`, `event`, `result`
- Preserve automatic failure dumps in hardware scripts:
  - Android probe state
  - Android BLE logs
  - macOS ClipRelay logs
- Add protocol-level counters:
  - transfers started/succeeded/failed
  - retries
  - session resets
  - heartbeat degraded events

## Implementation Phases

### Phase 0 (Lightweight, Same-Day)
- Finalize frame schema, FSM diagrams, and error taxonomy.
- Keep this lightweight: design artifacts should land as tests/fixtures and concise docs, not heavy process overhead.

### Phase 1: Protocol V2 Library and Fixtures
- Implement framing/parser/validator on both platforms.
- Add golden and negative fixture tests.

### Phase 2: Runtime Refactor
- Introduce new architecture boundaries on macOS and Android.
- Wire v2 session/transfer FSMs.

### Phase 3: Cutover Mechanics
- Switch to v2 UUIDs, enforce re-pair behavior.
- Remove/disable v1 path in runtime.

### Phase 4: Reliability Hardening
- Tune timeouts/retries/heartbeat escalation based on stress and reconnect runs.
- Eliminate flapping and nondeterministic transition behavior.

### Phase 5: Stabilization and Merge
- Hit hardware and test gates.
- Finalize docs and operational runbooks.

## Risks and Mitigations

- Risk: big change surface increases short-term instability.
  - Mitigation: FSM-first, fixture-first, phased integration, strict gates.
- Risk: hidden platform BLE quirks still surface late.
  - Mitigation: deterministic logging, stress loops, reconnect soak tests.
- Risk: heartbeat policy causes false positives.
  - Mitigation: conservative escalation, no single-miss disconnects, suppress during active transfers.
- Risk: cutover friction due to re-pair requirement.
  - Mitigation: explicit in-app re-pair UX and one-shot reset automation.

## Definition of Done

- Build and test suites green on both platforms.
- Hardware smoke + stress + reconnect gates pass consistently.
- No known flapping pattern under normal operation.
- Mac -> Android transfer success is deterministic under stress.
- Protocol v2 docs and troubleshooting docs updated.
- Team confidence restored: no recurring 48-hour regressions from BLE changes.

## Initial Execution Checklist

- [ ] Create branch `refactor/ble-protocol-v2-reliability`
- [ ] Lock wire format (header fields, endianness, CRC) in tests/fixtures
- [ ] Add protocol v2 FSM docs + fixtures (including negative cases)
- [ ] Implement v2 frame codecs + fixture tests
- [ ] Refactor macOS runtime boundaries
- [ ] Refactor Android runtime boundaries
- [ ] Wire session FSM and transfer FSM end-to-end
- [ ] Implement conservative `PING`/`PONG` degradation policy
- [ ] Enable clean cutover + explicit re-pair UX flow
- [ ] Run full reliability gate suite
- [ ] Merge only after consecutive pass threshold
