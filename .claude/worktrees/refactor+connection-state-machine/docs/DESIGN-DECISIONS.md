# Design Decisions & Trade-offs

Intentional choices made during development, with rationale. This is a living document — add new entries as decisions are made.

---

## BLE Transport: L2CAP Only, No GATT Fallback

**Date:** 2026-03-03
**Status:** Active

ClipRelay uses L2CAP Connection-Oriented Channels as its sole BLE transport. There is no GATT-based chunked transfer fallback.

**Why:**
- L2CAP CoC provides a TCP-like byte stream, eliminating manual chunking, reassembly, MTU negotiation, and notification subscription management.
- A GATT fallback would add ~2,500 lines across both platforms (10 new files, 3 modified) — roughly 2.2x the complexity of the current transport layer — almost entirely for chunking/reassembly plumbing.
- The Session and protocol layers are transport-agnostic (generic InputStream/OutputStream), so a GATT fallback could be added later if needed without touching protocol code.

**Trade-off:** Devices with unreliable L2CAP CoC implementations (primarily phones from 2018-2019 that were upgraded to Android 10) are not supported. This is acceptable because these devices are aging out of the market.

---

## Android Minimum SDK: API 30 (Android 11)

**Date:** 2026-03-03
**Status:** Active

The minimum Android version is API 30 (Android 11), not API 29 (Android 10) where the L2CAP API was introduced.

**Why:**
- `listenUsingInsecureL2capChannel()` was added in API 29, but devices that were upgraded to Android 10 from older OS versions (Galaxy S9, S10, etc.) have unreliable BLE firmware for L2CAP CoC.
- API 30 eliminates this "upgraded-to-Android-10" device class while still covering ~83% of active Android devices.
- The practical Samsung floor becomes the Galaxy S20/S21 generation, which shipped with Android 10/11 natively and has reliable L2CAP support.

**Trade-off:** ~17% of Android devices running Android 10 are excluded. These are primarily 2018-2019 era phones.

---

## Insecure L2CAP with App-Layer Encryption

**Date:** 2026-03-03
**Status:** Active

ClipRelay uses `listenUsingInsecureL2capChannel()` (no BLE-level encryption) and implements its own AES-256-GCM encryption at the application layer.

**Why:**
- Secure (BLE-level encrypted) L2CAP channels are unreliable cross-platform. The secure variants effectively fail on most real Android devices.
- App-layer AES-256-GCM with HKDF-SHA256 key derivation from the pre-shared pairing token provides equivalent confidentiality and integrity.
- This is the same approach used by Ditto (ditto.live) in production across iOS, Android, and macOS.

**Trade-off:** Relies on correct implementation of app-layer crypto rather than OS-provided BLE encryption. Mitigated by using standard library primitives (Android: javax.crypto, macOS: CryptoKit).

---

## QR-Based Pairing, No BLE Bonding

**Date:** 2026-03-03
**Status:** Active

Pairing is done via QR code (256-bit pre-shared token) rather than standard BLE bonding/pairing.

**Why:**
- BLE bonding behavior varies across OS versions and devices, causing unpredictable pairing dialogs and bond failures.
- QR-based token exchange is deterministic — scan succeeds or it doesn't.
- Device identification uses a tag derived from the shared token (HKDF), not BLE addresses, so BLE address rotation doesn't break discovery.

**Trade-off:** Requires camera access and physical proximity for initial pairing. Re-pairing requires scanning a new QR code.

---

## Mac as Central, Android as Peripheral

**Date:** 2026-03-03
**Status:** Active

The Mac always acts as the BLE Central (scanner/initiator) and Android always acts as the Peripheral (advertiser/acceptor).

**Why:**
- Eliminates connection races by having a single owner of the connection lifecycle.
- macOS CoreBluetooth is a more mature and reliable Central implementation than Android's.
- Android BLE advertising is well-supported and doesn't require foreground activity.

**Trade-off:** Android-to-Android or Mac-to-Mac pairing is not supported. Only one connection topology exists.

---

## No Partial Transfer Resume

**Date:** 2026-03-03
**Status:** Active

If a clipboard transfer is interrupted (BLE disconnect mid-transfer), it restarts from scratch on reconnect.

**Why:**
- Maximum payload is 100 KB of text, which transfers in 3-10 seconds even with Android's DLE limitation.
- Resume logic (tracking offsets, handling stale partial data) adds significant complexity for minimal gain.
- Deduplication by content hash means duplicate delivery is harmless.

**Trade-off:** A 100 KB transfer interrupted at 99% must restart fully. At worst this wastes ~10 seconds.
