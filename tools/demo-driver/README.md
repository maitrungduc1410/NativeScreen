# DemoDriver

Records the website demos. It opens `tools/demo-page` in a plain window (no URL bar) and plays scripted takes with
real mouse, scroll and keyboard events, so Native Screen records a real cursor, clicks and keystrokes.

## Setup

```bash
tools/demo-driver/build.sh
```

Then allow `tools/demo-driver/build/DemoDriver.app` in System Settings > Privacy & Security > Accessibility (on some
macOS versions the pane is called "Device Control and Data Access"). An ad hoc signed rebuild counts as a new app, so
remove the old entry and add it again after each build.

In Native Screen, turn on Settings > AI Agents (the scripts drive it through MCP) and set the language you want in the
UI. Point `NATIVE_SCREEN_APP` at the app if it is not in `/Applications`.

## Recording

Start the driver and leave it running. Use `open`: started from a shell, macOS checks the shell's Accessibility permission instead.

```bash
mkdir -p tools/demo-driver/build/ctl
open -n tools/demo-driver/build/DemoDriver.app --args "$PWD/tools/demo-page/index.html" "$PWD/tools/demo-driver/build/ctl"
```

Record a take (it prints the new project, including its `id` and `path`):

```bash
tools/demo-driver/take.sh hero
```

`take.sh` runs `takes/<name>.pre.json` first (reload the page, bring the window front, park the cursor), starts a
window recording, plays `takes/<name>.json`, then stops. Edit and export the project in the app or with `mcp.py`.
Write `quit` to `build/ctl/cmd` to close the driver.

## Takes

A take is a JSON array of steps. Positions are an element (`sel`, with `fx`/`fy` as the point inside it, default the
center), a fraction of the window content (`x`, `y`), or global points (`gx`, `gy`).

| op | Fields | Does |
| :-- | :-- | :-- |
| `wait` | `ms` | Pauses |
| `move` | `sel` or `x`/`y`, `ms` | Glides the cursor on a curved, eased path (`ms` 0 picks a time from the distance) |
| `click` | position (optional), `count`, `settle`, `after` | Moves there, then clicks |
| `type` | `text`, `cps` | Types with a human rhythm |
| `key` | `key`, `mods` (`cmd`, `shift`, `alt`, `ctrl`), `after` | Presses a shortcut |
| `scroll` | `lines` (negative scrolls up) | Scrolls at the cursor |
| `reload` | `ms` | Reloads the page |
| `front` | | Brings the window to the front |
| `js` | `code` | Runs JavaScript in the page |
| `play` | `file` (relative to the take) | Plays an audio file from the driver, so a window recording with system audio captures it (audio from other apps is not captured) |
| `place` | `app`, `x`, `y`, `width`, `height`, `after` | Moves that app's focused window (global points). Activation can be refused, so bring the app forward with `osascript` first |
| `rects` | `sels`, `file` | Writes element rects (points, relative to the content) to `build/ctl/<file>`, for placing masks |

`takes/transcript.json` is the voice take for the transcript screenshot. Render the voice first with
`say -o tools/demo-driver/build/transcript.aiff -f tools/demo-driver/takes/transcript.txt`; the take plays it from the
driver. Record it with `systemAudio` on (`take.sh` records without audio, so start the recording through `mcp.py`).

`takes/idle.json` is not a website demo: a 24 s take with a few page changes and long waits. Use it to check that a
recording reaches the end of the take (`spec/06` ADR-54).

## Website exports

The site uses these export settings (why: `spec/06` ADR-53): MP4 H.264, 60 fps, Social Media compression, 2160p for
`hero.mp4` and 1080p for the rest. Files go in `site/public/assets/demos/`.

| File | Take | Notes |
| :-- | :-- | :-- |
| `hero.mp4`, `ratio-*.mp4` | `hero` | Ratios are the same project at 1:1, 9:16, 16:9 |
| `auto-zoom.mp4` | `typing` | |
| `shortcuts.mp4` | `shortcuts` | |
| `agent.mp4` | none | Agent in Terminal (448 pt, an opaque profile) next to the editor (1280 pt), area recording 1728 x 972 pt. Masks over the user name in the title and the path in the agent's last message |
| `blur.mp4` | `blur` | Blur on the email and phone fields, pixelate on the API key (rects from the `rects` step) |
| `cursor-before.mp4`, `cursor-after.mp4` | `cursor` | Before: smoothing, click effect and rotation off, scale 1 |
| `motion-blur-on.mp4`, `motion-blur-off.mp4` | `hero` | A 2.5 s cut at half speed |
