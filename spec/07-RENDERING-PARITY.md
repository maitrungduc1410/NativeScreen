# NativeScreen: Rendering Parity (CoreImage → Direct3D 11 / HLSL)

The macOS compositor is built from CoreImage filters and CoreGraphics drawing. Many of its behaviors are implicit in
those APIs (color space, blur radius conventions, anti-aliasing, text metrics). Windows has no CoreImage, so every pass
is rewritten in HLSL / Direct2D / DirectWrite. This document states those implicit behaviors explicitly so the Windows
compositor produces the same frames.

**Source of truth.** The Swift code is authoritative: `Engine/MetalFrameCompositor.swift` (`composeFrame` and its pass
helpers), `Engine/EffectKernels.swift`, `Engine/StageLayout.swift`, `Engine/CaptionLineLayout.swift`,
`Engine/LocalOnDeviceMediaIntelligence.swift` (camera looks, cutout). If this document and the Swift code disagree, follow
the code and fix this document. Conformance tests (`spec/08`) check the result.

---

## 1. Color Pipeline

| Topic | macOS behavior | Windows rule |
| :--- | :--- | :--- |
| Working space | `CIContext` with `workingColorSpace = sRGB`, `workingFormat = BGRA8` | Composite in **gamma-encoded sRGB, 8-bit, premultiplied alpha**. Do not linearize. |
| Render targets | `bgra8Unorm` | `DXGI_FORMAT_B8G8R8A8_UNORM`. Never the `_SRGB` variant for compositor targets or views (it would make the GPU linearize on read and blend in linear light). |
| Blending | `composited(over:)` = premultiplied source-over | `out = src + dst * (1 - src.a)` (`D3D11_BLEND_ONE`, `D3D11_BLEND_INV_SRC_ALPHA`). |
| Video input | `AVPlayerItemVideoOutput` / `AVAssetReader` deliver BGRA converted from BT.709 YCbCr | Convert NV12 → RGB with the **BT.709 matrix, limited range (16–235 / 16–240)**, no transfer-function change. Use `ID3D11VideoProcessor` or an HLSL pass; both must give the same result as §1.1. |
| Export output | VideoToolbox, BT.709 primaries / transfer / matrix tags | RGB → NV12 with the BT.709 limited-range matrix; tag `MF_MT_VIDEO_PRIMARIES`, `MF_MT_TRANSFER_FUNCTION`, `MF_MT_YUV_MATRIX` = BT.709, `MF_MT_VIDEO_NOMINAL_RANGE = 16_235`. |
| Hex colors | `CIColor(hexString:)`: `#RRGGBB` or `#RRGGBBAA`; anything else → `(0.28, 0.46, 0.90, 1)` | Same parser, same fallback. Values are sRGB-encoded. |

The only stage that works in linear light is the camera motion blur kernel, which decodes with gamma 2.2 internally and
re-encodes before writing (see §6).

### 1.1. BT.709 limited-range conversion
```
Y' = (Y - 16/255) * 255/219,  Cb' = (Cb - 128/255) * 255/224,  Cr' = (Cr - 128/255) * 255/224
R = Y' + 1.5748 Cr'
G = Y' - 0.1873 Cb' - 0.4681 Cr'
B = Y' + 1.8556 Cb'
```
Export uses the inverse. Clamp to `[0, 1]` after conversion.

---

## 2. Coordinates and Units

- CoreImage uses a **bottom-left** origin in pixels; Direct3D textures and Direct2D use **top-left**. For a rect in a
  canvas of height `H`: `yTopDown = H - yBottomUp - height`. Points: `yTopDown = H - yBottomUp`.
- Project and telemetry data are normalized `[0, 1]` with a **top-left** origin (`spec/02` §2). The Swift code converts
  with `1 - y` when going to CoreImage; on Windows the conversion is usually the identity.
- **Canvas scale.** Most sizes are authored for a 900 px tall canvas and scaled by `canvasScale = outputHeight / 900`
  (corner radii, shadow distance and blur, inset size, cursor size, click effects, device bezels).
- Pixel centers: sample at `(x + 0.5, y + 0.5)`. Affine transforms of images use **bilinear** sampling unless a pass
  says otherwise.

---

## 3. CoreImage Primitive Semantics

| CoreImage | Meaning | HLSL / Direct2D equivalent |
| :--- | :--- | :--- |
| `CIRoundedRectangleGenerator(extent, radius, color)` | Filled rounded rect, circular corners, ~1 px anti-aliased edge. Radius is clamped to `min(w, h) / 2`. | Signed distance `d` to the rounded rect; `coverage = saturate(0.5 - d)`; output `color * coverage` (premultiplied). |
| `CIRoundedRectangleStrokeGenerator(extent, radius, color, width)` | Stroke of `width` px along the rounded rect outline. | `coverage = saturate(0.5 - abs(d + width/2) + width/2)` with the band lying **inside** `extent`. Confirm against the webcam border fixture. |
| `applyingGaussianBlur(sigma: s)` and `CIGaussianBlur(inputRadius: r)` | Gaussian with standard deviation `s` (resp. `r`) pixels. | Separable two-pass Gaussian, `sigma` in px, taps to `ceil(3 * sigma)`. Edge handling: if the Swift code calls `.clampedToExtent()` first, clamp to edge; otherwise pixels outside the image are transparent black. For large sigmas, downsample by 2 per level first and keep the effective sigma the same. |
| `CILanczosScaleTransform(scale, aspectRatio: 1)` | High-quality downscale. Used for the screen only when the scale is uniform and `< 0.99`. | Separable Lanczos-3 (two passes). Otherwise bilinear. |
| `CIColorMatrix(R, G, B, A, Bias)` | Per-pixel `out.c = dot(vector_c, rgba) + bias_c` on **unpremultiplied** color, then re-premultiplied. | Same math in a pixel shader. A matrix that only scales alpha by `w` is equivalent to multiplying the premultiplied pixel by `w`. |
| `CIColorControls(saturation s, brightness b, contrast c)` | Saturation: mix toward Rec.709 luma `(0.2125, 0.7154, 0.0721)`; brightness: add `b`; contrast: `(x - 0.5) * c + 0.5`. | Implement in that order on unpremultiplied color, clamp to `[0, 1]`. Used directly for keycap highlight (`brightness 0.08`) and custom camera presets. |
| `CIVibrance`, `CITemperatureAndTint`, `CISharpenLuminance` | Undocumented internals. | Built-in camera looks use **LUTs exported from macOS** (§7), so no formula is needed. Custom presets use the approximations in §7.2. |
| `CIPixellate(scale, center)` | Square cells of `scale` px on a grid anchored at `center`; each cell takes the input color at the cell center. | `cell = floor((p - center) / scale)`, sample at `center + (cell + 0.5) * scale`. |
| `CIBlendWithMask(image, background, mask)` | `mix(background, image, mask)`. The masks used are white premultiplied by coverage, so mask value = coverage. | Multiply the image by coverage, composite over background. |
| `CIBlendWithAlphaMask` | Same, using mask alpha. | Same. |
| `CISourceOutCompositing(src, bg)` | `src * (1 - bg.a)`. | Same. |
| `CIMorphologyMinimum(radius)` | Erosion (min over a disc of `radius`). | Separable min over a square of `radius` is acceptable (mask edges only). |
| `cropped(to:)` | Clip, outside is transparent. | Scissor or clip in the shader. |

---

## 4. Frame Composition, Pass by Pass

All numbers below come from `composeFrame`. `S = canvasScale = outputHeight / 900`.

### Pass 1: Background (`renderBackgroundLayer`, `buildRawBackgroundImage`)
- **Solid:** fill with `solidColor`.
- **Gradient:** smooth linear gradient (CoreImage `CISmoothLinearGradient` uses a smoothstep ramp, not linear) between
  the first and last stop colors, from `start01` to `end01` (normalized, top-left origin). Use `t = smoothstep(0, 1, projection)`.
- **Mesh preset:** smooth linear gradient from `colors[0]` at the top-left corner to `colors[1]` at the bottom-right, then
  a radial gradient over it: center `(0.78 W, 0.28 H)` in top-down coordinates, color `colors[2]` with alpha 1 at radius
  `0.05 W` fading linearly to alpha 0 at `0.75 W`.
- **Wallpaper / image:** decode once, downsampled so the longest side is at most 2560 px; aspect-fill and center-crop to the canvas.
- **Blur:** if `blurRadius > 0.5`, Gaussian with `sigma = blurRadius * 0.4`, edges clamped.
- **Crossfade:** when the background identity changes, fade the new one over the old for **320 ms**, ease-out cubic
  `1 - (1 - t)^3`, blur applied to the blend. Preview only; exports render the settled background.
- Cache the result in a texture keyed by (background identity, canvas size, `round(blurRadius * 2)`).
- **Orientation:** every path keeps the background upright: the bake, the crossfade and export (`spec/06` ADR-32).

### Pass 2: Masks on the source screen (`applyMultiTrackMasks`)
Applied in source-video pixels, before scaling and zoom. For each active mask, rect = keyframe-interpolated `rect01`,
min 8 px, clipped to the frame. Corner radius `min(min(w, h) / 2, cornerRadius * sourceHeight / 900)`.
- **Blur:** `sigma = max(4, intensity * 0.92)`, computed at quarter resolution: crop the rect padded by `2.4 * sigma`,
  downscale 0.25, Gaussian `max(1.2, sigma * 0.25)`, upscale back, clip to the rounded rect.
- **Pixelate:** cell `max(8, intensity * 0.85)` centered on the rect center.
- **Solid:** `solidColor` when set, otherwise color `(0.08, 0.08, 0.11, 1)`.
- **Spotlight:** everything outside the rounded rect is multiplied by `1 - min(0.95, intensity / 100)` (RGB only).
Then apply `canvas.cropRect01` (min 16 px).

### Pass 3: Screen placement, corners, inset, shadow
- Screen rect comes from the stage layout (`StageLayout`, port `resolvedStageLayout`, `rawStageLayout`,
  `computeSplitScreenGeometry`, `calculateFittedScreenRect`, `cameraPlacement` exactly). Padding uses uniform margin
  `m = (s - s / (1 + 2r)) / 2` where `s` = shortest canvas side and `r = clamp(paddingRatio, 0, 0.45)`.
- Scale the masked screen into the rect (§3 Lanczos rule).
- **Corner radius:** `borderRadius * S`, or with a device mockup `34 * S` (iPhone) / `14 * S` (others).
- **Inset border** (no mockup, `inset.size > 0.1`): rounded rect of the screen rect grown by `inset.size * S`, radius
  `radius + insetPx`, color `inset.color` at `inset.opacity`, drawn under the screen.
- **Drop shadow:** rounded rect of the screen rect, radius as above, black at alpha `intensity`, offset
  `Directional: (cos a * dist * 0.55, sin a * dist * 0.55)` in top-down coordinates (angle `a` in degrees, `dist = distance * S`),
  `Classic: (0, +0.20 * dist)` downward; Gaussian `sigma = max(1, blur * S * 0.45)`. Bake into a texture (key: screen
  rect, canvas, radius, shadow config). Never blur at 4K per frame.
- **Device mockup:** port `renderDeviceMockupBezel` with Direct2D (same rects, radii, colors, gradients, even-odd fill).

### Pass 4: Click effect and cursor (`renderCursorAndRipple`)
Cursor position = screen rect + `position01` (top-left normalized).
- **Circle click effect** while `activeClickProgress = p` is set: filled white disc, radius `max(4, 46 * S * cursor.scale * p)`,
  alpha `(1 - p) * 0.72 * cursorOpacity * 0.65`.
- **Ripple click effect:** draws nothing on top. It bends the positioned screen, shadow included, before the cursor is drawn,
  over the whole canvas (`clickRipple` in `EffectKernels.swift`). Up to 3 waves at once, each from the cursor position when the
  button went down, for 900 ms. With `t` the age in seconds, `L` the longer side of the screen rect and `d` the distance to the
  click: front radius `L * (0.012 + 0.24 t)`, strength `exp(-3.4 t) * sin(8.8 t) * (1 - clamp((t / 0.9 - 0.7) / 0.3))`,
  `w = exp(-3.5 b^2) * smoothstep(0, 0.03 L, d)` where `b = (d - front) / (0.042 L)`, skipped when `|b| > 3`. Waves add up.
  Displacement is `radial * strength * w * 0.013 L`, sampled at `pixel - displacement`. Red and blue sample a further
  `radial * |strength| * w * (1 - w) * 4 * 0.0035 L` to either side of green.
- **Sprite:** rasterize the theme SVG once per (theme, variant, kind) at 256 px (Direct2D `ID2D1SvgDocument`). Height
  `32 * S * cursor.scale`, hotspot from the file name (percent of the 100×100 view box), rotation `rotationRadians`
  about the hotspot, alpha `opacity`. For a non-pointer kind, choose the sprite as in `spec/06` ADR-29.

### Camera zoom (classic)
Skipped while editing masks on the paused preview. With `Z = max(1, scale)` and focus `f` = screen rect + `center01`:
the zoom target moves from the screen center toward the canvas center by `k = clamp((Z - 1) / 0.5, 0, 1)`; the
transform is `translate(target) · scale(Z) · translate(-f)`. Crop to the canvas grown by 24 px.

### Pass 5: Motion blur and lens
Port the Metal kernels in `EffectKernels.swift` to HLSL compute shaders **line for line** (same math, same constants,
same sample counts: 8 in playback, 24 in export, `pixelsPerSample` 10 / 3). Conditions for running motion blur are in
`composeFrame` (instant-zoom window, paused last frame, loupe mode, `motionBlurIntensity > 0.02`). The lens runs over the
whole composite when `loupePresence01 > 0.005` and `loupeScale > 1.002`, radius `max(48, max(w, h) * radius01)` of the
screen rect.

### Pass 6: Overlays (camera, captions, keycaps)
Drawn in this order, in both preview and export (the preview draws everything in the compositor; there is no XAML overlay).

**Webcam** (`renderWebcamOverlay`, `prepareRecordedWebcamFrame`):
1. Crop by `camera.cropRect01` (min side 25%), mirror unless `mirror` is on (the raw frame is flipped by default).
2. Cutout mode: person mask (§7.3), applied before grading.
3. Grade and sharpen (§7).
4. Aspect-fill into the placement rect, extra zoom `1.16` when face tracking is on, clip to rounded rect.
5. Shadow: the clipped image's alpha, black at `shadowOpacity`, Gaussian `sigma = 0.011 * min(W, H)`, offset `0.008 * min(W, H)` downward.
6. Border: white at `borderOpacity`, width `max(1, 0.0014 * min(W, H))`, rect inset 0.5 px, radius `cornerRadius - 0.5`.
7. Multiply the whole layer by `opacity`.

**Captions** (`renderCaptionTracks`): each track not hidden draws the frame from `CaptionLineLayout.frames`. Font size is the canvas's shortest side times `fontSizeRatio`, shrunk if the line is wider than the margins. The line is fitted inside canvas margins of 6% of the shortest side, with `position01` as the fraction of free space (`(0.5, 1)` is bottom center). The box adds padding of 0.5 em and 0.25 em, radius 0.3 em, fill black at 0.82 or white at 0.92, and an outline of 0.025 em at 0.12 alpha in the opposite color. Words are drawn over it, clipped to the box in `Word by word`.

Animation: box x, y, width, height and opacity, and each word's x, y and opacity, follow a spring (stiffness 425, damping 12, mass 1.5) stepped at 240 Hz on an absolute time grid. A value stops at its target instead of overshooting. Each frame simulates the 500 ms before it, starting settled, so it does not depend on playback history. Targets: `Expanding` and `Centered` boxes hold the words spoken so far, `Full line` the whole line (always for `Fade in`). `Slide in` words start 0.75 em to the right at opacity 0. `Fade in` words wait at opacity 0.5. In `Word by word` the current word sits at x 0, later words wait one current-word width to the right and spoken words leave to the left. A box and its words are at opacity 0 outside their line, and the box stays on the line closest in time. Anything below opacity 0.99 is blurred with sigma `(1 - opacity) * 5 * (shortest side / 1080)`, except a `Fade in` word waiting at 0.5.

**Keycaps** (`renderShortcutKeycapsOverlay`, `rasterizeShortcutClusterCIImage`, `drawSingle3DKeycap`): port all sizes and
colors exactly. Key height `max(34, round(H * shortcutsSizeRatio))`, spacing `round(0.10 kh)`, edge margin
`max(16, round(0.05 H))`, sprite padding `max(18, ceil(0.35 kh))`. Envelope: fade-in 150 ms, fade-out 180 ms, smoothstep;
scale `0.95 + 0.05 s`, slide `0.10 kh * (1 - s)`. Keycap: outer radius `0.125 kh`, border `max(1.2, kh * 3/256)`,
shadow black 42% offset `0.10 kh` blur `0.22 kh`, bevel and body gradients as in the code. Highlighted (preview only):
scale 1.02 and brightness +0.08. Windows projects (`platform = "windows"`) draw Windows labels instead of macOS symbols, on
purpose (`spec/06` ADR-27).

---

## 5. Text Rendering (DirectWrite)

| macOS | Windows |
| :--- | :--- |
| `NSFont.systemFont` (SF Pro) | `Segoe UI Variable` (Display for sizes ≥ 20 px, Text otherwise); fall back to `Segoe UI`. |
| `.serif` design | `Georgia` |
| `.monospaced` design | `Cascadia Mono`, fallback `Consolas` |
| Weights regular / medium / semibold | `DWRITE_FONT_WEIGHT` 400 / 500 / 600 |
| `NSAttributedString.size()` | `IDWriteTextLayout` metrics: width = `widthIncludingTrailingWhitespace`, height = line height. |
| Modifier glyphs `⌘ ⌥ ⇧ ⌃` | `Segoe UI Symbol` via font fallback. Keys recorded on Windows use Windows labels (`Ctrl`, `Alt`, `Shift`, `Win`); keep the label table per recording platform (`metadata.platform`). |

Text will not match pixel for pixel across fonts. Layout must still follow the same formulas (sizes derived from the font
size, centered by measured size), and conformance checks text regions with a lower SSIM threshold (`spec/08` §3).
Render text with grayscale anti-aliasing (not ClearType) into premultiplied BGRA bitmaps.

---

## 6. Effect Kernels

`EffectKernels.swift` holds the Metal source as a string. Port each kernel to an HLSL compute shader with identical math:
- `magnifierLens`: magnification, rim refraction `1 + 0.55 e^2`, three-tap color fringe `±0.045 * fringe * e`, gloss,
  rim darkening, exponential rim highlight, Gaussian-falloff shadow. Light direction `normalize(-0.45, -0.9)` (top-down).
- `cameraMotionBlur`: per-pixel path `mapToNow(px, previous, now, t)`, jitter from interleaved gradient noise
  `fract(52.9829189 * fract(dot(px, (0.06711056, 0.00583715))))`, gamma 2.2 decode/encode around the average.
HLSL notes: `fract` → `frac`, `mix` → `lerp`, texture sampling with a linear clamp sampler, uniforms in a constant buffer
with 16-byte alignment (pad explicitly).

---

## 7. Camera Looks, Custom Presets and Cutout

### 7.1. Built-in looks → 3D LUTs
The 12 built-in looks (`applyBuiltInLook`) chain `CIColorMatrix`, `CIColorControls`, `CIVibrance` and
`CITemperatureAndTint`. To match them exactly, the macOS conformance generator (`spec/08` §2) renders an identity
lattice through each look and writes `conformance/looks/<preset>.cube` (33³, sRGB-encoded in and out). Windows applies the
LUT with a 3D texture and trilinear sampling, then blends with the original by `colorGradeIntensity`:
`out = lerp(original, graded, intensity)`.

### 7.2. Custom presets
`applyCustomColorPreset` uses continuous parameters, so no LUT. Port it with:
- Warmth: approximate `CITemperatureAndTint` as a white-balance gain in sRGB: for warmth `w`, multiply R by `1 + 0.10 w`,
  B by `1 - 0.12 w`, and G by `1 + 0.01 w` (fit against the fixture `custom-warmth-*` frames; adjust the coefficients if SSIM < 0.97).
- Contrast / saturation / brightness: `CIColorControls` formulas in §3 with the clamps from the code.
- Vibrance `v`: saturation boost weighted by low current saturation:
  `sat = max(r,g,b) - min(r,g,b); k = v * (1 - sat); out = lerp(luma, color, 1 + k)`.
- Sharpen: unsharp mask on luma, radius 1.6 px, amount `sharpen01 * 1.15`.

### 7.2b. Background, sticker and face tracking
After grading, when the layout is not cutout and `backgroundMode` is not `original`, the graded person (through the §7.3 mask) goes over the background. `image`: the picture scaled to cover. `blur`: Gaussian with sigma `height * 0.06 * backgroundBlur`, with the person removed first (mask dilated by `max(2, height * 0.008)` px) so no halo surrounds them; holes are filled with the plain blur.

The sticker is drawn last, in camera image space, so it is cropped and mirrored with the picture. Placement: see `CameraEffects.place`. `faceTrackingZoom` multiplies the aspect-fill scale and the picture is offset to center the framing point, clamped so it always covers the camera rect.

### 7.3. Person cutout
macOS uses Vision person segmentation (`.balanced` in the preview, `.accurate` in exports). Windows: ONNX Runtime (DirectML, CPU as a fallback) with MODNet,
downloaded on demand (`spec/04`, `spec/06` ADR-59), 320 px on the long side in the preview and 672 px in exports. Post-process exactly
like `applyPersonCutout`: stretch the mask to the frame, erode by `clamp(edgeInset * 10, 1, 12)` px when `edgeInset > 0.01`,
blur with `sigma = clamp(edgeSoftness * 10, 0.5, 14)` when `edgeSoftness > 0.01`, then use it as alpha. In the live preview,
segment asynchronously and use the newest mask (never block the render thread); exports segment every frame.
