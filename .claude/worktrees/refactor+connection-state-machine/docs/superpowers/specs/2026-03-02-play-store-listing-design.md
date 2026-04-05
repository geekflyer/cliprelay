# Play Store Production Listing

## Goal

Build out a production-quality Play Store listing for ClipRelay with all required assets, metadata, and documentation. The app is already published on internal testing — this work upgrades the listing to be production-ready.

## Store Listing Assets

### App Icon (512x512 PNG)
Render from existing `design/logo-android-foreground.svg`. Aqua background (#00FFD5) with the ClipRelay logo mark.

### Feature Graphic (1024x500 PNG)
Branded banner with app name and tagline. Dark background consistent with website theme, aqua accent.

### Screenshots (4 phone screenshots)
Captured from connected Android device:
1. Home screen — unpaired state
2. QR scanner — pairing flow
3. Connected state — clipboard syncing
4. Settings screen

## Store Listing Metadata

- **Title**: ClipRelay
- **Short description** (80 chars max): One-liner, e.g. "Sync your clipboard between Android and Mac over Bluetooth"
- **Full description**: Feature overview, how it works, privacy pitch (up to 4000 chars)
- **Category**: Tools
- **Contact email**: Required by Play Store

## Directory Structure

Place everything in `googleplay/` for Gradle Play Publisher:

```
play/
├── listings/
│   └── en-US/
│       ├── title.txt
│       ├── short-description.txt
│       ├── full-description.txt
│       └── graphics/
│           ├── icon/
│           │   └── icon.png           # 512x512
│           ├── featureGraphic/
│           │   └── feature.png        # 1024x500
│           └── phoneScreenshots/
│               ├── 1.png
│               ├── 2.png
│               ├── 3.png
│               └── 4.png
└── contact-email.txt
```

## Data Safety Questionnaire

Document answers for manual entry in Play Console:
- No data collected (no analytics, no crash reporting, no accounts)
- No data shared with third parties
- Encryption in transit (AES-256-GCM over BLE)
- No server-side storage, no data deletion mechanism needed

## Out of Scope

- Automated publishing pipeline changes (already working)
- Play Console account setup (already done)
- Closed/production track release (start with internal testing validation)
