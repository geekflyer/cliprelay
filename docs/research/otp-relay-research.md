# OTP Auto-Relay Research: Android 15+ Notification Redaction and Workarounds

## Problem Statement

We want ClipRelay to detect one-time passcodes (OTPs) arriving on the Android
phone and relay them to the paired Mac's clipboard automatically.

The obvious implementation — a `NotificationListenerService` that reads incoming
notifications (SMS apps, mail, messengers), extracts the code, and pushes it over
the existing BLE path — **does not work on Android 15+**.

## Why the notification-listener approach fails (Android 15+ OTP redaction)

Since Android 15, Android System Intelligence (ASI) classifies any notification it
believes contains a 2FA code as "sensitive." Content of sensitive notifications is
**withheld from untrusted `NotificationListenerService`s** — the listener receives
the literal placeholder `"sensitive notification content hidden"` instead of the
body. A listener is "trusted" only if it holds `RECEIVE_SENSITIVE_NOTIFICATIONS`.

This was verified on a real Android 16 device: `dumpsys notification --noredact`
showed the full Amex code (the `--noredact` flag bypasses redaction), while the
listener's own `onNotificationPosted` callback received redacted text. The redaction
is upstream of extraction, so it does not matter where the regex runs (phone or Mac)
— the code is stripped before it reaches the app.

Sources:
- https://www.androidauthority.com/android-15-two-factor-authentication-codes-3492585/
- https://www.androidpolice.com/android-15-stop-malware-from-stealing-otps/

## What ships today: SMS User Consent API (SMS only, Play-clean)

The current implementation (`android/app/src/main/java/org/cliprelay/otp/`) uses the
**SMS User Consent API** (`SmsRetriever.startSmsUserConsent`). This is a *different
channel* from notifications and is **not subject to redaction**. Flow:

1. Arm a ~5-minute listening window (`SmsOtpController.arm`).
2. On a matching inbound SMS, GMS broadcasts `SMS_RETRIEVED_ACTION`
   (`SmsUserConsentReceiver`).
3. A transparent `SmsConsentActivity` shows the system "Allow ClipRelay to read this
   message?" dialog. On approval it gets the full SMS, extracts only the code
   (`OtpExtractor`), and relays that over `ACTION_PUSH_TEXT`.
4. Re-arm on consume/timeout to keep listening.

Trade-offs: **SMS only** (no email/app OTPs), **one tap per code**, and requires
Google Play services. No SMS permission, no notification access, no Play-policy risk.

## The "watch profile" hack — how to unlock email OTP (NOT shipped)

`RECEIVE_SENSITIVE_NOTIFICATIONS` (the permission that makes a listener "trusted" and
receive **un-redacted** notifications, including Gmail/email OTPs) is auto-granted to
apps holding certain CompanionDeviceManager (CDM) roles. The semantically-correct role
for a phone↔Mac companion is `COMPANION_DEVICE_COMPUTER` — but it is **not obtainable
by a normal Play app**.

Protection levels read live off an Android 16 device
(`adb shell pm list permissions -f`):

| Permission | protectionLevel | Third-party app can hold? |
|---|---|---|
| `REQUEST_COMPANION_PROFILE_COMPUTER` | `signature\|privileged` | **No** (platform-signed / privileged only — this is why Phone Link can, we can't) |
| `REQUEST_COMPANION_PROFILE_APP_STREAMING` | `signature\|privileged` | No |
| `REQUEST_COMPANION_PROFILE_WATCH` | `normal` | **Yes** |
| `REQUEST_COMPANION_PROFILE_GLASSES` | `normal` | **Yes** |
| `RECEIVE_SENSITIVE_NOTIFICATIONS` | `signature\|preinstalled\|role\|knownSigner` | Yes, via a granting **role** |

Because `RECEIVE_SENSITIVE_NOTIFICATIONS` carries the `role` flag, holding the WATCH
or GLASSES companion role grants it. Wearable companion apps are the example Google
itself cited as still able to read OTPs
(https://x.com/MishaalRahman/status/1790791156122677549).

### The hack, concretely

1. Associate the Mac via `CompanionDeviceManager.associate()` with
   `AssociationRequest.setDeviceProfile(DEVICE_PROFILE_WATCH)` (needs only the
   `normal` `REQUEST_COMPANION_PROFILE_WATCH` permission).
2. The granted `COMPANION_DEVICE_WATCH` role carries `RECEIVE_SENSITIVE_NOTIFICATIONS`.
3. A `NotificationListenerService` now receives **un-redacted** notifications — SMS
   and email. Reinstate the notification-listener design (the `git`-removed
   `OtpNotificationListener` in this branch's history is a starting point) and reuse
   `OtpExtractor`.

### Why we did NOT ship it

1. **Play-policy risk (highest).** Using the watch profile on a non-watch device to
   defeat OTP redaction is textbook "circumventing a security control" — the most
   scrutinized area on the platform. Plausible rejection or removal for an app already
   on Play.
2. **Scary, dishonest consent.** The WATCH profile requests a bundle (Phone, SMS,
   Contacts, Calendar, Nearby devices). The system dialog says the app wants to
   *manage a watch*. Alarming and semantically false for a clipboard app.
3. **Overreach.** Pulls SMS/Contacts/Calendar grants we don't need, just to get the
   notification bit.

### When it would be viable

A **sideloaded / non-Play build** (the way ClipSync distributes) can hold the watch
role — or simply `RECEIVE_SMS` for the fully-silent, no-tap experience ClipSync gets —
without Play policy applying. That build is the right home for the fully-automatic,
email-included version. It cannot go on Play without becoming the default SMS handler
or being flagged for the watch-profile circumvention.

## Summary

| Approach | Third-party Play app? | Covers | Auto? | Verdict |
|---|---|---|---|---|
| Notification listener (plain) | Yes | — | — | Redacted on A15+, useless for OTP |
| **SMS User Consent (shipped)** | Yes | SMS only | one tap/code | Clean, works today |
| CDM COMPUTER profile | **No** (signature\|privileged) | SMS + email | silent | Can't obtain |
| CDM WATCH/GLASSES profile | Yes (normal) | SMS + email | silent | Works, but policy risk + scary UX |
| `RECEIVE_SMS` broadcast (ClipSync) | Sideload only | SMS | silent | Play-forbidden unless default SMS app |
