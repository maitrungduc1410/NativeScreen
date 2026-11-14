# Product Hunt gallery

`out/`: the 6 gallery images (2540 × 1520 PNG, twice the 1270 × 760 Product Hunt recommends), in upload order.

Each one is an editor window capture from `raw/` with a title and a line of text above it. To rebuild after new
captures, edit the text in `make_gallery.swift` and run from the repository root:

```bash
swift macos/store-listing/producthunt/make_gallery.swift
```

To capture an editor window (Retina resolution, no system shadow), open the project in light appearance, set the
playhead and the inspector panel, then run from the repository root:

```bash
swift macos/store-listing/producthunt/capture_window.swift 1-editor "Mapleboard demo"
```

The second argument is the start of the window title, for when several editors are open. `raw/6-windows.jpg` is the
Windows editor shot the website uses. The Microsoft Store badges are the official ones from get.microsoft.com.
