// Builds the Product Hunt gallery (2540 × 1520, twice the 1270 × 760 Product Hunt recommends) from editor window
// captures in raw/. Run from the repository root: swift macos/store-listing/producthunt/make_gallery.swift
// A slide whose capture is missing is skipped. RAW_DIR overrides where the captures are read from.
import AppKit

let width = 2540, height = 1520
let base = "macos/store-listing/producthunt"
let raw = ProcessInfo.processInfo.environment["RAW_DIR"] ?? "\(base)/raw"
let out = "\(base)/out"

struct Slide {
    let file: String
    let capture: String
    let title: String
    let subtitle: String
    var storeBadge = false
}

let slides = [
    Slide(file: "1-editor.png", capture: "1-editor.png",
          title: "Record once. Get a finished demo.",
          subtitle: "Zooms follow your clicks, with captions and shortcut keys on their own tracks."),
    Slide(file: "2-annotations.png", capture: "2-annotations.png",
          title: "Point, number and explain each step",
          subtitle: "Arrows, steps, shapes and text that draw themselves in, on as many layers as you need."),
    Slide(file: "3-masks.png", capture: "3-masks.png",
          title: "Blur two things at once",
          subtitle: "Stack blur and spotlight masks. Emails, keys and faces are found for you."),
    Slide(file: "4-camera.png", capture: "4-camera.png",
          title: "Just you, on any background",
          subtitle: "Camera-only videos with background removal and stickers, kept centered on your face."),
    Slide(file: "5-transcript.png", capture: "5-transcript.png",
          title: "Edit the video by editing the words",
          subtitle: "Captions are made on your computer. Delete a sentence to cut it."),
    Slide(file: "6-windows.png", capture: "6-windows.jpg",
          title: "Also on Windows",
          subtitle: "Native on Windows 10 and 11, free on the Microsoft Store.",
          storeBadge: true),
]

let paper = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF3 / 255.0, blue: 0xEE / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x17 / 255.0, green: 0x16 / 255.0, blue: 0x14 / 255.0, alpha: 1)
let ink2 = NSColor(srgbRed: 0x4A / 255.0, green: 0x47 / 255.0, blue: 0x41 / 255.0, alpha: 1)

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
    return NSFont(descriptor: descriptor, size: size) ?? font
}

func drawCentered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let box = attributed.boundingRect(with: NSSize(width: CGFloat(width) - 200, height: 400), options: [.usesLineFragmentOrigin])
    // AppKit draws bottom-up: convert the top edge.
    let rect = NSRect(x: 100, y: CGFloat(height) - top - box.height, width: CGFloat(width) - 200, height: box.height)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
    return top + box.height
}

let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)

for slide in slides {
    let path = "\(raw)/\(slide.capture)"
    guard fm.fileExists(atPath: path) else { print("skip \(slide.file): no \(path)"); continue }
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Cannot read \(path)") }

    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    var y = drawCentered(slide.title, font: serif(88, .semibold), color: ink, top: 96)
    y = drawCentered(slide.subtitle, font: .systemFont(ofSize: 40, weight: .regular), color: ink2, top: y + 22)

    if slide.storeBadge, let badge = NSImage(contentsOfFile: "\(base)/ms-store-badge-dark.svg") {
        let bh: CGFloat = 88
        let bw = bh * badge.size.width / badge.size.height
        let top = y + 32
        badge.draw(in: NSRect(x: (CGFloat(width) - bw) / 2, y: CGFloat(height) - top - bh, width: bw, height: bh))
        y = top + bh
    }

    // The capture fills the space under the text, keeping its aspect ratio.
    let areaTop = y + 64
    let areaBottom: CGFloat = 80
    let maxW = CGFloat(width) - 240
    let maxH = CGFloat(height) - areaTop - areaBottom
    let aspect = CGFloat(cg.width) / CGFloat(cg.height)
    var w = maxW, h = maxW / aspect
    if h > maxH { h = maxH; w = h * aspect }
    let x = (CGFloat(width) - w) / 2
    let shotTop = areaTop + (maxH - h) / 2
    let rect = NSRect(x: x, y: CGFloat(height) - shotTop - h, width: w, height: h)

    // Window captures keep their own rounded corners; this radius only trims the shadow shape to match.
    let radius: CGFloat = 20
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 56
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.set()
    paper.setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(cg, in: rect)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(out)/\(slide.file)"))
    print("wrote \(out)/\(slide.file)")
}
