# AGENTS.md: Linux (`linux/`)

Read the root [`AGENTS.md`](../AGENTS.md) first, then [`spec/09-LINUX-PORT-PLAN.md`](../spec/09-LINUX-PORT-PLAN.md) and
[`spec/platforms/linux-pipewire-vaapi.md`](../spec/platforms/linux-pipewire-vaapi.md).

- `nativescreen/`: Rust recorder (`cargo build`, `cargo test`). Modules: `capture` (portal + PipeWire),
  `encoder` (GStreamer), `input` (evdev), `cursor_kind` (Xcursor theme matching), `bundle` (package writer), `autozoom`,
  `telemetry`, `status`.
- `packaging/`: Arch `PKGBUILD` (`options=('!lto')`, see ADR-98) and the launcher `.desktop` entry.
- `noctalia-plugin/recorder/`: Noctalia plugin `nativescreen/recorder` (Luau). Lint with `noctalia plugins lint`.

Rules:
1. Packages written here must open unchanged in the macOS and Windows editors: same file names, normalized
   coordinates, `Double` milliseconds, and the key/click vocabulary of `windows/src/NativeScreen.Core/Recording/RecordingPackage.cs`.
2. Engines shared with the other platforms are ports, not rewrites: keep constants and order of operations, and test
   against `conformance/cases/*/expected/` (see `autozoom.rs`).
3. Zero FFmpeg: never use `gst-libav` (`av*`) elements.
4. The Noctalia service must stay cheap while idle: no process spawned per tick, only the status-file read.
5. Never commit `target/`, recordings, or machine-specific paths.
