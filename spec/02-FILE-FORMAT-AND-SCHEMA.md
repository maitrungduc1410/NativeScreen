# NativeScreen — File Format & Cross-Platform Data Schema (`.nativescreen`)

## 1. Package Structure (`.nativescreen`)

A NativeScreen project is a self-contained directory bundle with the `.nativescreen` extension.
- **On macOS:** Registered in `Info.plist` via `UTExportedTypeDeclarations` (`com.nativescreen.project`, `LSTypeIsPackage = true`). macOS Finder displays `MyDemo.nativescreen` as a single double-clickable file icon.
- **On Windows:** Opened directly as a `.nativescreen` folder or exported/shared as a single `.nativescreen` uncompressed ZIP archive with identical internal paths.

```text
MyDemo.nativescreen/
├── project.json                  # Main NLE state, styling, zooms, multi-track masks, slices
├── assets/                       # Self-contained assets copied into the project for portability
│   ├── background.jpg            # Copy of the chosen wallpaper/custom image (if image/wallpaper mode)
│   └── custom-audio.mp3          # Copy of custom background music (if imported)
└── recording/                    # Immutable raw capture outputs
    ├── metadata.json             # Capture hardware info, dimensions, scale, track file names
    ├── display.mp4               # Screen video, H.264, fragmented MP4 (2 s fragments, crash safe).
    │                             #   System audio (AAC 48 kHz stereo) is muxed into this file when recorded.
    ├── webcam.mp4                # Optional webcam video, H.264, fragmented MP4
    ├── microphone.m4a            # Optional microphone audio, AAC 48 kHz mono
    └── telemetry/                # Append-only JSON Lines (.jsonl) recorded during capture
        ├── cursor.jsonl          # 60Hz–120Hz mouse positions & cursor shape IDs
        ├── clicks.jsonl          # Mouse button down/up & scroll wheel events
        ├── keys.jsonl            # Keyboard shortcut & typing timestamps
        └── window.jsonl          # Target window resize/move bounds changes during capture
```

**Projects created from an existing video** (`File > Create project from video…`) use the same layout: the movie is copied
unchanged to `recording/display.<original extension>` (`tracks.displayVideo`, also `tracks.systemAudio` when the movie has
audio), `captureTarget.mode` is `display` with the movie's pixel size and `scaleFactor: 1`, `tracks.windowTelemetry` is
`null`, and `cursor.jsonl` / `clicks.jsonl` / `keys.jsonl` are empty files. Readers must treat an empty `cursor.jsonl` as
"no cursor recorded": zooms are `manual` (`manualCenter01`) and the cursor layer is not drawn.

> **Track names come from `metadata.json`.** Readers must open the files named in `tracks` (`displayVideo`, `webcamVideo`,
> `microphoneAudio`, `systemAudio`) instead of assuming the names above. `systemAudio` usually points at the display video
> file because the system audio track is muxed into it. Imported projects may use `.mov` or other container extensions.

---

## 2. Coordinate System Convention (Cross-Platform Rule)

To guarantee that a `.nativescreen` project created on a Retina macOS display (e.g. `2880×1800` @ 2x scale) opens with **pixel-perfect alignment** on a Windows 11 machine (`1920×1080` @ 1.25x scale):

1. **Normalized Coordinates (`0.0` to `1.0`):**
   - All spatial coordinates in `project.json` and `telemetry/*.jsonl` (cursor positions, click positions, zoom target points, crop rectangles, mask rectangles, webcam overlay positions, caption positions) **MUST be stored in normalized `[0.0, 1.0]` coordinates** relative to the recorded source bounds (`width`, `height`), with origin `(0, 0)` at the **top-left corner** (`x` increases rightwards, `y` increases downwards).
2. **Time Units (`Double` milliseconds):**
   - All timestamps and durations across `project.json`, `metadata.json`, and `*.jsonl` use **`Double` milliseconds (`Ms`)** relative to recording start (`0.0`).

---

## 3. Telemetry `.jsonl` Schemas (MVP)

Using **JSON Lines (`.jsonl`)** in the MVP ensures:
- **Crash safety during recording:** Each event is appended as a single line (`\n`). If power is lost mid-recording, all prior lines remain valid JSON.
- **Human & AI debuggability:** Easy to inspect and manipulate with standard tools.

### 3.1. `recording/telemetry/cursor.jsonl`
Sampled at display refresh rate / mouse polling rate (60–120 Hz):
```jsonl
{"t":0.0,"x":0.4125,"y":0.5210,"c":"arrow"}
{"t":8.33,"x":0.4150,"y":0.5195,"c":"arrow"}
{"t":16.67,"x":0.4210,"y":0.5120,"c":"pointingHand"}
```
- `t` (`Double`): Timestamp in ms from start of recording.
- `x`, `y` (`Double`): Normalized coordinates `[0.0, 1.0]` relative to recorded area/window. (Can be `< 0` or `> 1` if cursor moves outside a recorded window/area).
- `c` (`String`): Cursor identifier (`"arrow"`, `"pointingHand"`, `"iBeam"`, `"crosshair"`, `"resizeLeftRight"`, `"resizeUpDown"`, `"openHand"`, `"closedHand"`).

### 3.2. `recording/telemetry/clicks.jsonl`
Recorded on mouse down, mouse up, and scroll wheel:
```jsonl
{"t":1240.5,"type":"down","button":"left","x":0.624,"y":0.310,"count":1}
{"t":1315.2,"type":"up","button":"left","x":0.624,"y":0.310,"count":1}
{"t":2100.0,"type":"scroll","dx":0.0,"dy":-12.5,"x":0.500,"y":0.500}
```
- `type`: `"down"` | `"up"` | `"scroll"`
- `button`: `"left"` | `"right"` | `"other"`
- `count`: Click count (`1` = single click, `2` = double click).

### 3.3. `recording/telemetry/keys.jsonl`
Recorded on key press (for typing-aware auto-zoom hold and shortcut HUD display):
```jsonl
{"t":3400.1,"kind":"typing"}
{"t":5120.8,"kind":"shortcut","modifiers":["cmd","shift"],"key":"P","label":"⌘⇧P"}
```
- Note: For privacy and Mac App Store compliance, normal alphanumeric typing only needs `"kind": "typing"` (timestamp only, or optional key identity if user enables full keystroke display). Modifier combinations record the human-readable shortcut label.

### 3.4. `recording/telemetry/window.jsonl`
Recorded if the user moves or resizes the target window while recording in Window mode:
```jsonl
{"t":0.0,"x":120,"y":80,"w":1280,"h":800}
```

---

## 4. `recording/metadata.json` Schema

```json
{
  "formatVersion": "1.0.0",
  "appVersion": "0.1.0",
  "platform": "macos",
  "createdAt": "2026-10-24T21:15:00.000Z",
  "durationMs": 64754.38,
  "captureTarget": {
    "mode": "window",
    "displayId": 2077748985,
    "windowId": 412,
    "appBundleId": "com.google.Chrome",
    "appName": "Google Chrome",
    "windowTitle": "NativeScreen Spec",
    "logicalBounds": { "x": 0, "y": 0, "width": 705, "height": 1120 },
    "pixelSize": { "width": 1410, "height": 2240 },
    "scaleFactor": 2.0,
    "refreshRate": 60.0,
    "windowBorderRadius": 16.0
  },
  "tracks": {
    "displayVideo": "display.mp4",
    "webcamVideo": null,
    "microphoneAudio": "microphone.m4a",
    "systemAudio": "display.mp4",
    "cursorTelemetry": "telemetry/cursor.jsonl",
    "clicksTelemetry": "telemetry/clicks.jsonl",
    "keysTelemetry": "telemetry/keys.jsonl",
    "windowTelemetry": "telemetry/window.jsonl"
  }
}
```

---

## 5. `project.json` Schema (Complete NLE & Visual State)

Below is the canonical structure of `project.json` at the root of `MyDemo.nativescreen/project.json`:

```json
{
  "schemaVersion": "1.0.0",
  "id": "b7f9d2a1-4c8e-4f1a-9b2d-8e1a3c5f7d90",
  "name": "Product Demo",
  "createdAt": "2026-10-24T21:15:00.000Z",
  "updatedAt": "2026-10-24T21:20:00.000Z",
  "canvas": {
    "aspectRatioMode": "preset",
    "aspectRatioPreset": "16:9",
    "customAspectRatio": { "width": 16, "height": 9 },
    "paddingRatio": 0.10,
    "cropRect01": { "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0 }
  },
  "background": {
    "type": "wallpaper",
    "solidColor": "#1E1E2E",
    "gradient": {
      "type": "linear",
      "start01": { "x": 0.0, "y": 0.0 },
      "end01": { "x": 1.0, "y": 1.0 },
      "stops": [
        { "color": "#4776E6", "location": 0.0 },
        { "color": "#8E54E9", "location": 1.0 }
      ]
    },
    "meshPresetId": "spring-aurora",
    "wallpaperRelativePath": "assets/background.jpg",
    "systemWallpaperName": "tahoe-dark",
    "blurRadius": 0.0,
    "noiseIntensity": 0.02
  },
  "frameStyle": {
    "borderRadius": 16.0,
    "inset": {
      "enabled": false,
      "size": 2.0,
      "color": "#000000",
      "opacity": 0.5
    },
    "shadow": {
      "enabled": true,
      "intensity": 0.35,
      "blur": 30.0,
      "distance": 24.0,
      "angleDegrees": 90.0
    },
    "deviceMockup": {
      "enabled": false,
      "deviceId": null
    }
  },
  "cursor": {
    "hidden": false,
    "scale": 1.6,
    "themeId": "classic-dark",
    "variantId": null,
    "alwaysUsePointer": false,
    "smoothMovementEnabled": true,
    "spring": {
      "stiffness": 470.0,
      "damping": 70.0,
      "mass": 3.0
    },
    "baseRotationDegrees": 0.0,
    "rotationMode": "velocity",
    "velocityRotationEnabled": true,
    "velocityRotationIntensity": 0.5,
    "hideWhenIdleAfterMs": null,
    "loopBackToStartMs": null,
    "stopMovementInLastPartMs": 0.0,
    "removeShakeThresholdPx": 4.0,
    "optimizeCursorChanges": true,
    "keepInSyncWithHovers": true,
    "clickEffect": {
      "visualStyle": "ripple",
      "color": "#FFFFFF",
      "soundSet": "soft",
      "soundVolume": 0.50
    }
  },
  "camera": {
    "enabled": false,
    "layoutMode": "overlay",
    "mirror": true,
    "position01": { "x": 0.92, "y": 0.88 },
    "sizeRatio": 0.22,
    "scaleWhenZoomed": 0.80,
    "shape": "squircle",
    "borderRadiusRatio": 0.20,
    "shadowIntensity": 0.3,
    "backgroundBlur": 0.0,
    "aiPersonCutout": false
  },
  "motion": {
    "cameraSpring": {
      "stiffness": 170.0,
      "damping": 50.0,
      "mass": 3.0
    },
    "motionBlurIntensity": 1.0,
    "avoidEmptyBoundsWhenZooming": true
  },
  "audio": {
    "masterVolume": 1.0,
    "microphoneVolume": 1.0,
    "muteMicrophone": false,
    "voiceEnhancement": true,
    "systemAudioVolume": 1.0,
    "muteSystemAudio": false,
    "backgroundMusic": {
      "relativePath": null,
      "volume": 0.08,
      "duckDuringSpeech": true
    }
  },
  "captions": {
    "enabled": false,
    "showKeystrokes": true,
    "shortcutsSizeRatio": 0.11,
    "showSingleKeyShortcuts": false,
    "hiddenShortcutStartMs": [],
    "deletedShortcutStartMs": [],
    "defaultShortcutStyle": {
      "dockPosition": "bottom",
      "offsetX": 0.0,
      "offsetY": 0.0,
      "colorMode": "default",
      "solidColorHex": "#4D2FF5",
      "gradientStartHex": "#4776E6",
      "gradientEndHex": "#8E54E9",
      "textColorHex": "#FFFFFF"
    },
    "shortcutTracks": [
      {
        "id": "default-shortcuts-track",
        "name": "Shortcuts",
        "isHidden": false,
        "style": {
          "dockPosition": "bottom",
          "offsetX": 0.0,
          "offsetY": 0.0,
          "colorMode": "default",
          "solidColorHex": "#4D2FF5",
          "gradientStartHex": "#4776E6",
          "gradientEndHex": "#8E54E9",
          "textColorHex": "#FFFFFF"
        }
      }
    ],
    "customShortcuts": [],
    "shortcutStyleOverrides": {},
    "shortcutTimingOverrides": {},
    "shortcutKeyOverrides": {},
    "keystrokesPosition01": { "x": 0.5, "y": 0.90 },
    "fontFamily": "SF Pro Rounded",
    "fontSizeRatio": 0.045,
    "textColor": "#FFFFFF",
    "backgroundColor": "#000000CC",
    "position01": { "x": 0.5, "y": 0.88 },
    "animationStyle": "word-by-word",
    "segments": [],
    "captionTracks": [
      {
        "id": "uuid",
        "name": "Captions",
        "isHidden": false,
        "style": {
          "fontStyle": "sans-serif",
          "fontSizeRatio": 0.045,
          "wordsReveal": "line-by-line",
          "lineGrowth": "left-anchored",
          "wordAnimation": "appear",
          "colorTheme": "dark",
          "position01": { "x": 0.5, "y": 1.0 }
        }
      }
    ],
    "captionBlocks": [
      {
        "id": "uuid",
        "trackId": "uuid",
        "sourceStartMs": 120.0,
        "sourceEndMs": 1440.0,
        "wordIds": ["uuid"],
        "customText": null,
        "styleOverride": null
      }
    ]
  },
  "timeline": {
    "slices": [
      {
        "id": "slice-1",
        "sourceStartMs": 0.0,
        "sourceEndMs": 64754.38,
        "speed": 1.0,
        "systemAudioVolume": 1.0,
        "microphoneVolume": 1.0,
        "muted": false,
        "hideCursor": false,
        "disableSmoothCursor": false
      }
    ],
    "zooms": [
      {
        "id": "zoom-1",
        "sourceStartMs": 3146.0,
        "sourceEndMs": 19416.0,
        "scale": 1.8,
        "mode": "follow-cursor",
        "presentation": "screen",
        "manualCenter01": { "x": 0.5, "y": 0.5 },
        "loupe": {
          "radius01": 0.35,
          "bevelRatio": 0.2,
          "chromaticAberration": 0.5
        },
        "instantAnimation": false,
        "disabled": false
      }
    ],
    "isZoomTrackHidden": false,
    "maskTracks": [
      {
        "id": "mask-track-1",
        "name": "Blur Track 1",
        "isHidden": false,
        "items": [
          {
            "id": "mask-1",
            "sourceStartMs": 5000.0,
            "sourceEndMs": 15000.0,
            "type": "blur",
            "style": "gaussian",
            "intensity": 36.0,
            "cornerRadius": 10.0,
            "keyframes": [
              {
                "sourceMs": 5000.0,
                "rect01": { "x": 0.10, "y": 0.20, "width": 0.30, "height": 0.08 }
              }
            ],
            "disabled": false
          }
        ]
      }
    ],
    "isShortcutsTrackHidden": false,
    "dismissedTypingSuggestionStarts": []
  }
}
```

### Key Architectural Advantages:
1. **`timeline.maskTracks` (Multi-Track Masks with Keyframes):** Instead of a flat single-track array where masks cannot overlap comfortably, `maskTracks` allows **unlimited parallel tracks of Blur / Pixelate / Spotlight regions**, and each mask item supports `keyframes` so a blur box can smoothly move when the user scrolls the page!
2. **Self-Contained `assets/` Directory:** Copying the active wallpaper (`assets/background.jpg`) into the `.nativescreen` bundle ensures 100% cross-platform visual parity when opening a Mac project on Windows.

### Caption tracks

`segments` holds transcript words at their spoken times, which `Edit by transcript` uses to cut. What appears on screen comes from `captionBlocks`: a block shows its `wordIds` (or `customText`) stretched to fit its own time span, so moving a caption never changes a cut. `styleOverride` replaces the track's `style` for one block. A project with `segments` but no `captionTracks` is migrated on load: the older top-level style fields become the first track's style, and words are grouped at sentence ends, pauses of 750 ms or more, and every 6 words. In `position01`, `(0, 0)` is the top-left of the canvas margins and `(1, 1)` the bottom-right.
