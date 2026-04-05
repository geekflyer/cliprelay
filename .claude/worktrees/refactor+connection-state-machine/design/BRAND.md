# ClipRelay Brand & Design Language

## Color Palette

### Brand Tokens (5 core colors)
| Token             | Hex       | Usage                                    |
|-------------------|-----------|------------------------------------------|
| `aqua`            | `#00FFD5` | Primary brand color, icon backgrounds    |
| `aqua-gradient`   | `#00DDC0` | Gradient endpoint, secondary accent      |
| `teal`            | `#00796B` | Primary accent, text, icons              |
| `board-dark`      | `#0A3A34` | Clipboard board fill (dark theme)        |
| `board-darker`    | `#082A26` | Clipboard body fill (dark theme)         |

### UI Theme (app-specific, not brand)
| Token               | Hex       | Usage                                  |
|---------------------|-----------|----------------------------------------|
| `bg-top-unpaired`   | `#E8F5F3` | Top section, unpaired state            |
| `bg-top-connected`  | `#D6F5EF` | Top section, connected state           |
| `bg-bottom-unpaired`| `#F0F0F0` | Bottom section, unpaired state         |
| `bg-bottom-connected`| `#F0F7F5`| Bottom section, connected state        |

### Dark UI Surfaces (used in logo-concepts pages)
| Token             | Hex       | Usage                                    |
|-------------------|-----------|------------------------------------------|
| `bg`              | `#0A0A0F` | Page background                          |
| `surface`         | `#13131A` | Card / panel surface                     |
| `border`          | `#1E1E2A` | Subtle borders                           |
| `text`            | `#E8E8ED` | Primary text                             |
| `text-dim`        | `#6B6B7B` | Secondary / dimmed text                  |

---

## Gradients

| Name              | Definition                                      | Usage                    |
|-------------------|-------------------------------------------------|--------------------------|
| Aqua Gradient     | `linear-gradient(135deg, #00FFD5, #00DDC0)`     | Icon backgrounds         |
| Board Gradient    | `linear-gradient(to bottom-right, #0A3A34, #082A26)` | Clipboard fill (dark) |
| Arc Gradient      | `linear-gradient(to bottom-right, #00FFD5, #00DDC0)` | Beam arc strokes     |
| Glow              | `feGaussianBlur stdDeviation="4"` + merge       | Beam arc glow effect     |
| Title Gradient    | `linear-gradient(135deg, #fff 30%, #00FFD5)`    | Display heading text     |

---

## Logo: "Beam Refined" Concept

The logo is a **clipboard board with clamp** (representing clipboard/paste) combined with **three concentric signal arcs** emanating to the right (representing wireless BLE data transfer) and **four text lines** on the board face (representing clipboard content).

### Anatomy
```
  ┌──────┐          Clamp (wide, centered on board)
  │╶────╴│          Rivet
┌─┴──────┴─┐
│ ════       │ )))  Board + 3 beam arcs
│ ═══        │ ))
│ ════       │ )
│ ══         │
└────────────┘
```

### Canonical Geometry (120x120 viewBox)
```
Board:       rect x="14" y="26" w="58" h="78" rx="12"
Clamp base:  rect x="24" y="18" w="38" h="14" rx="5"
Clamp top:   rect x="30" y="14" w="26" h="8"  rx="4"
Rivet:       rect x="39" y="22" w="8"  h="3"  rx="1.5"
Text lines:  y=42 w=38, y=51 w=27, y=60 w=33, y=69 w=20 (h=4.5 rx=2.25)
Arc 1 (inner): path d="M80 48 A 20 20 0 0 1 80 78"  (sw 4)
Arc 2 (mid):   path d="M90 39 A 32 32 0 0 1 90 87"  (sw 3.5)
Arc 3 (outer): path d="M100 30 A 44 44 0 0 1 100 96" (sw 3)
```

All variants share these exact coordinates. Only styling (fills, strokes, effects) differs.

### SVG Variants (in this directory)

| File                        | Size      | Description                                     |
|-----------------------------|-----------|--------------------------------------------------|
| `logo-full-dark.svg`        | 120x120   | Dark board + aqua gradient arcs + glow           |
| `logo-android-foreground.svg`| 108x108  | Adaptive icon foreground, mark on transparent     |
| `logo-appicon.svg`          | 1024x1024 | Solid dark bg, 3x stroke widths, glow            |
| `logo-menubar.svg`          | 120x120   | Black template strokes (macOS auto-tints)        |

### Design Rules
- **On dark backgrounds**: Use aqua-colored strokes/fills with glow filter
- **On light backgrounds**: Use aqua-filled board with teal arcs and drop shadow
- **On colored (aqua) backgrounds**: Use black arcs, dark semi-transparent fills
- **Menu bar / monochrome**: Stroke-only in black (macOS template mode auto-tints)
- Beam arcs always face **right** (signal radiating outward)
- Three arcs at radii 20, 32, and 44 (in the 120-unit viewBox)
- Arcs are semicircular (`A` commands spanning ~180 degrees)
- Stroke-linecap is always `round`
- Four text lines on the board give the clipboard content feel
- Menu bar variant uses 3 text lines + 2 arcs (tiny rendering)

---

## Animation

### Beam Pulse (CSS)
Three staggered keyframe animations give the arcs a pulsing "broadcasting" effect:

```css
@keyframes beamPulse1 {
  0%, 100% { opacity: 0.9; transform: translateX(0); }
  50%      { opacity: 1;   transform: translateX(2px); }
}
@keyframes beamPulse2 {
  0%, 100% { opacity: 0.55; transform: translateX(0); }
  50%      { opacity: 0.75; transform: translateX(3px); }
}
@keyframes beamPulse3 {
  0%, 100% { opacity: 0.3; transform: translateX(0); }
  50%      { opacity: 0.5; transform: translateX(4px); }
}

.beam-arc-1 { animation: beamPulse1 2s ease-in-out infinite; }
.beam-arc-2 { animation: beamPulse2 2s ease-in-out 0.25s infinite; }
.beam-arc-3 { animation: beamPulse3 2s ease-in-out 0.5s infinite; }
```

- Inner arc is most opaque/least movement; outer arc is most transparent/most movement
- Stagger delays: 0s, 0.25s, 0.5s
- Duration: 2s per cycle

### Text Shimmer (CSS)
```css
@keyframes beamTextShimmer {
  0%, 100% { opacity: 0.4; }
  40%      { opacity: 0.6; }
}
.beam-text-line { animation: beamTextShimmer 3s ease-in-out infinite; }
```
Lines stagger by 0.4s each.

### Android (Compose)
The Android app implements equivalent animations in Jetpack Compose using `rememberInfiniteTransition()` with `animateFloat` for 3 arc alpha values. See `ClipRelayScreen.kt:LogoIcon()`.

---

## Typography (Brand / Marketing)

| Role    | Family             | Weight | Notes                          |
|---------|--------------------|--------|--------------------------------|
| Display | Instrument Serif   | 400    | Headlines, logo lockup text    |
| Body    | DM Sans            | 300/500/700 | UI text, descriptions     |

Google Fonts import:
```
https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,300;0,9..40,500;0,9..40,700;1,9..40,300&family=Instrument+Serif:ital@0;1&display=swap
```

---

## Color Selection Rationale

**Why Neon Aqua over Neon Green or Ice Cyan?**

- **Neon Green (#39FF14)**: Maximum visibility but strong battery/power app association (AccuBattery, Greenify, etc.). At small icon sizes users pattern-match on color before reading the silhouette.
- **Neon Aqua (#00FFD5)**: Distinctive in Android share menus (dominated by blues and grays), no wrong-category associations, naturally conveys data transfer / connectivity.
- **Ice Cyan (#00E5FF)**: Clean and modern but too close to the blues that dominate Android share sheets (Messages, Drive, Chrome, Duo) -- would blend in rather than stand out.

---

## Legacy

### Beam Simplified (attempted, reverted)
An iteration that reduced to **two arcs** (radii 24, 36), removed text lines, narrowed/centered the clamp (`x=26 w=34` / `x=32 w=22`), used `rx=10` for the board, and aimed for a sparser mark. The result looked like a battery icon at small sizes and the mark was too sparse to be recognizable. Reverted in favor of the original Beam Refined geometry.

### Beam Refined (current)
Uses **three arcs** (radii 20, 32, 44), **four text lines**, wider clamp (`x=24 w=38` / `x=30 w=26`), and `rx=12` for the board. The extra arc and text lines give the icon density and recognizability at all sizes.

### Original (pre-Beam)
The original logo concept used **two overlapping clipboards** with sync arrows, representing Mac-to-Android relay. This was replaced by the single-clipboard + beam-arcs design which is simpler and reads better at small sizes. The old SVGs are preserved in git history.
