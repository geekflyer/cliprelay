# Play Store Production Listing — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create all assets, metadata, and documentation needed for a production-quality Play Store listing.

**Architecture:** Generate the 512x512 store icon from existing SVG sources using `rsvg-convert` + Python/Pillow. Capture phone screenshots from the connected Android device via `adb screencap`. Create the feature graphic with Python/Pillow. Place everything in a `googleplay/` directory at the project root.

**Tech Stack:** Python 3 + Pillow (image compositing), rsvg-convert (SVG rendering), adb (screenshots), Gradle Play Publisher (directory conventions)

---

### Task 1: Scaffold the googleplay/ directory structure

**Files:**
- Create: `googleplay/contact-email.txt`
- Create: `googleplay/listings/en-US/title.txt`
- Create: `googleplay/listings/en-US/short-description.txt`
- Create: `googleplay/listings/en-US/full-description.txt`
- Create directories for graphics (icon/, featureGraphic/, phoneScreenshots/)

**Step 1: Create the directory tree**

```bash
mkdir -p googleplay/listings/en-US/graphics/{icon,featureGraphic,phoneScreenshots}
```

**Step 2: Write contact-email.txt**

```
info@cliprelay.org
```

Save to `googleplay/contact-email.txt`.

**Step 3: Write title.txt**

```
ClipRelay
```

Save to `googleplay/listings/en-US/title.txt`.

**Step 4: Write short-description.txt**

Must be 80 chars or fewer. Write:

```
Sync your clipboard between Android and Mac over Bluetooth.
```

(60 chars — within limit.)

Save to `googleplay/listings/en-US/short-description.txt`.

**Step 5: Write full-description.txt**

```
ClipRelay syncs your clipboard between Android and Mac instantly over Bluetooth Low Energy. Copy on one device, paste on the other.

No cloud. No servers. No internet required. Your clipboard data never leaves your devices.

HOW IT WORKS
• Pair your Android phone with your Mac by scanning a QR code
• ClipRelay runs in the background on both devices
• Copy text on either device and it appears on the other within seconds

PRIVACY FIRST
• Direct Bluetooth connection — no data goes through any server
• End-to-end encrypted with AES-256-GCM
• No accounts, no sign-up, no tracking
• Open source

FEATURES
• Instant clipboard sync over Bluetooth Low Energy
• One-time QR code pairing — no manual setup
• Runs quietly in the background
• Works offline — no internet connection needed
• Share text to ClipRelay from any app via the share sheet
• Auto-start on boot to keep your devices connected
```

Save to `googleplay/listings/en-US/full-description.txt`.

**Step 6: Commit**

```bash
git add googleplay/
git commit -m "feat(android): scaffold Play Store listing metadata"
```

---

### Task 2: Generate the 512x512 store icon

**Files:**
- Read: `design/logo-android-foreground.svg` (the logo mark on transparent bg)
- Create: `googleplay/listings/en-US/graphics/icon/icon.png`

The Play Store icon should match what users see on their home screen: the logo mark on the aqua (#00FFD5) background.

**Step 1: Render the foreground SVG at 512px**

```bash
rsvg-convert -w 512 -h 512 design/logo-android-foreground.svg -o /tmp/cliprelay-fg-512.png
```

**Step 2: Composite onto aqua background with Python**

```python
from PIL import Image, ImageDraw

# Create aqua background (512x512)
bg = Image.new('RGBA', (512, 512), (0, 255, 213, 255))

# Load foreground
fg = Image.open('/tmp/cliprelay-fg-512.png').convert('RGBA')

# Composite foreground onto background
result = Image.alpha_composite(bg, fg)

# Convert to RGB (Play Store requires no alpha)
result = result.convert('RGB')
result.save('googleplay/listings/en-US/graphics/icon/icon.png')
```

**Step 3: Verify dimensions**

```bash
python3 -c "from PIL import Image; img = Image.open('googleplay/listings/en-US/graphics/icon/icon.png'); print(img.size)"
```

Expected: `(512, 512)`

**Step 4: Visually inspect the icon**

Read the generated PNG to verify it looks correct.

**Step 5: Commit**

```bash
git add googleplay/listings/en-US/graphics/icon/
git commit -m "feat(android): add 512x512 Play Store icon"
```

---

### Task 3: Capture phone screenshots

**Files:**
- Create: `googleplay/listings/en-US/graphics/phoneScreenshots/1.png` through `4.png`

**Prerequisites:** Android device connected (`adb get-state` returns "device"), ClipRelay debug APK installed.

**Step 1: Capture the home screen (unpaired state)**

If the app is paired, unpair first. Then capture:

```bash
adb shell am force-stop org.cliprelay
adb shell am start -n org.cliprelay/.ui.MainActivity
sleep 2
adb exec-out screencap -p > googleplay/listings/en-US/graphics/phoneScreenshots/1.png
```

Visually verify the screenshot shows the unpaired home screen.

**Step 2: Capture the QR scanner screen**

Navigate to the QR scanner (tap "Pair with Mac" or equivalent button):

```bash
adb exec-out screencap -p > googleplay/listings/en-US/graphics/phoneScreenshots/2.png
```

Visually verify it shows the QR scanner UI.

**Step 3: Capture the connected state**

Re-pair with the Mac if needed so the app shows the connected/syncing state:

```bash
adb exec-out screencap -p > googleplay/listings/en-US/graphics/phoneScreenshots/3.png
```

Visually verify it shows the connected state with clipboard sync.

**Step 4: Capture the settings / about screen**

Navigate to settings:

```bash
adb exec-out screencap -p > googleplay/listings/en-US/graphics/phoneScreenshots/4.png
```

Visually verify it shows the settings screen.

**Step 5: Commit**

```bash
git add googleplay/listings/en-US/graphics/phoneScreenshots/
git commit -m "feat(android): add Play Store phone screenshots"
```

---

### Task 4: Create the feature graphic (1024x500)

**Files:**
- Read: `design/BRAND.md` (brand colors and typography)
- Read: `design/logo-full-dark.svg` (dark theme logo)
- Create: `googleplay/listings/en-US/graphics/featureGraphic/feature.png`

The feature graphic is a 1024x500 branded banner. Dark background (#0A0A0F) with the logo mark centered-left and "ClipRelay" + tagline text to the right. Aqua accent color.

**Step 1: Render the dark logo at 300px for the banner**

```bash
rsvg-convert -w 300 -h 300 design/logo-full-dark.svg -o /tmp/cliprelay-logo-dark-300.png
```

**Step 2: Create feature graphic with Python/Pillow**

```python
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 1024, 500
BG_COLOR = (10, 10, 15)       # #0A0A0F
AQUA = (0, 255, 213)          # #00FFD5
TEXT_COLOR = (232, 232, 237)   # #E8E8ED
DIM_COLOR = (107, 107, 123)   # #6B6B7B

img = Image.new('RGB', (WIDTH, HEIGHT), BG_COLOR)
draw = ImageDraw.Draw(img)

# Load and place logo on the left
logo = Image.open('/tmp/cliprelay-logo-dark-300.png').convert('RGBA')
logo_x = 100
logo_y = (HEIGHT - 300) // 2
img.paste(logo, (logo_x, logo_y), logo)

# Draw app name "ClipRelay" — use a large system font
# Try to load a good font, fall back to default
try:
    title_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 64)
    tagline_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 28)
except:
    title_font = ImageFont.load_default()
    tagline_font = ImageFont.load_default()

text_x = 460
draw.text((text_x, 175), "ClipRelay", fill=AQUA, font=title_font)
draw.text((text_x, 260), "Clipboard sync over Bluetooth.", fill=TEXT_COLOR, font=tagline_font)
draw.text((text_x, 300), "No cloud. No servers. Just paste.", fill=DIM_COLOR, font=tagline_font)

img.save('googleplay/listings/en-US/graphics/featureGraphic/feature.png')
```

**Step 3: Verify dimensions**

```bash
python3 -c "from PIL import Image; img = Image.open('googleplay/listings/en-US/graphics/featureGraphic/feature.png'); print(img.size)"
```

Expected: `(1024, 500)`

**Step 4: Visually inspect the feature graphic**

Read the generated PNG. Iterate on font sizes, positioning, or copy if it doesn't look good.

**Step 5: Commit**

```bash
git add googleplay/listings/en-US/graphics/featureGraphic/
git commit -m "feat(android): add Play Store feature graphic"
```

---

### Task 5: Document Data Safety questionnaire answers

**Files:**
- Create: `docs/play-store-data-safety.md`

**Step 1: Write the Data Safety guide**

Document the exact answers for each section of the Play Console Data Safety form:

```markdown
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
```

**Step 2: Commit**

```bash
git add docs/play-store-data-safety.md
git commit -m "docs: add Play Store Data Safety questionnaire answers"
```

---

### Task 6: Final verification

**Step 1: Verify directory structure**

```bash
find googleplay -type f | sort
```

Expected output:
```
googleplay/contact-email.txt
googleplay/listings/en-US/full-description.txt
googleplay/listings/en-US/graphics/featureGraphic/feature.png
googleplay/listings/en-US/graphics/icon/icon.png
googleplay/listings/en-US/graphics/phoneScreenshots/1.png
googleplay/listings/en-US/graphics/phoneScreenshots/2.png
googleplay/listings/en-US/graphics/phoneScreenshots/3.png
googleplay/listings/en-US/graphics/phoneScreenshots/4.png
googleplay/listings/en-US/short-description.txt
googleplay/listings/en-US/title.txt
```

**Step 2: Verify all images meet Play Store requirements**

```python
from PIL import Image
checks = {
    "icon": ("googleplay/listings/en-US/graphics/icon/icon.png", (512, 512)),
    "feature": ("googleplay/listings/en-US/graphics/featureGraphic/feature.png", (1024, 500)),
}
for name, (path, expected) in checks.items():
    img = Image.open(path)
    actual = img.size
    status = "OK" if actual == expected else f"FAIL (got {actual})"
    print(f"{name}: {status}")

# Screenshots must be 320-3840px on each side, 16:9 or 9:16
import os
ss_dir = "googleplay/listings/en-US/graphics/phoneScreenshots"
for f in sorted(os.listdir(ss_dir)):
    img = Image.open(os.path.join(ss_dir, f))
    w, h = img.size
    ok = 320 <= w <= 3840 and 320 <= h <= 3840
    print(f"screenshot {f}: {w}x{h} {'OK' if ok else 'FAIL'}")
```

**Step 3: Verify text lengths**

```bash
echo "Short desc: $(wc -c < googleplay/listings/en-US/short-description.txt) chars (max 80)"
echo "Full desc: $(wc -c < googleplay/listings/en-US/full-description.txt) chars (max 4000)"
echo "Title: $(wc -c < googleplay/listings/en-US/title.txt) chars (max 30)"
```

All must be within limits.

**Step 4: Run build to make sure nothing is broken**

```bash
scripts/build-all.sh --android-only
```
