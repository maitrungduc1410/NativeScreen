# Mac App Store listing

`screenshots/en-us/`: the 5 screenshots App Store Connect shows (2880 × 1800 PNG, no alpha, the largest Mac size).
Only English for now; a language with no screenshots of its own uses these.

They are built from the app shots and the demo video the website uses (`site/public/assets/`), with a title and a
line of text above each. To change the text or rebuild them after new shots, edit `make_screenshots.swift` and run it
from the repository root:

```bash
swift macos/store-listing/make_screenshots.swift
```

If the interpreter crashes, compile it first: `swiftc -O macos/store-listing/make_screenshots.swift -o /tmp/mkshots && /tmp/mkshots`.

Upload them in App Store Connect > the macOS version > App Previews and Screenshots (drag the five files in, in order).
The listing text is in App Store Connect only; see `docs/releasing.md`, "Mac App Store".
