# NativeScreen: File Format & Cross-Platform Data Schema (`.nativescreen`)

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

**Projects created from an existing video** (`File > Create project from video...`) use the same layout: the movie is copied
unchanged to `recording/display.<original extension>` (`tracks.displayVideo`, also `tracks.systemAudio` when the movie has
audio), `captureTarget.mode` is `display` with the movie's pixel size and `scaleFactor: 1`, `tracks.windowTelemetry` is
`null`, and `cursor.jsonl` / `clicks.jsonl` / `keys.jsonl` are empty files. Readers must treat an empty `cursor.jsonl` as
"no cursor recorded": zooms are `manual` (`manualCenter01`) and the cursor layer is not drawn.

`captureTarget.mode` is `display`, `window`, `area` or `camera`. Older files may say `device`, which readers treat as
`display` (that mode recorded the whole display).

**Camera-only recordings** (the `Camera` mode of the recording bar) capture no screen. `captureTarget.mode` is `camera`,
`displayId` is `0`, `pixelSize` and `logicalBounds` are the camera picture's size with `scaleFactor: 1`, and `refreshRate` is
the camera frame rate. `tracks.displayVideo` is `webcam.mp4` (the camera movie, the main picture), `tracks.webcamVideo`,
`tracks.systemAudio` and `tracks.windowTelemetry` are `null`, and the telemetry files are empty, as above. The camera
movie starts at the first usable camera frame and the microphone counts from it. Readers treat the main picture as a
camera: `camera` styling (mirror, background, color grade, sharpen, sticker) applies to it, and there is no camera layer.
The device frame (`frameStyle.deviceMockup`) is ignored for these recordings. `camera.cameraOnlyFraming` (`framed`
default, `full-frame`, `cutout`) sets how it sits on the canvas, and
`camera.enableFaceTracking` (on for new camera-only projects) keeps the face centered when the picture is cropped or zoomed,
using `assets/face-track.json` scanned from the main picture. `camera.faceTrackingZoom` enlarges the `full-frame` and
`cutout` picture around the face (new camera-only projects start at `1.0`). The same scan places `camera.stickerId`.

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

### 3.5. `recording/telemetry/drawings.jsonl`
What was drawn on the screen while recording (optional; screen recordings only). A `stroke` has a `tool` (`pen`,
`highlighter`, `arrow`, `rectangle`), a `color`, `points` as `[x, y, ms after t]` normalized like the cursor, and
`fadeAfterMs` (null: stays until cleared; one value for the whole recording, taken when it starts). `clear` ends every stroke still shown; `undo` ends the newest one. `t` is the
recording time the stroke started, pauses removed.
```jsonl
{"type":"stroke","t":1520.0,"tool":"pen","color":"#FF3B30","points":[[0.31,0.42,0],[0.33,0.41,16]],"fadeAfterMs":3000}
{"type":"clear","t":6100.0}
```
When the project is made (and when an interrupted recording is recovered) the strokes become annotations on `Live drawing`
tracks at the top:
- **Bursts.** Replaying the log in the order it was written (a stroke at `t` + its last point time), each stroke belongs to the
  clear epoch it was drawn in. In start order, a stroke starts a new burst when its epoch differs from the previous stroke's,
  or when it starts more than the previous stroke's `fadeAfterMs` after the latest finish in the burst. A burst ends
  `fadeAfterMs` after its latest finish (at the end of the recording when null), or at the `clear` that ends its epoch,
  whichever is first: strokes drawn without a long enough pause leave together, as on screen.
- **Items.** In a burst, the `pen` strokes of one tool and color are one `pen` item: the points of every stroke in order,
  `pointTimesMs` measured from the first stroke's `t` (never decreasing), and `strokeStarts` at the first point of each later
  stroke; bounding box as `position01`/`size01`, `highlighter` set for the highlighter, `enter: draw`, `exit: fade`, 300 ms.
  `arrow` is an arrow from the first to the last point with `bend: 0`, and `rectangle` a rectangle over them with
  `cornerRatio: 0.006` (`enter: draw`, `exit: fade`, the drawing time as `animationMs`, 120...600). A stroke that was undone
  is an item of its own that ends at the `undo`.
- **Constants.** `strokeRatio` is 0.005 for the pen, 0.022 for the highlighter and 0.006 for arrows and rectangles; the
  color is the stroke's; `anchor` is `screen`. An item starts at `max(0, min(t, duration - 220))` and lasts at least 220 ms.
- **Tracks.** Items are packed in start order onto the first track whose last item has ended (20 ms of overlap allowed), or a new one (`Live drawing`,
  `Live drawing 2`...), so there are as many tracks as things shown at once.

Items on one annotation track never overlap by more than 20 ms (the tolerance drags, layer moves and duplicates use). A
project opened with items overlapping more than that on a track has that track repacked the same way (the first keeps its
id and name).

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
    "customPointer": { "imagePath": "assets/cursors/arrow.png", "hotspot01": { "x": 0.0, "y": 0.0 } },
    "customHand": null,
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
    "aiPersonCutout": false,
    "backgroundMode": "original",
    "backgroundImagePath": "assets/camera-bg-1a2b3c4d.jpg",
    "stickerId": "crown",
    "enableFaceTracking": false,
    "faceTrackingZoom": 1.3,
    "cameraOnlyFraming": "framed",
    "backgroundRemoval": "ai",
    "chromaKeyColor": "#00B140",
    "chromaSimilarity": 0.4,
    "chromaSmoothness": 0.3,
    "chromaSpill": 0.5
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
2. **Face track:** `assets/face-track.json` holds where the largest face is in `webcam.mp4`, written once when a sticker or face tracking is first used and safe to delete (it is scanned again). `{"version": 1, "webcamDurationMs": n, "samples": [[timeMs, faceX, faceY, faceW, faceH, eyeAx, eyeAy, eyeBx, eyeBy, noseX, noseY, mouthX, mouthY], ...]}`, normalized to the raw webcam frame, top-left origin, every other frame; moments with no face have no sample.
2. **Self-Contained `assets/` Directory:** Copying the active wallpaper (`assets/background.jpg`) into the `.nativescreen` bundle ensures 100% cross-platform visual parity when opening a Mac project on Windows.

### Custom cursors

`cursor.customPointer` and `cursor.customHand` (both optional) replace the arrow and the pointing hand with a picture the user chose, copied into `assets/cursors/`. `hotspot01` is the tip, from the picture's top left. With `alwaysUsePointer`, `customPointer` is used for every shape. Other shapes (I-beam, crosshair, grab) keep the theme's sprite, and a missing file falls back to the theme.

### Annotation tracks

`timeline.annotationTracks` holds what is drawn over the video: text, arrows, shapes, steps, images and pen strokes. Like masks, items on one track never overlap, times are source times (`sourceStartMs`, `sourceEndMs`), and an empty track is removed. Every item keeps every field whatever its `kind`, so changing the kind or patching one field never loses the rest.

```json
"annotationTracks": [
  {
    "id": "annotation-track-1",
    "name": "Annotations",
    "isHidden": false,
    "items": [
      {
        "id": "annotation-1",
        "sourceStartMs": 1000.0,
        "sourceEndMs": 4000.0,
        "kind": "arrow",
        "anchor": "screen",
        "text": "",
        "position01": { "x": 0.5, "y": 0.5 },
        "fontSizeRatio": 0.042,
        "maxWidthRatio": 0.5,
        "bold": true,
        "textBackground": "solid",
        "backgroundColor": "#16161D",
        "from01": { "x": 0.30, "y": 0.80 },
        "to01": { "x": 0.42, "y": 0.65 },
        "bend": 0.18,
        "strokeRatio": 0.007,
        "size01": { "width": 0.22, "height": 0.12 },
        "rotationDegrees": 0.0,
        "fillOpacity": 0.0,
        "cornerRatio": 0.012,
        "imagePath": "",
        "keyframes": [],
        "points01": [],
        "pointTimesMs": [],
        "highlighter": false,
        "strokeStarts": [],
        "color": "#FF5A36",
        "enter": "fade",
        "exit": "fade",
        "animationMs": 250.0,
        "disabled": false
      }
    ]
  }
]
```

- `kind`: `text` (draws `text` in a box centered on `position01`), `arrow` (from `from01` to `to01`), `rectangle` or `ellipse` (sized by `size01` around `position01`, in the same units as the points, so a screen-pinned shape zooms with what it frames), `step` (a numbered badge at `position01`, `fontSizeRatio` setting its size), `image` (the file at `imagePath`, relative to the package and copied into `assets/annotations/`, `maxWidthRatio` of the frame wide at its own aspect, `cornerRatio` rounding its corners), or `pen` (a freehand stroke: `points01` inside its `size01` box around `position01`, 0...1 from the box's top left, `pointTimesMs` one per point in ms after the first, `strokeStarts` the indices where the pen went down again, `highlighter` for a wide see-through marker). Steps are numbered 1, 2, 3... by `sourceStartMs`, then by layer, skipping disabled items and hidden tracks.
- Layers: the first track draws on top. Moving an item up or down a layer moves it to the neighboring track when that track is free at its time, or to a new track inserted next to it.
- `rotationDegrees`: clockwise about the center, `-180...180`. Arrows ignore it.
- `keyframes`: optional `{ sourceMs, position01, from01, to01, size01, rotationDegrees }` sorted by time. With any, they replace the item's own geometry: it holds the first before it and the last after it, and eases between neighbors with smoothstep (rotation the shorter way round). Moving an item in time moves its keyframes; splitting gives each half a keyframe at the cut.
- `fillOpacity` (0...1) fills a rectangle or ellipse with `color`; `cornerRatio` is a rectangle's corner radius as a share of the frame's shorter side (0...0.1).
- `anchor`: `screen` points are in full-frame recording coordinates, the same as masks, so the item follows zoom, pan, crop and layout. `canvas` points are 0...1 of the output frame.
- Sizes are shares of the output frame, never of the zoomed recording: `fontSizeRatio` and `strokeRatio` of its shorter side, `maxWidthRatio` (where lines wrap) of its width. A zoom moves an item but does not enlarge it.
- `bend` moves the arrow's middle sideways by that share of its length, to the left of the direction of travel when positive (`-0.8...0.8`).
- `enter` and `exit`: `none`, `fade`, `pop` (from 60% scale, overshooting on the way in), `rise` (from below on the way in, upward on the way out), `slide` (from the left on the way in, to the right on the way out), `draw` (the line draws on and off; other kinds fade instead) or `typewriter` (text appears one character at a time and is erased on the way out; other kinds fade instead), each lasting `animationMs`, capped at half the item.
- Ranges on load: `fontSizeRatio` 0.015...0.2, `maxWidthRatio` 0.1...1, `strokeRatio` 0.002...0.03, `animationMs` 0...1500, each side of `size01` 0.01...1.5. Missing fields take the defaults above (text color `#FFFFFF`).

### Caption tracks

`segments` holds transcript words at their spoken times, which `Edit by transcript` uses to cut. What appears on screen comes from `captionBlocks`: a block shows its `wordIds` (or `customText`) stretched to fit its own time span, so moving a caption never changes a cut. `styleOverride` replaces the track's `style` for one block. A project with `segments` but no `captionTracks` is migrated on load: the older top-level style fields become the first track's style, and words are grouped at sentence ends, pauses of 750 ms or more, and every 6 words. In `position01`, `(0, 0)` is the top-left of the canvas margins and `(1, 1)` the bottom-right.
