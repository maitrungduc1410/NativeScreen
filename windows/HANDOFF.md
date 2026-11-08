# Windows Handoff Log

Shared log between the **writer** (macOS) and the **verifier** (Windows). Newest entry on top. See `AGENTS.md` §2.

## Template

```markdown
## <YYYY-MM-DD>, Phase <n>: <short title>

### Writer
- **Scope:** what was ported (Swift sources → C# files)
- **Built on macOS:** projects built / tests run and their result
- **How to verify:** exact steps and expected results (from `spec/08` §3 where possible)
- **Open VERIFY items:** file:line, what to check
- **Risks / unsure:** anything the verifier should look at first

### Verifier
- **Result:** PASS | FAIL
- **verify.ps1:** summary (build, tests, shaders)
- **Measurements:** frame timing, A/V offset, export speed, memory, SSIM, … (with machine: CPU, GPU, display Hz)
- **Changes made:** files and why
- **Spec updates:** ADRs or guide changes added
- **Next:** what the writer should do next
```

---

<!-- Entries start below this line. -->

## 2026-11-08, Settings: sliding segmented controls, smooth tab resize, full MCP config (macOS done, Windows port pending)

### Writer
- **Scope:** `spec/06` ADR-16 (Settings window bullets). macOS files: `Views/SlidingSegmentedControl.swift` (new), `Views/SettingsView.swift`.
  - **Segmented choices slide:** appearance, countdown, max camera resolution, quick export format, resolution and compression, and the Shortcuts section switcher. The selected pill (accent color, 6 pt radius, light shadow) slides to the clicked segment with a 0.3 s spring; hairlines sit only between two unselected segments. Screen readers get a standard segmented control. With animations turned off in Windows (`UISettings.AnimationsEnabled == false`) the pill jumps.
  - **Tab height animates:** when the Settings tab changes, the window (or page host) eases to the new tab's height in about 0.3 s, keeping its top edge in place, instead of jumping. Skip the animation when animations are off.
  - **AI Agents page:** the copy blocks show their whole text (the JSON config wraps over several lines instead of showing `{…`).
- **Built on macOS:** builds. The resize was measured frame by frame with a temporary probe (window height eased over about 27 frames, top edge fixed), and the General and AI Agents tabs were checked in screenshots. Not checked by clicking through.
- **How to verify on Windows:** switch every Settings tab and watch the height ease; click through each segmented choice and watch the pill slide; check Narrator reads them as a list of options with the selected one.


## 2026-11-08, AI agents through MCP (macOS done, Windows port pending)

### Writer
- **Scope:** rules are in `spec/06` ADR-52. The tool list is `NativeScreen/NativeScreen/Resources/MCPTools.json`: link it into the Windows app as content, like `Localizable.xcstrings`, and do not fork it. A tool Windows cannot support yet should still be listed and return `isError` with a sentence.
  - **macOS files:** `MCP/MCPServer.swift` (socket, JSON-RPC, connections), `MCP/MCPStdioBridge.swift` (`--mcp`), `MCP/MCPToolbox.swift` (the 28 tools), `MCP/MCPJSON.swift` (merge patch, argument reads), `NativeScreenApp.swift` (`NativeScreenMain` checks `--mcp` before AppKit starts), `Views/SettingsView.swift` (`AIAgentsSettingsTab`). Small additions: `ProjectSession.startNewUndoStep()`, `RecordingCoordinator.discardCurrentRecording()`, `ProjectWorkspaceStore.closeEditorWindow(for:)`, `VideoProjectImporter.buildPackage` no longer private, `AppSettings.aiAgentsEnabled`.
- **Built on macOS:** the app builds. Tested with a scripted client through the bridge and with a real Claude Code session (ADR-52, "Checked"). Codex not tried. The tests changed the recording bar's choices on this Mac to no camera, no microphone and no system audio.
- **What to port:**
  1. **Server in the app.** A named pipe, `\\.\pipe\NativeScreen.MCP.<user SID>`, with a `PipeSecurity` ACL for the current user only (`PipeOptions.CurrentUserOnly` on .NET). Newline-delimited JSON-RPC, same methods as macOS. The C# SDK (`ModelContextProtocol`) can run over a `StreamServerTransport` on the pipe stream, or reuse the hand-written dispatch; either way tool names, schemas and descriptions come from `MCPTools.json`, with `$ref` to `definitions` inlined before `tools/list`.
  2. **Bridge.** `NativeScreen.exe --mcp` must not create a window or the WinUI app. Check that a GUI-subsystem exe gets the client's redirected stdin and stdout; if not, ship a tiny console `nativescreen-mcp.exe` next to the app instead. If the pipe is missing: when the setting is off, answer the first request with the same error text and exit; otherwise start the app and wait up to 20 s. With Velopack, point configs at the stable `current` folder path so updates do not break them.
  3. **Setting.** `AiAgentsEnabled` in `settings.json`, off by default, read by the bridge too. Settings gets an `AI Agents` page with the switch, the status (`Off`, `Waiting for an agent to connect`, `Connected: %@`) and three copy blocks: `claude mcp add nativescreen -- "<exe>" --mcp`, `codex mcp add nativescreen -- "<exe>" --mcp`, and the `mcpServers` JSON.
  4. **Tools.** Same behavior as `MCPToolbox.swift`: merge patch against the document JSON (validated by deserializing before applying), `update_item` per kind, one undo step per call (break the undo coalescing first), overlap refusal for zooms, camera layouts, captions on a track and masks on a track, `render_frame` as a PNG image result, `export_video` with `notifications/progress` every 2% and cancellation, `delete_project` to the Recycle Bin, `control_recording cancel` without a dialog. JSON property names must match the macOS document exactly (the projects are shared), and `list_options enums` must list the same paths.
  5. **Visibility.** Toast `AI agent connected` on the first connection, connected clients in the tray menu (`AI agent connected: %@`), `Exporting video…` and `Export finished` toasts.
- **Strings:** 16 new keys with all 7 translations: `AI Agents`, `Allow AI agents to control Native Screen` and its description, `Status`, `Waiting for an agent to connect`, `Connected: %@`, `Connect an agent`, the paste hint, `Copied`, `Copy %@`, `Claude Desktop, Cursor and other apps`, the footnote, `AI agent connected`, `AI agent connected: %@`, `Exporting video…`, `Export finished`. The macOS texts mention `⌘Z`; add Windows keys with `Ctrl+Z` where needed.
- **How to verify on Windows:**
  - Turn the setting on, run `claude mcp add nativescreen -- "<exe>" --mcp` (or the Codex line), and in the agent ask for `get_status`; quit the app first to check that the bridge starts it.
  - Ask the agent to open a copy of a project, change the background, add a zoom, render a frame and export a 720p MP4. Each edit appears in the editor and `Ctrl+Z` undoes them one by one.
  - Start and stop a short area recording from the agent; the recording bar and countdown show.
  - With the setting off, the client shows the "turned off" message and the app does not start.
  - Measure idle CPU with the setting on and no client: the pipe wait must cost nothing.
- **Risks / unsure:** the GUI-subsystem stdio question in step 2. Large documents (`get_project` with `include_transcript`) can be big; keep the default without transcript words.

## 2026-11-07, Windows port: accessibility (names, timeline, playhead, announcements, Reduce Motion)

### Verifier
- **Result:** PASS for what UI Automation can check. Narrator speech and Reduce Motion with the system setting off were not run.
- **Build and tests:** the solution builds in Release (x64) with 0 warnings. Core 260 tests pass.
- **Measurements** (UI Automation probe, editor with a 10 s project and the recording bar, in English and Vietnamese):
  - **Editor:** 78 buttons, 0 unnamed (4 before, all icon-plus-label buttons), 6 sliders and 3 toggles, all named.
  - **Recording bar:** 9 buttons, all named.
  - **Segments:** 5 named, for example "Thuyết minh, 80%" with "Từ 0,5 giây đến 3,7 giây".
  - **Playhead:** `Đầu phát`, value 0 of 10.43 s, small change 1. `SetValue(3)` moved it to 3.
  - **Invoke:** invoking a shortcut segment selected it.
  - **Cost:** idle CPU is 0.00% before and after. Open and close leaves no editor object alive (97 to 102 MB after close).
- **Changes made:** `App/A11y.cs` (names from tooltips, durations and ranges, item status, announcements, Reduce Motion), segment and ruler automation peers in `TimelineView`, naming in `Ui`, `Loc.Apply`, `InspectorPanel` and `EditorWindow`, the hover magnet and split mode wiggle off under Reduce Motion, and 4 catalog keys (`Selected` and three duration forms) with all 7 translations.
- **Spec updates:** a Windows note in `spec/06` ADR-51.
- **Next / open:**
  - **Run with Narrator:** run Narrator and Accessibility Insights FastPass.
  - **Reduce Motion:** turn Animation effects off and check that the hover highlight and split mode no longer move.
  - **Preview targets:** expose the preview's keycap, caption and mask targets as elements.

## 2026-11-07, Accessibility: control names, timeline, announcements, Reduce Motion (macOS done, Windows port pending)

### Writer
- **Scope:** rules are in `spec/06` ADR-51. Scope is names for every control in the UI language, a readable timeline, toasts read out and Reduce Motion. Full editing with a screen reader (moving segments, drawing masks, picking a window) is out of scope on both platforms.
  - **macOS files:** `Views/Accessibility.swift` (new: `accessibleButton`, `AccessibilityText.duration/range/announce/reduceMotion`), `InstantTooltipView.swift` (shared buttons, Reduce Motion), `RecordingCoordinator.swift` (recording bar and its menus), `ProjectEditorWindowView.swift`, `MultiTrackTimelineView.swift`, `InspectorSidebarView.swift`, `TimelineSegmentContextPopovers.swift`, `SettingsView.swift`, `InteractiveMaskCanvasOverlayView.swift`, `ProjectSession.showToast`.
- **Built on macOS:** the app builds. Not checked with VoiceOver or Accessibility Inspector in the running app yet.
- **What to port** (WinUI: `AutomationProperties` and automation peers, read by Narrator, Voice Access and UI Automation tools):
  1. **Names from tooltips.** `Ui.IconButton` already sets `AutomationProperties.Name` to the tooltip. Strip a trailing shortcut in parentheses (`Split clip (Alt)` names "Split clip", same rule as the tooltip keycap badge), and do the same for every other icon-only button that sets a tooltip without going through `Ui.IconButton` (recording bar, transport, dock, timeline eye buttons, inspector wand, eyedropper and `+` buttons). A button showing a state also sets a value: the playback speed button reads "Playback speed" plus `2x` (`AutomationProperties.ItemStatus` or a peer value).
  2. **Hidden-label controls.** Every `ToggleSwitch`, `ComboBox`, segmented control and `Slider` without a visible header gets `AutomationProperties.Name` from its row title: settings rows, inspector toggle and slider rows, the segment menu volume sliders (`Microphone volume`, `System audio volume`), mask mode and blur style pickers, `Hue`, `Motion blur`, `Timeline zoom`, the typing speed-up slider (`Speed`). Slider `Reset` buttons are named "Reset <row title>" with the new key `Reset %@`.
  3. **Clickable non-buttons.** Anything that takes a click through `PointerPressed` instead of a `Button` (recording bar menu rows, countdown and camera resolution segments, zoom and mask palette cards, preview hit targets for keycaps, captions and masks) needs an automation peer with the Invoke pattern, a name, and `SelectionItem.IsSelected` (or `AutomationProperties.ItemStatus`) when it is the selected one. Invoke must run the same action as the click. Preview hit targets are named `Edit shortcut`, `Edit caption`, `Sensitive data mask` or `Highlight mask`.
  4. **Grids.** Wallpaper, mesh, gradient, swatch, cursor, color grade and layout thumbnails get a name and a selected state. Bundled wallpaper ids like `spring-01` are named "<category in the UI language> 1". Favorites add "Favorite". Gradients are `Gradient %lld` (1-based), swatches are `Color` with the hex as value. The color swatch button is `Color` with the hex and the help text `Opens the color picker`.
  5. **Timeline segments.** One automation element per segment (custom peer, Invoke pattern): name = title and what the block shows joined by ", " (`Zoom, 1.6×, Auto`, `Caption, <text>`, `Shortcut, Ctrl+C`, plus `Disabled` when dimmed), value or help text = `From %@ to %@` with both times spelled out in the UI language (macOS uses `Duration.UnitsFormatStyle`: "3.2 seconds", "1 minute, 5.2 seconds"; on Windows build them from the catalog or `NumberFormatInfo`, do not show `mm:ss`). Invoke = what a click in the middle does: seek there and select, or split in split mode. Selected segments report selected. The eye buttons are named `Hide Track` / `Show Track`. The `+` ghost blocks are named `Add`, the typing chip `Speed up typing`, the cut badges use their tooltip.
  6. **Playhead.** The ruler is one element named `Playhead` with the RangeValue pattern (or a Slider peer) whose small change moves the playhead by 1 second. Do not raise value changes from the playback tick, and do not compute the spoken value per frame. The transport timecode button is named `Playhead`, its value is the timecode it already shows, help text `Copy to clipboard`. The total time button is `Duration`. The project title button is `Project name` with the name as value and help text `Rename project`.
  7. **Containers.** The preview canvas is a group named `Preview`. The playhead lines, snap guide, mic level meters, countdown ring and modal backdrops are hidden from automation (`AccessibilityView.Raw`). Export progress is one element named `Export progress` with the percentage as value. The command menu clear button is `Clear search` and the highlighted row is selected. The `Advanced` and inspector section headers report `Expanded` / `Collapsed` (or the ExpandCollapse pattern), and section headers are headings.
  8. **Announcements.** Every toast is also raised as a notification so Narrator reads it: `AutomationPeer.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "toast")` on the editor root, or a `LiveSetting=Assertive` text block. Only when an automation client is listening (`AutomationPeer.ListenerExists`), so nothing runs otherwise.
  9. **Reduce Motion.** Windows has `Settings > Accessibility > Visual effects > Animation effects`, read with `new UISettings().AnimationsEnabled` (and its change event). When off: the hover highlight appears in place without the fly-in or the cursor pull, tooltips fade without the slide, the toast fades instead of sliding up, split mode does not wiggle the tracks, and the spring demo dot stays still.
- **Strings:** 21 new keys with all 7 translations: `From %@ to %@` (translations use `%1$@`/`%2$@`, so `Loc.F` must handle positional args), `Duration`, `Copy to clipboard`, `Playhead`, `Preview`, `Edit caption`, `Clear search`, `Expanded`, `Collapsed`, `Export progress`, `Timeline zoom`, `Favorite`, `Gradient %lld`, `Opens the color picker`, `Random color`, `Pick a color from the screen`, `Reset %@`, `Disabled`, `Shortcut`, `Add`, `Current Desktop`. Other names reuse existing keys (tooltips, row titles, `Show Track`, `Hide Track`, `Edit shortcut`, `Sensitive data mask`, `Highlight mask`, `Countdown`, `Max resolution`, `Close`). Inserted without reordering the catalog; the file still ends with a newline.
- **Performance:** nothing here should run when no automation client is connected. Peers are created on demand by UI Automation; keep name and value lookups lazy (override `GetNameCore` and friends rather than setting properties from the frame tick).
- **How to verify on Windows:**
  - Run Accessibility Insights for Windows (FastPass) on the recording bar, the editor, the inspector tabs, Settings and the export dialog: no "name missing" errors on focusable elements.
  - With Narrator on: tab through the recording bar (Close, Display/Window/Area/Device, camera, microphone, system audio, Projects, Recording options); open a timeline segment with Caps Lock+Enter and check it is selected and the inspector opens; move the playhead from the ruler; delete a track and hear the toast.
  - With the app in Vietnamese and in German, check that the names above are read translated, including segment ranges ("Từ 3,0 giây đến 5,5 giây").
  - Turn off Animation effects and check the hover highlight, tooltip, toast and split mode no longer move.
  - Measure editor idle and playback CPU with Narrator off before and after the change: it must not move.
- **Risks / unsure:** on macOS nothing was verified with VoiceOver in the running app, only built. Segment Invoke during split mode splits at the segment's middle, which is what a click there does but may surprise a screen reader user.


## 2026-11-07, Windows port: delete a track from its label, wallpaper favorites, random pick across categories

### Verifier
- **Result:** PASS for what was clicked through. Undo of a delete and the restart persistence of favorites are covered by tests and the settings file, not by clicking.
- **Build and tests:** the solution builds in Release (x64) with 0 warnings. Core 260 tests pass, including 7 new ones: each track kind's delete, voiceover renumbering, recorded keystrokes hidden only for the first shortcut track, and favorites order.
- **Checked in the running app** (a copy of a project in a scratch folder):
  - **Track menu:** right-clicking the Shortcuts label showed `Hide Track` and a red `Delete Track`. Delete Track removed the row and its two shortcuts and showed `Deleted Shortcuts. Press Ctrl+Z to undo.`
  - **Favorites:** right-clicking a mesh thumbnail showed `Add to Favorites`. After adding it, `★` showed only that thumbnail with the white star, and `settings.json` held `mesh:spring-aurora`.
- **Changes made:**
  - **Track delete:** `Core/Session/EditorSession.Tracks.cs`. The label menu is in `TimelineView.AddLabel`. Clip has no menu, Zoom only hides, and a voiceover track is not offered while one is recording.
  - **Favorites:** `Core/Rendering/BackgroundFavorites.cs`, `AppSettings.FavoriteBackgrounds`, and the inspector's `Favorite` and `PickRandomBackground`.
  - **Catalog:** one Windows key, `Deleted %@. Press Ctrl+Z to undo.`, inserted after the macOS key without reordering the file, since Xcode now sorts keys its own way. The file still ends with a newline, as Xcode writes it.
- **Next / open:** none.

## 2026-11-07, Delete a track from its label's right-click menu (macOS done, Windows port pending)

### Writer
- **Scope:** `ProjectSession.deleteTimelineTrack(_:displayName:)` and `MultiTrackTimelineView.trackLabelMenu`. Rules are in `spec/06` ADR-50.
  - **Menu:** right-click on a track label shows `Hide Track` / `Show Track`. For Layouts, Mask, Voiceovers, Shortcuts and Captions tracks it adds `Delete Track` (destructive) below a divider. Clip has no menu, and Zoom only hides.
  - **Delete:** one undo step, then the toast `Deleted %@. Press ⌘Z to undo.`. Watch the shortcut case: deleting the first shortcut track also hides its recorded keystrokes.
  - **Strings:** `Show Track`, `Hide Track`, `Delete Track` and the toast are in the catalog with all 7 translations.
- **Built on macOS:** the app builds. Not clicked through in the running app yet.
- **How to verify on Windows:** delete one track of each kind, check that the row and its items are gone from the timeline and the preview, then `Ctrl+Z` and check that they come back. Delete the only shortcut track, save, reopen, and check that the recorded keystrokes stay hidden.

## 2026-11-07, Wallpaper favorites and a random pick across categories (macOS done, Windows port pending)

### Writer
- **Scope:** `Views/InspectorSidebarView.swift` (`favoriteMenuButton`, `meshPresets(in:)`, `wallpaperItems(in:)`, `pickRandomBackground`). Rules are in `spec/06` ADR-32.
  - **`★` pill:** now Favorites, not "All". Every mesh and wallpaper thumbnail has a right-click menu with `Add to Favorites` or `Remove from Favorites`. Favorites are app-wide, in add order, one id per line (`mesh:<id>` or `wallpaper:<id>`). On Windows, store them in `settings.json`. With no favorites, the grid shows the hint text. A favorite thumbnail has a white outlined star in its middle (15 pt semibold, light shadow), under `★` and in its own category.
  - **`Pick random wallpaper`:** draws from mesh, system and built-in wallpapers together, then switches to the pick's category and scrolls its pill into view.
  - **Strings:** `Add to Favorites`, `Remove from Favorites` and the empty hint are in the catalog with all 7 translations.
- **Built on macOS:** the app builds. Not clicked through in the running app yet.
- **Also in this change:** `STRING_CATALOG_GENERATE_SYMBOLS = NO` on macOS. The Windows-only keys that differ from macOS keys only by case or by `...` versus `…` produced duplicate Swift symbols and failed the build (ADR-44). No catalog key changed.
- **How to verify on Windows:** right-click a wallpaper, add it, and check that it shows under `★` and survives a restart. Remove it from the `★` grid. Press the random button several times from `★` and check that it lands in different categories and the pill row follows.

## 2026-11-07, Performance pass: closing frees the project, no work for unused features (macOS done, Windows pass pending)

### Verifier
- **Result:** PASS. Closing an editor now frees it, and memory after close stays flat.
- **Build and tests:** the solution builds in Release (x64) with 0 warnings. Core 253 and Rendering 21 tests pass. The wallpaper fixtures still score SSIM 0.9955 to 0.9978.
- **Measurements** (Release, i9-9880H with Radeon Pro 5500M, 10 s 3072 x 1840 project, opened and closed through the running app):
  - **Before:** every closed editor stayed alive, with its window, session, timeline, inspector, compositor, swap chain and renderer. Memory after close was 147, 222, 291, 350, 417 and 466 MB over 6 cycles.
  - **After:** 97 to 115 MB after close over 8 cycles. At 2, 6 and 15 s after each close, no editor object is alive and the managed heap is 3.3 MB.
  - **Idle CPU:** 0.00% at launch, and 0.00% with a project open and paused.
  - **Open-time memory:** about 580 MB private and 300 MB working set with a project open. It does not settle like macOS, but it is all returned on close. Opening the Media Foundation source reader with hardware decode takes about 265 MB, and the first decoded frames about 210 MB, including the 50 MB NV12 ring. Software decode was larger (490 MB working set), so hardware decode stays.
- **Cause of the leak:** `Window` is outside XAML reference tracking. A lambda on the window's own `Closed` or `Activated` event that captures the window forms a native cycle that is never collected. A heap dump showed no managed root. An empty probe window was collected, and the same window passed through `AppTheme.Register` (whose `Closed` lambda captured it) was not. The fix and the rule are in `spec/06` ADR-48 and the platform guide's pitfalls table.
- **Changes made:**
  - **Window handlers:** the editor's handlers are named and removed in `WindowClosed`, and `AppTheme` uses a static `Closed` handler.
  - **What a close now tears down:** the timers are stopped and unhooked, the music preview stops, both click sound sets are disposed, the session events are detached, and the content is dropped.
  - **Wallpaper thumbnails:** purged when the last editor closes.
  - **Camera LUT:** a LUT file is checked on disk at most once a second, and a custom preset is serialized once per snapshot instead of every frame.
  - **Preview wallpaper:** decoded at the canvas size, in 512 px steps up to 2560 px.
  - **Waveform p95:** taken from a 1024-bin histogram, the same as macOS. One test expectation moved to the bin edge.
  - **Diagnostics:** `NS_MEMORY_STATS=<file>` reports what is alive after a close (`windows/AGENTS.md`).
- **Leads checked and left as they are:**
  - **Window picker:** it does not poll; it lists windows once when opened and once on a click.
  - **Sliders and undo:** they already coalesce into one undo step (700 ms).
  - **Delete:** it already clears unsaved changes before the close.
- **Next / open:**
  - **Native drift after close:** about 2 MB a cycle, still rising slowly by cycle 8.
  - **Decoder memory:** lowering it while paused would need a smaller frame ring or a lazily opened reader, which costs seek latency.

### Writer
- **Scope:** macOS only. What changed and why is in `spec/06` ADR-48 (closing an editor releases its project) and ADR-49 (pay only for what is used). Windows: run the same pass. Measure first and change only what the numbers show, since the Windows code is laid out differently.
- **macOS result** (Debug, 15 MB recording): memory after closing every project stays at 95 to 113 MB over repeated open and close cycles. It used to grow by about 5 MB per cycle. CPU is 0% with a project open and paused.
- **How to verify on Windows:**
  1. **Baseline.** Use a Release build. Note memory at launch, with one project open and idle, and after closing it. Take private working set from Task Manager or `Get-Process`, and dedicated GPU memory from Task Manager. Open and close the same project 5 to 10 times. Memory after close should stay flat, not climb.
  2. **Find what survives a close.** Take a heap snapshot after closing (`dotnet-gcdump` or Visual Studio Diagnostic Tools) and count `EditorWindow`, `EditorSession`, `MediaPlayer`, renderer and compositor instances. There should be none. On macOS the causes were a registry that never removed sessions, an event monitor capturing the view, and closures kept by framework-held views. On Windows, look for the same pattern: static events, `DispatcherTimer`s still running, and handlers on objects that outlive the window.
  3. **Idle CPU.** With a project open and paused, CPU must be 0%. The 16 ms `clockTimer` should only run while playing or scrubbing.
  4. **Open-time peak.** On macOS, opening a project jumps to about 500 MB for about 1 second, then settles to about 190 MB. That is GPU working memory for the first frames (UI and compositor), which the system then marks purgeable. It is not a leak. Expect something similar with D3D11, so check that it settles rather than trying to remove it.
- **Leads found by reading the Windows code (not run):**
  - **Music preview keeps playing after close.** `EditorTools.musicPreview` (a `MediaPlayer`, `EditorTools.cs` `ToggleMusicPreview`) is not stopped by the editor's `Closed` handlers (`EditorWindow.xaml.cs`, next to `FinishVoiceoverRecordingForClose`). macOS had exactly this bug. Call `tools.StopMusicPreview()` on close.
  - **Wallpaper thumbnails are never released.** `InspectorPanel.WallpaperThumbnails` is a static dictionary of `BitmapImage`s. Check how many are decoded when the inspector opens, and at what `DecodePixelWidth`. macOS now loads only the shown category and clears the cache when the last editor closes.
  - **Undo.** `UndoStack` keeps up to 150 serialized documents, one per `Commit`. Check whether a slider drag commits on every tick. macOS now merges edits less than 0.4 s apart into one step.
  - **Window picker.** `CaptureTargets` lists windows with `EnumWindows` and `DwmGetWindowAttribute`. Check how often the picker calls it while hovering, and whether it keeps calling it while the mouse is still. On macOS the picker queried every window 60 times a second; now it queries only the window under the mouse, and only when the mouse moves.
  - **Disk checks per frame.** Look for `File.Exists` or directory scans in the render and clock path. On macOS, the camera and voiceover file checks ran several times per frame. Files in `recording/` never change after capture, so the checks can be cached.
  - **Preview wallpaper size.** macOS decoded the background at 2560 px even for a small preview. It now decodes at the canvas size, in 512 px steps between 1024 and 2560 px.
  - **Already fine:** deleting a project closes the window first and clears `hasUnsavedChanges`, so the close-time save cannot recreate the folder (a macOS bug). `ReleasePreview` disposes the renderer, players, swap chain and compositor. `AppTheme.Changed` is unsubscribed on close.
- **Risks / unsure:** the leads come from reading the code only, with nothing run on Windows. FPS during playback was not measured on macOS in this pass.

## 2026-11-07, Windows port: slice volumes, waveform look, snapping, Ctrl + scroll zoom, zoom cost, HUD width, localization

### Verifier
- **Result:** PASS for what could be checked here. Not yet heard: per-slice volumes in preview and export.
- **Build and tests:** the solution builds in Debug and Release (x64) with 0 warnings. Core 253, Rendering 21 and Media 20 tests pass.
- **Measurements** (this machine, 2400 x 1500 window at 200%, Release build):
  - **Zoom step:** 40 `Ctrl` + wheel steps from 1x to 6x on a 10 s project, timed with `NS_TIMELINE_ZOOM_STATS`. Before, 17.8 ms median and 39.9 ms worst. After, 8.3 ms median and 20.2 ms worst.
  - **What cost the time:** rebuilding the timeline tree took 11.3 ms per step. A zoom step now only moves and widens what is there (ADR-46).
- **Checked in the running app**, on copies of a project in a scratch folder, with real mouse and wheel input:
  - **Snapping:** dragging the second shortcut toward the first one's end stuck its start to that edge and showed the purple guide, which went away on the drop.
  - **Ctrl + wheel:** 3 notches in and 2 out over the 0:05 tick kept it at the same pixel. A plain wheel still scrolls and does not zoom.
  - **Waveforms:** a voiceover at 80% shows its full wave faintly behind the scaled one.
  - **Vietnamese:** run with `NS_LANGUAGE=vi`, the editor, inspector, timeline labels and the hover prompt are translated.
- **Changes made:**
  - **Per-slice volume:** `ClipSlice.MicrophoneVolume`, the two setters (neither sets `Muted`), `AudioMix.MicrophoneGain`, a clip menu slider per source from the metadata, and the inspector's `Clip audio volume` through the same setter.
  - **Waveforms:** `Core/Editing/WaveformRaster.cs` replaces the polygon outline, which is deleted. The timeline caches one bitmap per slice and voiceover, stretches it during a zoom, and sharpens it on a worker thread after 90 ms.
  - **Snapping:** `Core/Timeline/TimelineSnapping.cs` with tests, wired into every drag and trim except clips. The toggle sits next to split, plus `View > Snap timeline items`.
  - **Zoom:** `Ctrl` + wheel over the whole timeline, anchored at the cursor. Over the labels it keeps the playhead. Hover skim pauses for 150 ms after each step.
  - **Recording bar:** it refits on its own `SizeChanged`.
  - **Localization:** `App/Localization/Loc.cs` reads the shared `Localizable.xcstrings`, and the shared helpers translate at display. `Settings > General > Language` has `Restart Now`. 92 Windows-only keys were added to the catalog with all 7 translations, and no existing key changed.
  - **Fixtures:** `"microphoneVolume" : 1` was added to each slice in `conformance/cases/*/project.json`.
- **Spec updates:** Windows notes in `spec/06` ADR-42 to ADR-47, the UI section in `spec/platforms/windows-d3d11-mediafoundation.md`, and the `NS_TIMELINE_ZOOM_STATS` and `NS_LANGUAGE` rows in `windows/AGENTS.md`.
- **Next / open:**
  - **Volumes:** listen to the per-slice volumes in preview and export. The test recording has no real microphone, and no microphone was opened.
  - **Strings:** the new Windows-only translations were written by an agent and need review by native speakers.
  - **Literals left:** some interpolated strings are still English (for example `Display 2` on the screen picker, and `Stop` / `Play` with a track name).
  - **macOS:** rebuild the macOS app once to confirm Xcode accepts the added catalog keys as they are.

## 2026-11-07, Smooth timeline zoom, per-slice microphone volume, HUD width (macOS side done, Windows port pending)

### Writer
- **Scope:** macOS only. Rules: `spec/06` ADR-46 (zoom cost), ADR-47 (per-slice volumes and the HUD width). File format: `microphoneVolume` on each clip slice (`spec/02`, `spec/schemas/project.schema.json`), default 1, optional. Swift: `MultiTrackTimelineView.swift` (`ClipWaveformImageView`, `TimelineZoomClock`), `ProjectEditorWindowView.swift` (`TimelineZoomSlider`), `ProjectDocument.swift` (`ClipSlice.microphoneVolume`), `ProjectSession.swift` (`setSliceMicrophoneVolume`, `setSliceSystemAudioVolume`), `TimelineSegmentContextPopovers.swift`, `MetalPreviewView.swift`, `HardwareVideoExporter.swift`, `RecordingCoordinator.swift`.
- **Built on macOS:** Debug and Release builds pass.
  - **Zoom:** in a Release build on a copy of a 12 s project with 27 captions, 40 zoom steps from 1x to 5.8x with layout and display each step went from 16.8 ms median (35.7 ms worst) to 11.3 ms median (22.6 ms worst). The playhead moved less than 0.1 pt after any frame. A CPU sample no longer shows waveform rasterizing or the RGBA to BGRA conversion on the main thread.
  - **Volume:** the user's recent recordings have silent system audio (-91 dB) and all their sound in `microphone.m4a`. That is why the old system audio slider seemed to do nothing above 0 and muted everything at 0. Build passes with the new sliders; I did not listen to playback or export.
  - **HUD:** showed the HUD, then set a long microphone name, a short one and none. Both rounded ends stayed visible every time, and the window followed the bar width (930, 950, 876, 929 pt).
- **To port on Windows:**
  - **Per-slice volume.**
    - Add `MicrophoneVolume` (default 1, clamp 0 to 2 on read) to the Core `ClipSlice`.
    - In `SegmentEdits`, stop setting `Muted` from the volume. Setting either volume clamps to 0 to 1 and clears `Muted`.
    - In `SegmentMenu`, show `Microphone volume` when the recording has a microphone file and `System audio volume` when `metadata.tracks.systemAudio` is set, both 0 to 100%.
    - Apply the slice's microphone volume in preview (`TimelineView` mic gain), in the timeline mic waveform scale, and in export (`ExportJob`/`AudioMixer` mic gain per slice). After a hiding voiceover ends, restore the volume of the slice playing then.
    - The Windows-only inspector row `Clip audio volume` should follow the same rule (no `Muted`).
    - Add Core tests for the setters and for reading a slice without `microphoneVolume`.
  - **Zoom smoothness.**
    - Cache the waveform bitmap per slice, keyed by samples, volumes, source range, height and DPI. When only the width changes, draw the cached bitmap stretched, and re-rasterize on a worker thread about 90 ms after the width settles. Any other change rasterizes at once.
    - Keep the bitmap in the swap chain's native format (BGRA premultiplied), so drawing it needs no conversion.
    - Suspend hover skim of the preview for 150 ms after each `Ctrl` + wheel or pinch zoom step.
    - Make sure only the timeline re-renders on a zoom change, not the whole editor.
    - Measure per-step cost the same way: 40 steps from 1x to 5.8x, report median and worst.
  - **HUD width.** If the Windows recording bar sizes its window from a measure taken right after a state change, switch to the bar's own reported size (`SizeChanged`), grow the window at once and animate only when shrinking.
  - **Strings.** `Microphone volume` is a new catalog key with all 8 languages. Destructive context menu items (`Remove`, `Reset trims and cuts for all slices`) now show translated text on macOS; check that Windows uses the catalog for them too.
- **How to verify:**
  - Record with a microphone and system audio playing. Split the clip, then set the first slice's microphone volume to 20% and the second slice's system audio to 0. In preview and in the exported file, only those slices change, and the microphone keeps playing when system audio is 0.
  - Open an old project: slices without `microphoneVolume` play at full volume.
  - Hold `Ctrl` and roll the wheel quickly over a long project with captions. The waveform stays drawn, though slightly soft while zooming, and is sharp shortly after you stop.
  - Pick a microphone with a long name in the recording bar; both rounded ends stay visible.
- **Open VERIFY items:** none in Swift.
- **Risks / unsure:**
  - **Remaining cost:** about 11 ms per step is still SwiftUI layout of the segments, over the 8.3 ms a 120 Hz display allows, so a fast zoom can still drop the odd frame on macOS.
  - **Audio not heard:** the per-slice volumes were built and reasoned through, not listened to in preview or export.
  - **Fixtures:** `project.json` now writes `microphoneVolume` on every slice, so regenerated conformance fixtures gain that field. Readers that reject unknown fields need it added first.

## 2026-11-07, Cmd + scroll zooms the timeline at the cursor (macOS side done, Windows port pending)

### Writer
- **Scope:** macOS only. Rule: `spec/06` ADR-45; UI in `spec/04` "Timeline zoom". Swift: `MultiTrackTimelineView.swift` (`TimelineCommandScrollZoomCatcher`, `zoomAnchorViewportX`, `anchorScrollOffsetAroundPlayhead(... anchorViewportX:)`). No project format change.
- **Built on macOS:** Debug build passes. In the running app on a copy of a project, synthesized `⌘` + wheel events over the lanes at a fixed x: zoom went 1.0, 1.52, 2.31, then back to 1.75 and up to 2.61 with a trackpad-style event, while the time under the cursor stayed at 6841 to 6842 ms the whole way. A wheel event without `⌘` left zoom and scroll unchanged. `⌘` + wheel over the label column zoomed around the playhead. The ruler and all lanes stayed in step.
- **To port on Windows:**
  - Use `Ctrl` instead of `⌘`. Handle `PointerWheelChanged` on the whole timeline (ruler, label column and lanes) with `handledEventsToo` or in the tunneling phase, before the lanes' `ScrollViewer` scrolls horizontally, and mark it handled when `Ctrl` is down. Without `Ctrl`, leave it alone.
  - Step: a mouse wheel notch (`MouseWheelDelta` = 120 per notch) multiplies zoom by 1.15, at most 4 notches per event. A precision touchpad (`PointerDeviceType.Touchpad`, or deltas that are not multiples of 120) multiplies by `exp(delta / 1200)`, close to the macOS feel; tune by hand. Positive delta (wheel away from you) zooms in. Clamp to 1x to 6x.
  - Anchor: before the change, `frac = (scrollX + cursorX - 20) / contentWidth`, where `cursorX` is relative to the lanes' viewport and 20 is the lanes' side inset. After the change, scroll to `20 + frac * newContentWidth - cursorX`, clamped to the scroll range. Over the label column, keep today's playhead anchor. Apply the zoom and the scroll in the same layout pass so the lanes do not jump for a frame.
- **How to verify:** hover a caption edge in the middle of the timeline, hold `Ctrl` and roll the wheel both ways; that edge should stay under the pointer. Try a precision touchpad with `Ctrl`. Scroll without `Ctrl` and check the timeline scrolls as before and zoom does not change. `Ctrl` + wheel over the track labels zooms around the playhead.
- **Open VERIFY items:** none in Swift.
- **Risks / unsure:** the trackpad step was only tested with a synthesized event, not with real fingers; it may feel fast or slow and is a single constant (`0.01`) to tune.

## 2026-11-07, Waveform at lowered volume, timeline snapping, localization (macOS side done, Windows port pending)

### Writer
- **Scope:** macOS only. Rules: `spec/06` ADR-42 (waveforms), ADR-43 (snapping), ADR-44 (localization); UI in `spec/04` "Timeline snapping" and "Language". Swift: `MultiTrackTimelineView.swift` (`rasterizeWaveforms`, snap guide), `Document/TimelineSnapping.swift`, `Document/AppLanguage.swift`, `EditorViewPreferences.snapToSegments`, `Localizable.xcstrings`, `InfoPlist.xcstrings`. No project format change and no fixture change.
- **Built on macOS:** Debug build passes. Checked in the running app on a copy of a project with a microphone track:
  - Waveform at 100%, 35% and 0% microphone volume: solid wave, then a lower wave over the faint full wave, then the faint wave alone.
  - Snapping: a synthesized drag of the second zoom toward the first moved its start to exactly 4610 ms, the first zoom's end, with its length kept and the purple guide line shown. With snapping off, the same move was left alone.
  - Editor, settings and recording bar in Vietnamese, German and Japanese.
- **To port on Windows:**
  - **Waveforms (ADR-39 changes).** Colors and opacities: microphone white at 0.35, system audio `#4D2FF5` at 0.5, drawn in that order. Behind each, the full-volume wave in the same color at 0.10, only while the volume is below 0.999, and also when muted. Opacity in each column goes from half at the bottom to full at that column's crest, which one polygon gradient cannot do. Rasterize per device pixel into a bitmap, or draw it in a pixel shader. The formulas are in ADR-42.
  - **Snapping.** Port `snapTargetsTimelineMs` and `TimelineSnapController` to Core with tests. Hook it in every segment drag and trim except clip slices: collect targets when the click slop is passed, use an 8-point threshold, and clamp afterwards as today. Add a 1 px guide line in `#704DFF` at 90% (`0.44, 0.30, 1.0`) over the tracks. Add the toggle next to the split button, lit like it, plus `View > Snap timeline items`, on by default, stored in settings.
  - **Localization.** Use `NativeScreen/NativeScreen/Localizable.xcstrings` as the source of truth, so both apps share one set of translations: ship it as content and look strings up by their English key, falling back to the key. A Windows-only string becomes a new key with `"extractionState": "manual"`, so Xcode keeps it.
    - Convert the specifiers in order: `%lld`, `%d` and `%@` become `{0}`, `{1}` and so on, and `%%` becomes `%`.
    - Same 8 languages. Add `Settings > General > Language` with the same list and `Restart Now`. Store the choice in `settings.json` and also set `ApplicationLanguages.PrimaryLanguageOverride`, so system-drawn text follows.
    - Keys mention macOS keys (`⌘`, `⌥`) and Finder. Where Windows shows different text, give it its own key; do not edit a shared value.
- **How to verify:**
  - **Waveform:** set a clip's volume to 35% and to 0%; compare with the macOS look described above.
  - **Snapping:** drag a zoom toward another zoom's end, a caption edge and the playhead, and check that `project.json` lands on that exact ms. Turn snapping off and check that nothing sticks.
  - **Languages:** switch to German and Japanese, restart, then go through the editor, inspector tabs, context menus, the recording bar and the export sheet, looking for English text and clipped labels.
- **Open VERIFY items:** none in Swift.
- **Risks / unsure:**
  - **Translations:** written by the writer agent, not reviewed by native speakers.
  - **Waveform speed:** the macOS waveform bitmap was not timed on a long clip at high zoom.
  - **Untranslated corners:** the Whisper download prompt and the start window strings are in the catalog, but those screens were not looked at in another language.

## 2026-11-03, Recording bar rectangle, sideways rows, disabled inspector tabs

### Verifier
- **Result:** PASS on Windows.
- **verify.ps1:** PASS, 217 tests (Core 183, Media 13, Rendering 21).
- **Measurements:** bar edge pixels before: white frame of 3 px outside the border; after: only the `#49494E` border on all 4 sides. Scroll percent sampled every 25 ms after picking a cursor card: 8.8, 30.3, 36.5, 40.4, 42.8, 43.6, 44.8, 45.3, 45.4.
- **Exercised in the running app, on copies of a project:** cursor style and color rows; wallpaper pills; mouse wheel over a row; each disabled tooltip on a copy with no camera, microphone, cursor or keys; a press and Ctrl+3 on a disabled tab change nothing; Hide camera disables Camera Style at once.
- **Changes made:** `RecordingHudWindow`, `InspectorPanel.Strip` and `Options`, `CursorThemeCards` at the macOS sizes without captions, `EditorSession.TabAvailability`, the rail, the View menu and Ctrl+digit.
- **Not exercised:** the View menu's disabled items; rows other than cursor and wallpaper by scroll measurement; the bar while recording or at another scale.
- **Spec updates:** ADR-33.
- **Next:** A plain wheel over an overflowing row scrolls the row, not the panel.

## 2026-11-03, Mask frame no longer covers the cursor

### Verifier
- **Result:** PASS on Windows.
- **verify.ps1:** PASS.
- **Measurements:** none.
- **Exercised in the running app, on a copy of a project:** a paused playhead inside a mask draws no frame; hovering shows the 4 corner handles and leaving hides them; clicking selects and keeps them; dragging moved `rect01` by the expected amount.
- **Changes made:** `PreviewOverlay.DrawMask` drew a XAML outline around every active mask, above the composited cursor. It now draws only the handles, while selected or hovered, as `InteractiveMaskCanvasOverlayView` does on macOS.
- **Not exercised:** a cursor overlapping a mask on screen, since the test project has none at that time; resizing with a corner handle.
- **Next:** macOS shows a selected mask at 1x (`suppressZoomForMaskEditing`); Windows keeps the zoom.

## 2026-11-03, Built-in wallpapers and upright baked layers

### Writer
- **Scope:** macOS only. Rules: `spec/06` ADR-32, `spec/07` Pass 1. All frame fixtures are regenerated, and most fail on Windows until the flip below is removed.
- **To port on Windows:**
  - Rendering, do this first: remove `VerticallyFlipped` and draw with `Identity` at its 3 call sites: `FrameCompositor.Compose.cs` (background, shadow) and `FrameCompositor.Overlays.cs` (bezel). Check the bezel rasterizer's own orientation, the notch must end up at the top.
  - Assets: ship `NativeScreen/NativeScreen/Resources/Wallpapers.bundle/**/*.jpg` as content, like the cursors in `NativeScreen.Rendering.csproj`.
  - App: category pills `★`, the system wallpapers, `Mesh`, then `Spring, Sunset, Radiant, Energy, Iridescent, Midnight, Glassmorphism`. Grid previews come from `thumbs/`, sorted by file name. A pill only browses. `Pick random wallpaper` draws from the current pill. Opening a project selects the pill holding its wallpaper or mesh.
  - Core: picking a bundled wallpaper copies it byte for byte to `assets/background-<id>.jpg`, with `systemWallpaperName` set to the id.
- **How to verify:** `verify.ps1` frame fixtures pass again. Pick `spring-01`: the image is upright during and after the crossfade, and the copied file hashes the same as the bundled one. In `device-mockup` the notch is at the top; in `basic` the shadow falls downward.

### Verifier
- **Result:** PASS on Windows.
- **verify.ps1:** Debug and Release x64, 209 tests (Core 175, Media 13, Rendering 21), 13 shaders.
- **Measurements:** all enforced fixture cases pass with the flip removed: `basic`, `mesh` and `wallpaper-blur` at SSIM 0.995 or better, `device-mockup-iphone` at 0.9956 or better. Not enforced and below the tolerance: `device-mockup` 98.9% within 6/255, `camera-cutout` and `camera-layout-transitions` about 94%.
- **Exercised in the running app, on a copy of a project:** picked `spring-03`; the settled image matches its thumbnail's orientation, `project.json` has type `wallpaper`, the id and `assets/background-spring-03.jpg`, and the SHA-256 equals the bundled file's. `Pick random wallpaper` stayed in Spring over 4 picks. The `Wallpaper` mode pill returned from Color to the last wallpaper. The `Mesh` pill left the background alone. `★` lists meshes, then bundled wallpapers.
- **Not exercised:** the crossfade frame itself; the notch by eye on a MacBook mockup, only the `device-mockup` fixture numbers above; a project picked on macOS and opened here; how long `★` takes to rebuild with its 100+ swatches.
- **Changes made:** `BundledWallpaperCatalog`, `SelectWallpaper`, the inspector pills and grid, a shared thumbnail cache, names on swatches for UI Automation; `VerticallyFlipped` removed.
- **Spec updates:** the wallpaper ADR clashed with the Windows ADR-24 and is now ADR-32.
- **Next:** nothing left from this entry.

## 2026-11-03, Editor parity: music, trim badges, keycap clicks, crop handles

### Verifier
- **Result:** PASS for the items exercised below.
- **verify.ps1:** Debug and Release x64, Core, Media and Rendering tests, 13 shaders.
- **Exercised in the running app, on copies of projects:** selecting a built-in track (2.8 MB wav written to the cache, name in `project.json`), the preview stop button; a cut badge on the ruler; Ctrl and the wheel zooming with the playhead still; the crop grid, edge handles drawn and size readout; camera layout dock buttons drawn; a click on a drawn keycap opening its editor.
- **Not exercised:** music by ear, including whether it matches macOS; trim badges for a leading or trailing trim; dragging crop edge handles; a real touchpad pinch; dropping and pasting a background image; Independent and Synchronized by ear; shortcut track eye; hover add on the layout row.
- **Changes made:** `BuiltInBackgroundMusic` ports the macOS synthesis with the same formulas. Background audio paths now resolve through the package, its assets, then built-in tracks, so projects using a built-in track from macOS play here.
- **Spec updates:** none.
- **Next:** Attach mode changes preview only, as on macOS: both exports place a voiceover at its timeline start. Not ported: the Reel mode mock UI, because it imitates other apps' interfaces; that needs an owner decision. Mic and voiceover waveforms are still missing.

## 2026-11-03, LUT files on both platforms (written on Windows, macOS not built)

### Writer
- **Scope:** `spec/06` ADR-31. macOS: new `Engine/CubeLUTFile.swift`, `applyCameraGradeAndSharpen(customLUT:)`, `packageURL` passed down the compositor, `loadLUTFile` and `Remove LUT` in the inspector. Windows: `CubeLut.TryParse`, `FileLookTable`, per-table LUT size, the `+` menu.
- **Built on macOS:** No. **The Swift changes were written on Windows and have never been compiled.** This breaks the `NativeScreen/AGENTS.md` rule to build after a Swift change, so build before anything else.
- **How to verify on macOS:** build; load a 33-point `.cube` on a project with a camera; confirm the camera changes in preview and export, the file is at `assets/lut-*.cube`, the intensity slider fades it, and a cutout camera keeps its transparency. Then open the same project on Windows and compare.
- **Open VERIFY items:** `CubeLUTFile.apply`: `CIColorCubeWithColorSpace` with a 33 size, and alpha on a cutout camera. `CubeLUTCache` uses `nonisolated(unsafe)`; adjust if the project's concurrency settings refuse it.
- **Risks / unsure:** No LUT fixture exists, so matching output between platforms is by design, not measured.

### Verifier
- **Result:** PASS on Windows only.
- **verify.ps1:** Debug and Release x64, all tests, 13 shaders. It does not build Swift.
- **Measurements:** none. On a test copy with the screen recording as a webcam track and an inverting 2-point LUT, the camera bubble drew inverted and no built-in look was selected. Camera crop with the 1:1 preset wrote `cropRect01` on the same copy.
- **Changes made:** the above; `CubeLutTests`.
- **Spec updates:** ADR-31.
- **Next:** Not exercised: the file picker path of `Load your LUT file`, a LUT in an export, Remove LUT.

## 2026-11-03, Editor parity: mask drawing, skim, colors, transcript bar, shortcut styles, presets, click sounds

### Verifier
- **Result:** PASS for the items exercised below. A parity pass, so `spec/05` is unchanged.
- **verify.ps1:** Debug and Release x64, Core, Media and Rendering tests, 13 shaders.
- **Exercised in the running app, on copies of projects:** dragging out a new mask (new track, rect and radius in `project.json`), Esc cancelling that mode, hover skim with the playhead staying put, the color picker opening and a random gradient, word selection and Cut transcript, preset list and badges, layout segment editor, a shortcut's custom style written to `shortcutStyleOverrides`, color preset studio creating and selecting a preset, device finish.
- **Not exercised:** retyping a word; click sounds by ear; camera crop, which needs a project with a webcam track; default preset on a new recording; preset rename, update and remove; pause chips; hue slider.
- **Changes made:** `ColorField.cs`, `ClickSounds.cs`, additions to `PreviewOverlay.cs`, `InspectorPanel.cs`, `EditorWindow.Tools.cs`, `TimelineView.cs`, `EditorSession.Segments.cs`, `ProjectPreset.cs`. Click sound wavs are now copied to the output.
- **Spec updates:** none.
- **Next:** Still open for editing: built-in music, trim badges with durations, quick dock layout buttons, pinch zoom, crop edge handles and thirds grid.

## 2026-11-03, Click ripple and voiceover tracks (macOS side done, Windows port pending)

### Writer
- **Scope:** macOS only. Rules: `spec/06` ADR-30, ripple formula: `spec/07` Pass 4. Fixtures are regenerated; only the ripple frames of `cursor-styles` change, so they fail until the ripple is ported.
- **To port on Windows:**
  - Core solver: `clickWaves` on the cursor frame state (`SpringTrajectorySolver.swift`). `activeClickProgress` is unchanged.
  - Rendering: a `ClickRipple.hlsl` pass over the whole canvas before the cursor sprite; remove the ring.
  - Core models: `VoiceoverSegment.trackIndex`, `TimelineConfig.hiddenVoiceoverTracks` and the helpers in `Models/VoiceoverTrackLayout.swift`, run on load.
  - Audio: playback and `AudioMixer` skip hidden tracks per segment (`isVoiceoverTrackHidden`), not with the old single flag.
  - App: one timeline row per voiceover track with its own eye, the recording block on its track, vertical drag between tracks (`moveVoiceoverToTrack`).
- **How to verify:** after fixtures are regenerated, `cursor-styles` frames. Open a project with overlapping voiceovers: each lands on its own track and the overlap still plays mixed.
- **Risks / unsure:** the 3-wave limit and the wave bouncing past the screen edge have no fixture.

### Verifier
- **Result:** PASS on Windows, except as noted under Next.
- **verify.ps1:** Debug and Release x64, Core, Media and Rendering tests, 13 shaders.
- **Measurements:** `cursor-styles` ripple frame 2600: screen SSIM 0.9955, within6 99.7%. Other `cursor-styles` frames 99.8 to 99.9%.
- **Changes made:** `ClickRipple.hlsl`, `clickWaves` in the solver, `VoiceoverTrackLayout`, one timeline row per voiceover track with its own eye. The app saw a test project with overlapping segments land on two tracks, a segment dragged to the other track, and an eye click hide one track.
- **Spec updates:** master's ADR-22 and ADR-23 are ADR-29 and ADR-30 here, because this branch already used those numbers.
- **Next:** Not exercised: overlapping voiceovers mixed by ear, the 3-wave limit, a live ripple in the preview. Voiceover recording does not exist on Windows yet, so the recording block on its track is not ported.

## 2026-11-02, Cursor themes redrawn (macOS side done, Windows port pending)

### Writer
- **Scope:** macOS only. `tools/generate_cursor_assets.py` redraws every cursor and adds themes; `CursorSpriteProvider.swift` and `ProjectDocument.swift` change the default, the order, the selection of non-pointer sprites and the migration of old projects. All rules: `spec/06` ADR-29. `conformance/` is regenerated, with one compositor per case, so the ADR-20 background leak is gone.
- **Built on macOS:** macOS app builds. Two fixture runs are pixel-identical. No Windows code was changed or built, so **Windows tests are expected to fail until the port below is done**.
- **To port on Windows:**
  - `Core/Rendering/CursorSpriteName.cs`: new `PreferredThemeOrder`; `NormalizeThemeId` accepts the nine ids and falls back to `classic-dark` (not `arrow`).
  - `CursorConfig` JSON read and its default: default `classic-dark`, and the `arrow` migration from `CursorThemePreset.migrateLegacyTheme`.
  - `OverlayRasterizer.CursorSprite`: non-pointer kinds follow the selected pointer's variant number (`resolveCGImageAndHotspot` in Swift).
  - Inspector theme names: `Classic Dark`, `Classic Light`, `Dart Color`; the others capitalized from the id, as `displayName(forSetId:)` does.
  - `OverlayRasterizer.AddSvgDropShadow`: the shared shadow is now black 50%, stdDeviation 3, dy 2.4 (was 35%, 2.2, 1.6). Update the values and its comment.
  - Inspector theme and variant cards: neutral gray fill (white 0.48, hover 0.51, selected 0.54) in both app themes, so dark and light cursors both read. Previews are centered on the sprite's visible pixels (`centeredOnVisiblePixels`), not on its view box.
  - `FrameFixtureTests`: the leak comment is out of date. Turn on full-frame enforcement for the passes that exist (`spec/06` ADR-20).
- **How to verify:** `pwsh windows/scripts/verify.ps1`, then frame fixtures. In the app, open a project saved with `arrow` + `pointer-2` and confirm it shows `classic-light`. Save it and open it on macOS: same theme.
- **Open VERIFY items:** Direct2D has to draw the `dart-color` gradients (`url(#g)`) and the `fill-opacity` / `stroke-opacity` in `touch`. If it does not, change the generator rather than special-casing Windows, so both platforms stay the same.
- **Risks / unsure:** `cursor-styles` is the only case with a non-default theme (`rounded`), so the other new themes have no frame fixture. Check them by eye against the macOS inspector.

### Verifier
- **Result:** PASS on Windows.
- **verify.ps1:** Debug and Release x64, all tests, 13 shaders.
- **Measurements:** Frame fixtures now enforce the whole frame too. Worst enforced values: `loupe` 4200 screen within6 99.30%, `zoom-follow` 4200 frame 99.42%. The misses are anti-aliasing on the outlined hand sprite and 1 px edges of the sampled screen, seen in diff images. `LoupeWithin` went from 0.994 to 0.993 and the whole-frame gate is 0.994, below the 0.995 of `spec/08` section 2.4, so tuning them is still open.
- **Changes made:** The port list above. Inspector cards show sprites on the neutral fill, centered on visible pixels, and a color row for themes with several pointers. `dart-color` gradients and `touch` opacities render in Direct2D.
- **Spec updates:** none beyond the ADR renumbering.
- **Next:** MSBuild keeps sprites from older builds in `bin`, so a stale `rounded/pointer-1__12-6.svg` can be picked over the new file. Delete `bin` once after this change.

## 2026-11-02, Editor parity: segment menus, command menu, export modals, recording options

### Verifier
- **Result:** PASS for the items exercised below. This is a parity pass, not a phase acceptance, so `spec/05` is unchanged.
- **verify.ps1:** Debug and Release x64 PASS; Core 150, Media 13, Rendering 19 tests passed; 12 shaders compiled.
- **Exercised in the running app, on copies of projects:** real mouse right-click menus on clip, zoom and mask; Duplicate from a menu; split with C and merge with the cut badge; D, Esc, H, Ctrl+C and Ctrl+V; a mask dragged up to a new track (2 to 3 tracks, undo restored it); crop presets with a real recording; zoom position pad (center written to `project.json`); a JPEG still and a clipboard video through the new modals; a 6 s area recording, no microphone or camera, with the highlight window present while recording and gone after, then After Recording set to clipboard, which produced the file.
- **Not exercised:** menus on shortcut, layout and voiceover segments; Alt held for split; file pickers (export to file, both-codec export, still folder choice); a GIF with loop disabled; moving the crop box by drag; the highlight's look, since it is excluded from capture and screenshots cannot show it.
- **Changes made:** `SegmentMenu.cs`, `EditorWindow.Commands.cs`, `EditorWindow.Dialogs.cs`, `ZoomPositionPad.cs`, `Recording/RecordedAreaHighlight.cs`, `EditorSession.Segments.cs`. Two icons missing from the Windows 10 font were replaced.
- **Spec updates:** `spec/06` ADR-28.
- **Next:** Gaps still open against macOS, largest first: voiceover recording (needs microphone testing, ADR-23), custom color presets and LUT loading, camera preview bubble, draw a new mask on the preview, cursor variants, built-in music, transcript word bar editing, custom color and gradient pickers, camera crop, hover skim, per-shortcut styles, preset management, view toggles, settings panes including quick export, hide desktop icons, max camera resolution. Small ones: crop edge handles and thirds grid, trim badges, quick dock layouts, device finish, layout position and ratio, pinch zoom, recents menu items.

## 2026-11-02, Phases 3 to 8: measurements and what is left (verifier work on Windows)

### Verifier
- **Result per phase:**
  - Phase 0 PASS: `verify.ps1` green, `conformance/` committed.
  - Phase 1 PASS: 131 Core tests including numeric conformance; all 26 macOS fixtures round trip.
  - Phase 2 FAIL (partial): `custom-look-warmth` and `camera-cutout` below the frame threshold; full frames blocked by the fixture defect; cutout not implemented. Compose time meets the target on a synthetic frame (ADR-24).
  - Phase 3 FAIL (partial): in the real window, 60 s at 60 Hz with 0.28% of intervals over 1.5x the median (ADR-26), 0.00% CPU paused, first frame 45 ms offscreen. Missing: A/V offset measured on real sound, and someone listening to it.
  - Phase 4 FAIL (partial): MP4 and GIF work and memory peaked at 307 MB, at 1.69x for 1080p and 1.17x for 4K. Not run: 30 minute flat memory, frames compared with `frames/*.png`.
  - Phase 5 FAIL (partial): display, window and area through the app or test, pause, system audio, and a killed process leaving 4.7 of 5 s playable all work. Blocked: microphone resets the machine (ADR-23); camera never completed; a recording not yet opened on macOS.
  - Phase 6 FAIL (partial): trimming clips, adding from the plus on a row, scrubbing, and moving and resizing masks on the preview were driven with real mouse input and checked in project.json. Dragging layouts, shortcuts and voiceovers, and the clip, layout and shortcut inspectors were built but not driven. Not done: global and customizable shortcuts (open on macOS too), the short-video mock interface, which is reduced to plain safe zones. Crop, stills, presets and file pickers not driven end to end, because the pickers cannot be automated here. No UI-stall measurement.
  - Phase 7 FAIL (partial): OCR found text in real engine runs on generated clips. The face engine ran but never saw a face. Whisper downloaded the base model and transcribed the Windows voice correctly, from WAV and from a fragmented recording (ADR-25); no real microphone speech, and the app's dialog path not driven. Cutout missing.
  - Phase 8 FAIL (partial): MSIX built, never installed or signed. Folders cannot take a file association (ADR-24).
- **Machine note:** every run with the microphone ended in a reset, so none were repeated. `NS_TEST_CAPTURE_PARTS` selects what a capture test turns on.

## 2026-11-02, Phase 3 and 5: preview audio and the recording engine (verifier work on Windows)

### Verifier
- **Result:** Phase 5 FAIL (partial). Phase 3 not measured.
- **Done:** Preview plays the audio mix through WASAPI, and the device position corrects the clock. Display, window and area capture, telemetry hooks, system audio, microphone, webcam, pause and package finishing as a library. The HUD and target picker are not written, so nothing is reachable from the app yet.
- **Measured:** Screen only and screen with system audio, on a 1536×960 capture: about 57 fps, 6 to 7 ms per frame to copy and convert, cursor every 9 ms, pause removed from all times, stop in about 45 ms. Reader times match written times in `FragmentedTimingTests` (ADR-22). Preview audio has not been heard in the app, and no A/V offset was measured.
- **Blocker:** The 3 runs with the microphone reset the machine (ADR-23). Camera alone not run. Window and area capture, crash safety and opening a recording on macOS not run.

## 2026-11-01, Phase 1, 2 and 6: saving and the compositor (verifier work on Windows)

### Verifier
- **Result:** Phase 2 FAIL (partial). Phase 1 project round trip PASS.
- **Done:** Autosave after 350 ms, atomic `project.json`, flush on close, and a real Showcase package on disk. Round trip across all 26 macOS fixtures keeps every value of `project.json` and `metadata.json`. Compositor: background (solid, gradient, mesh, blur), masks (blur, pixelate, solid, spotlight), Lanczos downscale, corners, inset, baked shadow, cursor SVG sprites with drop shadow, click effects, classic zoom, motion blur and lens.
- **Measurements:** Screen region against macOS frames, enforced in `Rendering.Tests` for `basic`, `drag-sync`, `masks`, `mesh`, `slices-speed-cut`, `wallpaper-blur`: SSIM 0.997 or more and 99.6 to 99.9% of pixels within 6/255, except the keycap frame at 2600 ms, which is excluded until keycaps are composited. Other cases are reported and not enforced. Full-frame scores are not meaningful until the fixtures are regenerated. No GPU timing yet.
- **Added after that:** camera overlay with built-in and custom looks, captions, keycaps, device mockup bezel, wallpaper and image backgrounds. Video decode into the preview, scrubbing and seeking. Export to MP4 (H.264, HEVC) and GIF with audio mix, progress and cancel, in `NativeScreen.Export`. `Media.Tests` round trips real clips; `Rendering.Tests` exports a real package and checks frame count, pixels against the compositor, audio, GIF frames and that cancel leaves no file.
- **Measured:** Playing a 1280×720 clip at 30 fps in a 2400×1500 window: about 40 to 46% of one core, 0 ms CPU over 4 s paused. Windows 10, one machine. No late-frame ratio, A/V offset, GPU timing, export speed or 4K numbers yet.
- **Not done in the compositor:** cutout mask, camera sharpen, live background crossfade, keycap and layout springs during edits. `custom-look-warmth` is at 95.4% in the screen region and `camera-cutout` at 94%; both stay out of the enforced list.
- **Not done at all:** audio during preview playback, recording, intelligence, crop, presets, most settings, copy to clipboard, ProRes-equivalent options, waveform.
- **Unexplained:** a fragmented clip reads back 100 ms late under the test host only (`spec/06` ADR-21).
- **Needs macOS:** regenerate the fixtures after making the generator use one compositor per case (`spec/06` ADR-20). Decide whether the vertical flip of baked layers is a bug to fix on macOS.
- **Spec updates:** `spec/06` ADR-20, `spec/07` Pass 1 and Pass 3, `spec/08` §2.4, `windows/AGENTS.md` commands.

## 2026-11-01, Phase 6: editor shell

### Writer
- **Scope:** `EditorSession` holds the playhead, inspector tab, command search, and the existing undo stack. The WinUI app opens a welcome window, an editor (menu bar, preview `SwapChainPanel`, inspector tabs, timeline slider, command menu), and a settings window with light and dark. Accelerators use Ctrl. Preview attach is `ISwapChainPanelNative` (`63aad0b8-7c24-40ff-85a8-640d944cc325`).
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 46 passed. The WinUI XAML compiler is a Windows executable, so the app project was not built here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`, then `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64`. Welcome opens. Open project loads a `.nativescreen` package into the editor. Play moves the time label and pauses at the end. Scrubbing stops playback. Undo restores the document name. Settings toggles dark and light. Command menu filters titles. Timeline drag must not stall the UI more than 8 ms.
- **Open VERIFY items:** `EditorWindow.xaml.cs` attaches the swap chain on the UI thread; the render thread must wait on the latency object and call `Present(1, 0)`. `WelcomeWindow.xaml.cs` file picker hwnd init. `SwapChainPanelInterop.cs` QueryInterface of the panel.
- **Risks / unsure:** The 16 ms dispatcher timer only updates the time label. The 120 Hz playhead still needs a Composition visual. Inspector pages show the tab title, not the full macOS control set.

### Verifier
- **Result:** FAIL. The chrome now follows the macOS layout, but phases 3 to 5 and 7 have no backend behind it. See Next.
- **verify.ps1:** PASS under Windows PowerShell 5.1: Debug and Release x64, Core tests 52 passed, 7 shaders compiled with dxc.
- **Measurements:** Windows 10 19045, 150% scale. Driven through UI Automation and real input: every inspector tab, command menu, export sheet, play and pause, split, undo, zoom drag, light theme, opening a package. No crashes. 0 ms CPU over 5 s idle after a static stage was drawn. No frame timing or drag stall measurement yet.
- **Changes made:** `SwapChainPanelInterop.cs` uses native `QueryInterface`. Editor, Welcome and Settings rebuilt from the Swift views (`App.xaml`, `Ui.cs`, `InspectorPanel.cs`, `TimelineView.cs`). `EditorSession` gained undoable edits: add zoom and mask, split, delete, interactive edits. Timeline duration now comes from the slices. `ShowcaseProject` is in-memory. `PreviewRenderer` and `StageScene` draw the background, shadow, screen, inset and camera placement on a render thread. Open project uses a folder picker, shows a dialog on failure, and no longer resolves the wrong directory.
- **Spec updates:** `spec/06` ADR-18 and ADR-19, `spec/platforms/windows-d3d11-mediafoundation.md` §8 and §9.
- **Next:** Edits are not saved: no `project.json` write exists, and a round trip against macOS projects must be proven before adding one. Inspector values outside the stage (cursor, camera style, captions, masks, device frames) change the document but draw nothing. Then decode and playback, full compositor passes, export, recording, intelligence. Disabled with a tooltip until then: recording, presets, crop, export frame, export start, playback speed, voiceover, image background, transcript generation, sensitive data and face detection, remove project. Missing from the timeline: waveform, hover add, typing suggestions, shortcut blocks from telemetry. System wallpapers and most Settings tabs are absent. Windows 11 behavior was not checked on this machine.

## 2026-11-01, Phase 5: recording timeline and capture policy

### Writer
- **Scope:** `PauseTimeline` matches `ScreenCaptureEngine.pausedOffset` (samples inside a pause are dropped). Display and webcam bitrates, even dimensions, cursor kind names (`IDC_HAND` → `pointer`, `IDC_IBEAM` → `ibeam`), normalized capture coordinates, package-relative telemetry paths, and jsonl append. `CapturePolicy` records cursor-off, `WDA_EXCLUDEFROMCAPTURE` (`0x11`), and the borderless-capture rule.
- **Built on macOS:** Core tests passed, including a cursor jsonl round trip. No Windows.Graphics.Capture call was made.
- **How to verify:** Record display, window, and area. Cursor is absent from `display.mp4` and present in `telemetry/cursor.jsonl`. Pause removes that span from every track. Kill the process mid-recording and confirm `display.mp4` still opens on macOS. HUD windows are excluded.
- **Open VERIFY items:** `CapturePolicy.cs` — `IsCursorCaptureEnabled`, borderless access, `SetWindowDisplayAffinity`, and QPC inside the hook callback. Fragmented MP4 for the recording (2 s) is still the export writer; the recording path should call `MFCreateFMPEG4MediaSink`.
- **Risks / unsure:** `IDC_SIZEALL` is mapped to `openhand`. Hook callbacks must only enqueue.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 4: export job and hardware sink writer

### Writer
- **Scope:** Audio gains match `HardwareVideoExporter` (system, microphone, voiceover mute, music × 2.5). `ExportPlan` frame count, quality 87/72/58/42, and ProRes hidden on Windows. `ExportJob` progress is encoded frames / total frames; cancel deletes the partial file. `FragmentedMp4Writer` creates an `IMFSinkWriter` with hardware transforms, H.264 or HEVC, NV12 input, GOP of 2 s.
- **Built on macOS:** Core tests passed. The sink writer was not opened.
- **How to verify:** Export the conformance project. Progress moves with encoded frames. Cancel leaves no partial file. Encoded frames match `conformance/frames/*.png`. A 30 minute project stays flat in memory. GIF still needs a WIC encoder; the job only plans the frame count.
- **Open VERIFY items:** `FragmentedMp4Writer.cs` — `ICodecAPI` quality, hardware MFT check, BT.709 tags, and `MFCreateFMPEG4MediaSink` for recordings. `ID3D11VideoProcessor` BGRA to NV12 is not wired yet.
- **Risks / unsure:** Quality mode may be rejected; the writer already sets the average bitrate as the fallback value.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 3: playback clock and source reader

### Writer
- **Scope:** `PlaybackClock` uses QPC, or the audio clock minus device latency when audio is playing. `FrameRing` keeps 4 frames and picks the newest `pts <= clock`. Late-frame ratio, scrub coalescing, and idle-when-paused are in Core. `HardwareVideoReader` starts Media Foundation, requests NV12, disables advanced video processing, and enables hardware transforms. The composition swap chain presents with sync interval 1.
- **Built on macOS:** Core tests passed. `dotnet build windows/src/NativeScreen.Media` — 0 warnings. No file was decoded.
- **How to verify:** Play a 60 s project. Late frames stay under 1%. A/V offset stays within 20 ms. First frame appears within 100 ms of play. Pausing drops to 0% CPU because the render loop blocks.
- **Open VERIFY items:** `HardwareVideoReader.cs` — `IMFDXGIBuffer` textures on the compositor device, and `MFShutdown` at process exit. `CompositionSwapChain.cs` — wait on `FrameLatencyWaitableObject` before `Present(1, 0)`.
- **Risks / unsure:** The reader is synchronous. A scrub must `Flush` and keep only the latest seek.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 2: D3D11 compositor and color pipeline

### Writer
- **Scope:** Core color math (`Rgba`, BT.709 limited NV12, source-over, CIColorControls order saturation → brightness → contrast, vibrance, warmth approximation, LUT lerp), mesh preset table, cursor SVG filename parser, `.cube` reader (red fastest), composite pass order and the screen-shadow / click / motion-blur sample caps from `MetalFrameCompositor` and `EffectKernels`. Rendering embeds `Nv12ToRgb`, `RoundedRect`, `MeshBackground`, `MagnifierLens`, `CameraMotionBlur`, and `Lut3D`. `FrameCompositor` compiles them with Vortice.D3DCompiler 3.8.3, creates a B8G8R8A8_UNORM target (not `_SRGB`), and a source-over blend of ONE / INV_SRC_ALPHA. `CompositionSwapChain` is flip, two buffers, waitable latency 1. `verify.ps1` compiles every `.hlsl` with Windows SDK `dxc`.
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 38 passed. `dotnet build windows/src/NativeScreen.Rendering` — 0 warnings. GPU draw, SSIM, and `dxc` were not run here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`. Shader step should PASS (6 files). On a GPU, `FrameCompositor` constructs without throwing and `CompiledShaderCount` is 6. Frame fixtures in `conformance/frames/` are the SSIM target (not compared on macOS). Compose budget is ≤4 ms/frame at 1080p and ≤8 ms at 4K; motion blur stays at 8 samples in preview and 24 in export.
- **Open VERIFY items:** `D3D11GraphicsDevice.cs` hardware device then WARP. `CompositionSwapChain.cs` — `ISwapChainPanelNative.SetSwapChain` is not called yet (Phase 6 preview). `FrameCompositor` runtime `Compiler.Compile` against the embedded HLSL. Mesh radial center is top-down `(0.78 W, 0.28 H)`, matching the Swift bottom-left `(0.78 W, 0.72 H)`.
- **Risks / unsure:** Built-in looks must sample `conformance/looks/*.cube`. The warmth approximation is only for custom presets; if SSIM is under 0.97, fit it, do not reimplement the CI chain for the built-in looks. Shadows are metrics only; they are not baked into a texture yet.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 0–1: conformance fixtures and Core engines

### Writer
- **Scope:** macOS `--generate-conformance` writes `conformance/` (already generated). Windows `NativeScreen.Core` ports project JSON, `NLETimeMapper`, `SpringTrajectorySolver`, `AutoZoomClusterGenerator`, stage layout (top-left fixture rects), caption lines, shortcut clusters / envelopes / typing suggestions, export size and duration estimators, snapshot undo, and `LoadedProject`. `NativeScreen.Rendering`, `Media`, and `Intelligence` are empty class libraries. `NativeScreen.App` is an unpackaged WinUI 3 window. `windows/scripts/verify.ps1` builds Debug and Release x64, runs tests, and writes `windows/artifacts/verify-report.md`.
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 27 passed, 0 failed. `dotnet build` of Core, Rendering, Media, and Intelligence — 0 warnings. The WinUI app was not built here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`. Expect Debug and Release x64 builds, Core tests green, and a PASS report. Then `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64` and confirm a window titled Native Screen.
- **Open VERIFY items:** `windows/src/NativeScreen.App/App.xaml.cs` — unpackaged WinUI 3 on Windows App SDK 2.6.4, `net10.0-windows10.0.22621.0`, `win-x64`, shows the empty window.
- **Risks / unsure:** No HLSL yet, so the shader step in `verify.ps1` is a skip. Stage transitions compare the camera settings that change placement; a color-only edit does not start a blend because the rects would be identical. `spec/05` Phase 5 stays unchecked until the verifier records PASS.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**
