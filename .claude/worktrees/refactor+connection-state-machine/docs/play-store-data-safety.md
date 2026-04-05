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
Bluetooth Low Energy. No data is sent to any server, cloud service, or
third party. The app has no backend infrastructure. All communication is
end-to-end encrypted with AES-256-GCM using keys established during
local QR-code pairing. No analytics, crash reporting, or telemetry is
included.

Privacy policy: https://cliprelay.org/privacy.html
