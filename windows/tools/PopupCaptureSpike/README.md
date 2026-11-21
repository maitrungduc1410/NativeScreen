# Popup capture spike

Which popup windows a window recording leaves out (spec/05, Capture: menus and dropdowns missing from window capture).

For each case a popup is opened over an app's window. Every window of that app's process that became visible is listed,
then:

- **A**: the main window is captured with Windows.Graphics.Capture (what the recorder does today), and the popup's
  rectangle in it is compared with the same rectangle in a Desktop Duplication frame of the screen. The same pixels (mean
  difference per channel near 0) mean the popup is in the window capture; around 100 to 200 means it is not.
- **B**: the popup window is captured on its own with Windows.Graphics.Capture.

Cases: WinForms and Win32 popups and WPF popups in the spike's own windows, WinUI 3 flyouts in a Native Screen editor
(a sandboxed copy of the app), and a `<select>` in Chrome, started with a throwaway profile.

```powershell
$env:NS_SPIKE_PROJECT = "<a .nativescreen folder>"   # opened in the sandboxed Native Screen
dotnet run --project windows/tools/PopupCaptureSpike -c Release -p:Platform=x64 -- <output folder> <NativeScreen.App.exe>
```

It writes `report.md` and the captured PNGs to the output folder. Without the second argument the WinUI cases are
skipped. Not part of the solution.

## Result (2026-11-21, Windows 10 19045, 200 % scale)

| Toolkit | Popup | Window class | Tool window | Owner | A: in window capture | B: alone |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| Win32 | Menu (`TrackPopupMenu`; menu bars too) | `#32768` | yes | none | **no** | refused |
| Win32 | ComboBox dropdown list | `ComboLBox` | yes | none | **no** | refused |
| Win32 | Tooltip | `tooltips_class32` | yes | none | **no** | refused |
| WinForms | `ContextMenuStrip` | `WindowsForms10.Window...` | no | main window | yes | refused |
| WinForms | DateTimePicker calendar | `DropDown` | no | main window | yes | refused |
| WinForms | Owned borderless window | `WindowsForms10.Window...` | no | main window | yes | refused |
| WPF | ComboBox dropdown | `HwndWrapper[...]` | yes | none | **no** | refused |
| WPF | ContextMenu | `HwndWrapper[...]` | yes | none | **no** | refused |
| WPF | ToolTip | `HwndWrapper[...]` | yes | none | **no** | refused |
| WinUI 3 | Editor menu and preset flyouts | `Microsoft.UI.Content.PopupWindowSiteBridge` | no | main window | yes | refused |
| Chromium (Chrome) | `<select>` dropdown | `Chrome_WidgetWin_1` | yes | main window | **no** | refused |

- **Tool windows are left out.** Every popup with `WS_EX_TOOLWINDOW` is missing from the window capture, owned or not
  (the Chrome `<select>` list is owned by the page's window and still missing). Every popup without it is there, and all
  of those are owned by the recorded window. Not tested: an unowned popup without the tool window style.
- That covers the common ones: Win32 menus and menu bars, ComboBox lists and tooltips (the owner's Win32 dialog), all
  WPF popups, and Chromium popups (`<select>` in Chrome and Edge, likely the same in Electron apps such as VS Code).
- WinUI 3 flyouts (Native Screen's own editor) and WinForms context menus are captured already.
- **A popup cannot be captured on its own:** `CreateForWindow` refuses every one of them (`E_INVALIDARG`), tool window or
  not. It also refuses the recording bar, which is a tool window.
- **Desktop Duplication has them all**, at their place on the screen, with no capture border.

So the planned fix stands: while a visible popup of the recorded window's process that the window capture leaves out (a
tool window) overlaps the recorded window, copy its rectangle from a Desktop Duplication frame into the frame. Popups
the capture already has need nothing.
