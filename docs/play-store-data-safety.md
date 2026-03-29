# Play Store Data Safety Questionnaire — Answers

## Data collection and security

**Does your app collect or share any of the required user data types?**
→ No

**Is all of the user data collected by your app encrypted in transit?**
→ Yes (AES-256-GCM over Bluetooth Low Energy)

**Do you provide a way for users to request that their data is deleted?**
→ Not applicable (no data is collected or stored remotely)

## Data types — NONE collected

For every data type category (Location, Personal info, Financial info,
Health and fitness, Messages, Photos and videos, Audio, Files and docs,
Calendar, Contacts, App activity, Web browsing, App info and performance,
Device or other IDs):

→ **Not collected** for all categories.

## Notes

ClipRelay transfers clipboard text directly between paired devices over
Bluetooth Low Energy. All communication is end-to-end encrypted with
AES-256-GCM using keys established during local QR-code pairing.

The macOS companion app sends an anonymous hourly usage heartbeat
(random install ID, peering state, app version, OS version) to help
measure active usage. No clipboard contents, Apple device identifiers,
or personal information are included. The Android app does not send
any telemetry.

Privacy policy: https://cliprelay.org/privacy.html
