# Test Plan

## Goal
Build a reliable automated test baseline in this order:
1. Tier-1 unit tests for pure logic on Android and macOS
2. Tier-2 cross-platform protocol contract tests with shared fixtures
3. Optional BLE state-machine tests after seam extraction

## Checklist

### Phase 0 - Preflight cleanup (minimal)
- [x] Delete dead file `android/app/src/main/java/com/clipshare/models/ClipboardContent.kt`
- [x] Delete dead file `macos/ClipShareMac/Sources/Models/ClipboardContent.swift`
- [x] Remove unused import in `android/app/src/main/java/com/clipshare/service/ClipShareService.kt`
- [x] Remove unused string `status_running` from `android/app/src/main/res/values/strings.xml`
- [x] Update stale security note in `docs/protocol.md`

### Phase 1 - Android Tier-1 tests
- [x] Add Android local unit test setup in `android/app/build.gradle.kts`
- [x] Make `PairingUriParser` JVM-testable (no `android.net.Uri` dependency)
- [x] Add tests for `E2ECrypto`
- [x] Add tests for `ChunkTransfer`
- [x] Add tests for `ChunkReassembler`
- [x] Add tests for `PairingUriParser`

### Phase 2 - macOS Tier-1 tests
- [x] Add test target in `macos/ClipShareMac/Package.swift`
- [x] Add tests for `E2ECrypto`
- [x] Add tests for `ChunkAssembler`

### Phase 3 - Tier-2 cross-platform contract fixtures
- [x] Add shared fixture folder `test-fixtures/protocol/v1/`
- [x] Add fixture with token, plaintext, encrypted blob, and expected chunk data frames
- [x] Add Android fixture-driven compatibility tests
- [x] Add macOS fixture-driven compatibility tests

### Phase 4 - Verification
- [x] Run Android unit tests: `./android/gradlew testDebugUnitTest`
- [x] Run macOS tests: `swift test --package-path macos/ClipShareMac`
- [x] Run full rebuild: `./scripts/build-all.sh`

### Phase 5 - Optional later work
- [ ] Extract BLE state-machine logic from platform APIs
- [ ] Add reconnect/slot cleanup tests (disconnect/reconnect cycles)
- [ ] Add partial-transfer discard tests at state-machine layer
- [ ] Add hardware smoke script/checklist for real Android device + macOS host
- [ ] Run manual BLE smoke pass (Mac->Android copy, Android Share->Mac, reconnect after Bluetooth toggle)

## Notes
- AES-GCM encryption uses random nonces in production; compatibility fixtures should focus on decrypt/reassemble behavior and deterministic chunk framing from known blobs.
- Keep refactors minimal until baseline tests are in place.
