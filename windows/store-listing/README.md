# Microsoft Store listing

What Partner Center shows on the Store page, for the 15 UI languages: `listing.csv` (text, screenshot captions, search
terms and the paths of the images), `screenshots/<language>/` (4 PNGs per language, 3050 × 1829, taken from the Windows
app running in that language: an annotation, the camera with a new background and a sticker, the light theme, Export) and `logos/` (9:16 poster 1440 × 2160 and 1:1 box art 2160 × 2160, shared by every
language). See `docs/releasing.md`, "Store listing", for how to import it and how it was made.

**Every image path in `listing.csv` starts with the folder name, `store-listing/`.** Partner Center's **Upload folder**
sends each file as `<folder you picked>/<path inside it>` and matches that string exactly. A path without the folder
name matches nothing, and the import fails with only "We couldn't process this .csv file", no details. So upload this
folder under this name, or change every path in the CSV when you rename it.
