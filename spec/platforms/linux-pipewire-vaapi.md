# Linux: ScreenCast Portal, PipeWire, GStreamer/VA-API, evdev

Implementation guide for `linux/nativescreen/` (spec/09). Read with spec/02 (package format) and spec/06 ADR-98.

## 1. Stack

| Concern | API | Crate / element |
| --- | --- | --- |
| Screen pick + permission | `org.freedesktop.portal.ScreenCast` (v4+) | `ashpd` 0.14 |
| Frames + cursor | PipeWire stream on the portal's remote fd | `pipewire` 0.10 (`find_meta::<MetaCursor>()`) |
| Video encode | GStreamer `vapostproc` → `vah264enc` (CQP) → `h264parse` → `mp4mux fragment-duration=2000` | `gstreamer` 0.25 |
| Fallback encode | `videoconvert` → `x264enc pass=quant` | |
| System audio | `pipewiresrc stream.capture.sink=true` (default sink monitor) → `fdkaacenc` | |
| Microphone | `pipewiresrc` (default source) → `fdkaacenc` → own `mp4mux` | |
| Clicks, keys | `/dev/input/event*` | `evdev` 0.13 |

Required packages (Arch/CachyOS): `pipewire`, `xdg-desktop-portal` + a backend with ScreenCast,
`gstreamer`, `gst-plugins-base`, `gst-plugins-good` (`mp4mux`), `gst-plugins-bad` (`h264parse`, `fdkaacenc`),
`gst-plugin-va`, `gst-plugin-pipewire`.

## 2. Capture

1. `SelectSources`: `cursor_mode = METADATA` when `AvailableCursorModes` has it (else `HIDDEN`),
   `types = MONITOR` (`| WINDOW` with `--window`), `persist_mode = 2` (until revoked). The restore token is
   stored in `$XDG_STATE_HOME/nativescreen/portal-restore-token`; a stale token falls back to the picker.
2. PipeWire `EnumFormat`: raw `BGRx | BGRA | RGBx | RGBA | xRGB | xBGR`, any size, 0–1000 fps. No modifiers
   are offered, so the producer sends shared-memory buffers.
3. On `Format`: `update_params` with `Buffers.dataType = MemFd | MemPtr`, `Meta Header`, and
   `Meta Cursor` sized for a bitmap up to 512×512 (range, default 64×64).
4. Each buffer: read `MetaCursor` (`id != 0` means valid) → position in stream pixels → normalized
   `cursor.jsonl` sample when it or the cursor kind changed. When the meta carries a bitmap, `cursor_kind.rs`
   names it from the Xcursor theme (`XCURSOR_THEME`, else `default`, with `Inherits=` and Adwaita as fallback);
   Umbriel sends it inside a 256×256 canvas, top-left aligned. `NATIVESCREEN_DEBUG=1` prints each bitmap and its match. Then, if the chunk has data and is not `CORRUPTED`, copy the frame
   (packing padded rows) and push it to `appsrc`. Buffers with an empty chunk are cursor-only updates.

## 3. Clocks (one zero for everything)

- `t0` = `Instant` at the first accepted frame (the encoder is created on that frame).
- Video PTS = `t0.elapsed()`; telemetry `t` = `t0.elapsed()` in ms. Events before `t0` are dropped.
- Audio sources run from pipeline start but sit behind `valve drop=true`. On the first frame the valves open
  and the `appsrc` src pad gets `offset = running_time(now)`, so video and audio share the same running time
  and `mp4mux` starts both tracks at that instant.
- `durationMs` = `t0.elapsed()` when stop is requested.

## 4. evdev telemetry

- Devices with `BTN_LEFT`/`BTN_TOUCH` (pointers) or `KEY_A`+`KEY_SPACE` (keyboards), one blocking thread each.
- Click position = latest cursor sample (evdev has no absolute screen position). `count` increments for the
  same button within 500 ms and 1% of the frame.
- Touchpad taps: `BTN_TOUCH` down→up within 200 ms, moving less than 45 units (~1.5 mm), 1 finger = left,
  2 fingers = right. Physical clicks arrive as `BTN_LEFT`/`BTN_RIGHT` and are not double counted (a physical
  click on a touchpad is not a quick touch without movement).
- Scroll: `REL_WHEEL`/`REL_HWHEEL`, 10 units per notch, positive = up/right.
- Keys follow the Windows/macOS vocabulary (`RecordingPackage.Stroke`): modifiers in order
  `CapsLock, Meta, Shift, Alt, Ctrl`; `kind = shortcut` with Meta/Alt/Ctrl or a special standalone key
  (arrows, Home/End, PageUp/Down, Delete, F1–F12). Plain typing stores only `{t, kind: "typing"}` unless
  `--typed-keys`. Labels use `Super` for Meta. Printable keys use the US layout of the physical key.
- No access (not in `input`): the recording continues, `clicks.jsonl`/`keys.jsonl` stay empty, the shell is told.

## 5. Status file protocol

`$XDG_RUNTIME_DIR/nativescreen/status.json`, replaced atomically:

```json
{"state":"recording","pid":4242,"package":"/home/u/Videos/NativeScreen/Recording 2026-11-19 10.02.11.nativescreen",
 "startedAtMs":1795579331000,"inputDevices":3,"encoder":"vah264enc"}
```

`state`: `picking` → `recording` → `finishing` → `idle`. `idle` carries no `pid` and, after a recording,
`package` + `frames`, or `message` on failure. Readers treat a `pid` whose `/proc/<pid>/comm` is not
`nativescreen` as `idle`. `nativescreen stop` sends SIGINT and waits until the file has no live pid.

## 6. Noctalia plugin

`linux/noctalia-plugin/recorder/` (id `nativescreen/recorder`, plugin API 24). Install for development:

```bash
ln -sfn "$PWD/linux/noctalia-plugin/recorder" ~/.local/share/noctalia/plugins/recorder
noctalia msg plugins enable nativescreen/recorder
```

The service polls the status file every 500 ms (no process spawned while idle) and launches the recorder
with `runAsync(argv)` (detached). IPC: `noctalia msg plugin nativescreen/recorder:service all toggle|start [pick]|stop`.
A compositor keybind can call the same command or `nativescreen toggle` directly.

## 7. Pitfalls

- `gst-plugins-good` is not pulled in by `gstreamer` on Arch; without it there is no `mp4mux`. The recorder
  checks for it before opening the portal session's stream and reports it.
- `vah264enc` on AMD supports `cqp`; VBR/CBR need a frame rate and the stream is variable frame rate
  (frames only on damage), so CQP is used.
- The portal `size` is logical (compositor) pixels; the negotiated format is buffer pixels. `scaleFactor` =
  buffer width / logical width.
- Do not request `SPA_DATA_DmaBuf` until DMA-BUF import into GStreamer is implemented: mapping a DMA-BUF
  with `MAP_BUFFERS` reads tiled memory.
- Build packages with `options=('!lto')` (ADR-98): makepkg's LTO breaks linking libspa's C shims.
- Umbriel's bar can be auto-hidden; `noctalia msg bar-show` shows it for a check.
- Keep the `appsrc` (`max-buffers`) and `queue` (`max-size-buffers`) depth at 2 frames: a 2880×1800 frame is ~20 MB,
  so depth 6 cost ~60 MB more resident memory (356 → 295 MB measured) with no dropped frames saved. Most of the
  remaining memory is mapped PipeWire buffers and the VA driver; DMA-BUF import (L2) removes the copies.
- Measured on Umbriel (Radeon 890M, 2880×1800 @ 120 Hz, desktop use): ~18% of one CPU core while recording.
