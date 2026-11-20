//! Cursor kind (`c` in `cursor.jsonl`) from the cursor bitmap the portal sends.
//!
//! The ScreenCast portal gives the cursor picture, not its name. The compositor draws that picture from
//! the Xcursor theme, so the theme's own files tell which picture is which: each named cursor we care
//! about is loaded once, reduced to a 16×16 alpha mask plus its hotspot, and an incoming bitmap takes the
//! kind of the closest mask. Unknown pictures stay `arrow`. Results are cached per bitmap.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

const GRID: usize = 16;
/// Mean alpha difference (0..1) plus hotspot distance above which a bitmap is not that cursor.
const MAX_DISTANCE: f32 = 0.16;

/// Theme file names (first found wins) for each kind written to `cursor.jsonl` (spec/02 §3.1).
const KINDS: &[(&str, &[&str])] = &[
    ("arrow", &["default", "left_ptr", "arrow"]),
    ("pointingHand", &["pointer", "hand2", "hand1", "pointing_hand"]),
    ("iBeam", &["text", "xterm", "ibeam"]),
    ("crosshair", &["crosshair", "cross", "tcross"]),
    ("resizeLeftRight", &["ew-resize", "col-resize", "sb_h_double_arrow", "h_double_arrow"]),
    ("resizeUpDown", &["ns-resize", "row-resize", "sb_v_double_arrow", "v_double_arrow"]),
    ("openHand", &["grab", "openhand"]),
    ("closedHand", &["grabbing", "closedhand"]),
];

#[derive(Clone)]
struct Signature {
    mask: [f32; GRID * GRID],
    hot: (f32, f32),
}

struct Reference {
    kind: &'static str,
    /// One signature per image size in the theme file.
    sizes: Vec<(u32, Signature)>,
}

pub struct CursorClassifier {
    references: Vec<Reference>,
    cache: HashMap<u64, &'static str>,
    /// Distance of the best match of the last uncached bitmap (for `NATIVESCREEN_DEBUG`).
    pub last_distance: f32,
}

/// An RGBA-like bitmap: `alpha_index` is the byte of each 4-byte pixel that holds alpha.
pub struct Bitmap<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub alpha_index: usize,
    pub pixels: &'a [u8],
    pub hotspot: (i32, i32),
}

impl CursorClassifier {
    pub fn load() -> Self {
        let dirs = theme_dirs(&theme_name());
        let mut references = Vec::new();
        for (kind, names) in KINDS {
            let file = names.iter().find_map(|n| dirs.iter().map(|d| d.join("cursors").join(n)).find(|p| p.exists()));
            let Some(images) = file.and_then(|p| std::fs::read(p).ok()).and_then(|b| parse_xcursor(&b)) else { continue };
            let sizes = images
                .iter()
                .map(|img| {
                    let bmp = Bitmap {
                        width: img.width,
                        height: img.height,
                        stride: img.width as usize * 4,
                        alpha_index: 3,
                        pixels: &img.pixels,
                        hotspot: (img.xhot as i32, img.yhot as i32),
                    };
                    (img.height, signature(&bmp, img.width.max(img.height)))
                })
                .collect();
            references.push(Reference { kind, sizes });
        }
        Self { references, cache: HashMap::new(), last_distance: f32::NAN }
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.references.is_empty()
    }

    /// Compositors may hand over the theme image inside a larger, transparent canvas (a 48 px cursor in
    /// the top-left corner of 256×256), so the bitmap is compared through a top-left window of each theme
    /// size that can hold everything opaque in it.
    pub fn classify(&mut self, bitmap: &Bitmap) -> &'static str {
        if bitmap.width == 0 || bitmap.height == 0 {
            return "arrow";
        }
        let Some((extent, key)) = opaque_extent_and_key(bitmap) else { return "arrow" };
        if let Some(kind) = self.cache.get(&key) {
            return kind;
        }
        let mut best = ("arrow", f32::MAX);
        let mut windows: HashMap<u32, Signature> = HashMap::new();
        for reference in &self.references {
            for (size, rsig) in &reference.sizes {
                if *size < extent {
                    continue;
                }
                let sig = windows.entry(*size).or_insert_with(|| signature(bitmap, *size));
                let d = distance(sig, rsig);
                if d < best.1 {
                    best = (reference.kind, d);
                }
            }
        }
        let kind = if best.1 <= MAX_DISTANCE { best.0 } else { "arrow" };
        self.last_distance = best.1;
        self.cache.insert(key, kind);
        kind
    }
}

/// Size of the smallest top-left square that holds every visible pixel, and a hash of those pixels' alpha
/// and the hotspot (the cache key).
fn opaque_extent_and_key(b: &Bitmap) -> Option<(u32, u64)> {
    let mut extent = 0u32;
    let mut h: u64 = 0xcbf29ce484222325;
    let mut any = false;
    for y in 0..b.height as usize {
        let row = y * b.stride;
        for x in 0..b.width as usize {
            let a = *b.pixels.get(row + x * 4 + b.alpha_index)?;
            if a > 16 {
                any = true;
                extent = extent.max(x as u32 + 1).max(y as u32 + 1);
                for v in [x as u64, y as u64, a as u64] {
                    h ^= v;
                    h = h.wrapping_mul(0x100000001b3);
                }
            }
        }
    }
    for v in [b.hotspot.0 as u64, b.hotspot.1 as u64] {
        h ^= v;
        h = h.wrapping_mul(0x100000001b3);
    }
    any.then_some((extent, h))
}

/// Alpha mask on a 16×16 grid over the top-left `window`×`window` pixels (box filter; pixels outside the
/// bitmap count as transparent), and the hotspot as a fraction of the window.
fn signature(b: &Bitmap, window: u32) -> Signature {
    let n = window.max(1) as usize;
    let mut mask = [0f32; GRID * GRID];
    let mut counts = [0u32; GRID * GRID];
    for y in 0..n {
        let gy = y * GRID / n;
        for x in 0..n {
            let cell = gy * GRID + x * GRID / n;
            counts[cell] += 1;
            if x < b.width as usize && y < b.height as usize {
                if let Some(&a) = b.pixels.get(y * b.stride + x * 4 + b.alpha_index) {
                    mask[cell] += a as f32 / 255.0;
                }
            }
        }
    }
    for (m, c) in mask.iter_mut().zip(counts) {
        if c > 0 {
            *m /= c as f32;
        }
    }
    Signature { mask, hot: (b.hotspot.0 as f32 / n as f32, b.hotspot.1 as f32 / n as f32) }
}

fn distance(a: &Signature, b: &Signature) -> f32 {
    let mask: f32 = a.mask.iter().zip(&b.mask).map(|(x, y)| (x - y).abs()).sum::<f32>() / (GRID * GRID) as f32;
    let hot = ((a.hot.0 - b.hot.0).powi(2) + (a.hot.1 - b.hot.1).powi(2)).sqrt();
    mask + 0.5 * hot
}

fn theme_name() -> String {
    if let Ok(name) = std::env::var("XCURSOR_THEME") {
        if !name.is_empty() {
            return name;
        }
    }
    "default".into()
}

fn icon_roots() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let mut roots = vec![home.join(".icons")];
    let data_home = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local/share"));
    roots.push(data_home.join("icons"));
    let data_dirs = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    roots.extend(data_dirs.split(':').filter(|d| !d.is_empty()).map(|d| Path::new(d).join("icons")));
    roots.push(PathBuf::from("/usr/share/pixmaps"));
    roots
}

/// The theme's directories followed by those of the themes it inherits from, then Adwaita.
fn theme_dirs(name: &str) -> Vec<PathBuf> {
    let roots = icon_roots();
    let mut out = Vec::new();
    let mut queue = vec![name.to_string(), "Adwaita".to_string()];
    let mut seen = Vec::new();
    while let Some(theme) = queue.pop().filter(|_| seen.len() < 16) {
        if seen.contains(&theme) {
            continue;
        }
        seen.push(theme.clone());
        let mut inherits = Vec::new();
        for root in &roots {
            let dir = root.join(&theme);
            if dir.join("cursors").is_dir() {
                out.push(dir.clone());
            }
            if let Ok(index) = std::fs::read_to_string(dir.join("index.theme")) {
                for line in index.lines() {
                    if let Some(v) = line.trim().strip_prefix("Inherits=") {
                        inherits.extend(v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()));
                    }
                }
            }
        }
        // Inherited themes are searched before the Adwaita fallback.
        for t in inherits.into_iter().rev() {
            queue.push(t);
        }
    }
    out
}

struct XcursorImage {
    width: u32,
    height: u32,
    xhot: u32,
    yhot: u32,
    /// ARGB as little-endian u32: bytes B, G, R, A.
    pixels: Vec<u8>,
}

/// Xcursor file: "Xcur", header size, version, toc count, then (type, subtype, position) entries.
/// Image chunks (type 0xfffd0002) hold width, height, xhot, yhot, delay and ARGB pixels.
fn parse_xcursor(b: &[u8]) -> Option<Vec<XcursorImage>> {
    let u32_at = |o: usize| -> Option<u32> { Some(u32::from_le_bytes(b.get(o..o + 4)?.try_into().ok()?)) };
    if b.get(0..4)? != b"Xcur" {
        return None;
    }
    let ntoc = u32_at(12)? as usize;
    let mut images: Vec<XcursorImage> = Vec::new();
    for i in 0..ntoc.min(64) {
        let entry = 16 + i * 12;
        if u32_at(entry)? != 0xfffd0002 {
            continue;
        }
        let pos = u32_at(entry + 8)? as usize;
        let (width, height) = (u32_at(pos + 16)?, u32_at(pos + 20)?);
        if width == 0 || height == 0 || width > 1024 || height > 1024 {
            continue;
        }
        // Animated cursors repeat a size: keep the first frame of each.
        if images.iter().any(|im| im.width == width && im.height == height) {
            continue;
        }
        let start = pos + 36;
        let pixels = b.get(start..start + (width * height * 4) as usize)?.to_vec();
        images.push(XcursorImage { width, height, xhot: u32_at(pos + 24)?, yhot: u32_at(pos + 28)?, pixels });
    }
    (!images.is_empty()).then_some(images)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every theme cursor, fed back at every size the theme ships, comes out as its own kind.
    #[test]
    fn recognizes_theme_cursors() {
        let mut classifier = CursorClassifier::load();
        if classifier.is_empty() {
            eprintln!("no cursor theme installed; skipped");
            return;
        }
        let dirs = theme_dirs(&theme_name());
        for (kind, names) in KINDS {
            let Some(path) = names.iter().find_map(|n| dirs.iter().map(|d| d.join("cursors").join(n)).find(|p| p.exists())) else {
                continue;
            };
            let images = parse_xcursor(&std::fs::read(&path).unwrap()).unwrap();
            for img in &images {
                let bmp = Bitmap {
                    width: img.width,
                    height: img.height,
                    stride: img.width as usize * 4,
                    alpha_index: 3,
                    pixels: &img.pixels,
                    hotspot: (img.xhot as i32, img.yhot as i32),
                };
                assert_eq!(classifier.classify(&bmp), *kind, "{} at {}px", path.display(), img.height);

                // The same picture in the top-left corner of a transparent 256×256 canvas.
                let mut canvas = vec![0u8; 256 * 256 * 4];
                for y in 0..img.height as usize {
                    let src = &img.pixels[y * img.width as usize * 4..(y + 1) * img.width as usize * 4];
                    canvas[y * 256 * 4..y * 256 * 4 + src.len()].copy_from_slice(src);
                }
                let padded = Bitmap { width: 256, height: 256, stride: 256 * 4, alpha_index: 3, pixels: &canvas, hotspot: bmp.hotspot };
                assert_eq!(classifier.classify(&padded), *kind, "{} at {}px in 256 canvas", path.display(), img.height);
            }
        }
    }
}
