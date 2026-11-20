# NativeScreen for Linux: Port Plan

Linux support targets Wayland compositors that expose the `org.freedesktop.portal.ScreenCast` portal with
cursor metadata. The reference setup is the **Umbriel** compositor (`xdg-desktop-portal-umbriel`) with the
**Noctalia** shell; any compositor whose portal offers `CursorMode::METADATA` works the same way.

The Linux build is written in Rust (`linux/nativescreen/`) and uses only native Linux media stacks: the
ScreenCast portal + **PipeWire** for capture, **GStreamer** with **VA-API** for hardware H.264 encode and AAC
audio, and **evdev** for click and keyboard telemetry. No FFmpeg (spec/01 §1, rule "Zero FFmpeg"):
`gst-libav` elements are never used.

Platform details live in [`platforms/linux-pipewire-vaapi.md`](./platforms/linux-pipewire-vaapi.md).

## 1. Phases

### L1. Recorder + shell integration (done)

A recording made on Linux is a normal `.nativescreen` package (spec/02) that the macOS and Windows editors open.

- `nativescreen record | stop | toggle | status` CLI; state in `$XDG_RUNTIME_DIR/nativescreen/status.json`.
- Capture: portal picker (monitor, optionally a window), remembered pick through the portal restore token.
- `display.mp4`: H.264 (VA-API, x264 fallback) + system audio AAC 48 kHz stereo, fragmented MP4 (2 s).
- `microphone.m4a` (optional): AAC 48 kHz mono, fragmented MP4.
- `cursor.jsonl` from PipeWire `SPA_META_Cursor`; the cursor is **not** in the video (same as macOS
  `showsCursor = false`), so the editor draws its spring cursor.
- `clicks.jsonl` / `keys.jsonl` from evdev when `/dev/input/event*` is readable (`input` group); touchpad taps
  are recognized because libinput resolves them in user space.
- `metadata.json` (`"platform": "linux"`) and `project.json` (default look, one slice, auto-zooms from clicks
  using the shared `AutoZoomClusterGenerator`, scale 1.8 like the Windows recorder).
- Noctalia plugin `nativescreen/recorder` (`linux/noctalia-plugin/recorder/`): headless service, bar widget
  (timer, start/stop, picker, open folder), control-center tile, IPC.

Acceptance:
- `cargo test` passes, including `autozoom::matches_conformance_fixtures` over every `conformance/cases/*`.
- A recording on Umbriel opens in the macOS and Windows editors with the cursor aligned to the video.
- Idle CPU of the Noctalia service: one 500 ms file poll, no process spawned while idle.

### L2. Editor and export

Port the editor following spec/08's approach (conformance fixtures, parity with spec/07):

- UI: GTK 4 + libadwaita ("80% OS native"), custom timeline and preview canvas ("20% custom pro").
- Compositor: Vulkan (`wgpu` or `ash`), each pass of spec/07 with the same constants; preview paused when
  playback is paused (0.0% idle CPU, render on demand).
- Decode/encode: GStreamer + VA-API (`vah264dec`, `vah264enc`/`vah265enc`), zero-copy DMA-BUF between decode,
  compositor and encode.
- Engines to port first, each checked against `conformance/`: spring solver, NLE time mapper, auto-zoom
  (done in L1), camera/cursor motion, captions/shortcuts layout.

### L3. Packaging (started)

- Done: `linux/packaging/arch/PKGBUILD` (binary, `.desktop` entry, plugin installed as a Noctalia `path` source in
  `/usr/share/nativescreen/noctalia-plugins` with its `catalog.toml`). Builds and passes `check()` with `makepkg`.
- To do: publish to the AUR; a MIME type for `*.nativescreen` folders once the Linux editor exists to open them.

## 2. Known limits (L1)

- Cursor kinds come from matching the bitmap against the Xcursor theme (ADR-98). A custom picture an app sets
  itself (not from the theme) is written as `arrow`.
- `window.jsonl` is written empty: the portal gives no window geometry while recording.
- Frames are copied once from shared memory into GStreamer (no DMA-BUF import yet), about 1 GB/s at
  2880×1800 at 60 fps on damage-heavy content. DMA-BUF import is planned with L2.
- Without the `input` group no clicks or keys are recorded, so no auto-zooms are created.
