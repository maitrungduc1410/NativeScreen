# Mac App Store listing

`screenshots/<locale>/`: the 9 screenshots App Store Connect shows for each language (2880 × 1800 PNG, no alpha, the
largest Mac size). The folder names match the files in `text/`.

They are built from the app shots and the demo videos the website uses (`site/public/assets/`), with a title and a
line of text above each: the editor, zooms, annotations, drawing while recording, shortcut keycaps, the camera, the
transcript editor, the timeline and privacy. The titles for every language are in `screenshot-text.json`, one
`[title, subtitle]` pair per screenshot in order. To change a picture or its frame, edit `slides` in
`make_screenshots.swift`; then rebuild from the repository root (add language codes to build only those):

```bash
swiftc -O macos/store-listing/make_screenshots.swift -o /tmp/mkshots && /tmp/mkshots
```

Upload them in App Store Connect > the macOS version > App Previews and Screenshots: pick the language, then drag the
nine files in, in order (replace the old English ones).

## Listing text

`text/<locale>.md` holds the store text for every language the app ships in, one file per App Store Connect
localization (the file name is the locale to pick, for example `de-DE` is "German"). Each file has the Subtitle,
Promotional Text, Keywords and Description in the order App Store Connect shows them. The app name stays
"Native Screen" everywhere. English (`en-US.md`) is the source; translations follow it, and the keywords are chosen
for each language rather than translated word by word.

Check the limits (Subtitle 30, Promotional Text 170, Description 4000 characters, Keywords 100 bytes) before pasting:

```bash
python3 macos/store-listing/check_text.py
```

In App Store Connect, add a language with the language menu at the top right of App Information (Subtitle, and the
Privacy Policy URL `https://nativescreen.app/<lang>/privacy/`), then fill Promotional Text, Description and Keywords on
the version page. Changing the Description or Keywords needs a new version in review; Promotional Text can change at
any time. See also `docs/releasing.md`, "Mac App Store".
