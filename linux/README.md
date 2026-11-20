# NativeScreen for Linux

Records the screen on Wayland into `.nativescreen` projects (the same packages the macOS and Windows editors open),
with cursor, click and keyboard telemetry for auto-zoom and the smooth cursor. Tested on Umbriel with Noctalia.

## Requirements (Arch / CachyOS)

```bash
sudo pacman -S --needed pipewire xdg-desktop-portal gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugin-va gst-plugin-pipewire
```

Your compositor's portal backend must provide ScreenCast (Umbriel: `xdg-desktop-portal-umbriel`).
For click and key telemetry (auto-zoom), your user needs read access to `/dev/input` (the `input` group).

## Build and install

```bash
cargo install --path linux/nativescreen --root ~/.local
```

Or as an Arch package (binary, launcher entry, and the Noctalia plugin as a plugin source):

```bash
cd linux/packaging/arch && makepkg -si
noctalia msg plugins source add nativescreen path /usr/share/nativescreen/noctalia-plugins
noctalia msg plugins enable nativescreen/recorder
```

See [Troubleshooting](#troubleshooting) for `NATIVESCREEN_DEBUG`.

## Use

```bash
nativescreen record            # pick a screen, record until Ctrl+C or `nativescreen stop`
nativescreen toggle            # bind this to a key in your compositor
nativescreen record --pick --window --mic
```

Projects go to `~/Videos/NativeScreen/Recording <date>.nativescreen`.

## Noctalia plugin

```bash
ln -sfn "$PWD/linux/noctalia-plugin/recorder" ~/.local/share/noctalia/plugins/recorder
noctalia msg plugins enable nativescreen/recorder
```

Then add the **NativeScreen** widget to a bar (Settings → Bar) or the tile to the control center. Left click
starts/stops, right click chooses another screen, middle click opens the projects folder. IPC:

```bash
noctalia msg plugin nativescreen/recorder:service all toggle
```

## Troubleshooting

| Symptom | Cause and fix |
| :-- | :-- |
| `missing GStreamer elements: ...` | Install the package named in the message (`mp4mux` is in `gst-plugins-good`). |
| `clicks.jsonl` / `keys.jsonl` empty, no auto-zoom | No read access to `/dev/input`: `sudo usermod -aG input $USER`, then log out and in. |
| A click gives no zoom | Clicks in the last second of a recording are ignored, as on macOS and Windows. |
| Slow start on a laptop with an NVIDIA GPU | The recorder pins `LIBVA_DRIVER_NAME` to the integrated GPU's driver so the discrete GPU is not woken up. Setting `LIBVA_DRIVER_NAME` yourself overrides that. |
| The picker opens every time | The portal did not return a restore token; `--pick` also forces the picker. |

`NATIVESCREEN_DEBUG=1 nativescreen record` prints each startup step with its time and every cursor bitmap with
the cursor kind it matched.
