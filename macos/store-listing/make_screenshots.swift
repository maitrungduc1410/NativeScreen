// Builds the Mac App Store screenshots (2880 × 1800, no alpha) from the app shots the website uses.
// Run from the repository root: swift macos/store-listing/make_screenshots.swift
import AppKit
import AVFoundation

let width = 2880, height = 1800
let shots = "site/public/assets"
let out = "macos/store-listing/screenshots/en-us"

struct Slide {
    let file: String
    let image: String
    /// For a video, the time of the frame to use.
    var seconds: Double? = nil
    let title: String
    let subtitle: String
}

let slides = [
    Slide(file: "1-editor.png", image: "\(shots)/shots/editor-dark.jpg",
          title: "Record once. Get a finished demo.",
          subtitle: "Automatic zooms, a gliding cursor, captions and backgrounds."),
    Slide(file: "2-transcript.png", image: "\(shots)/shots/transcript.jpg",
          title: "Edit the video by editing the words",
          subtitle: "Captions are made on your Mac. Delete a sentence to cut it."),
    Slide(file: "3-timeline.png", image: "\(shots)/shots/timeline.jpg",
          title: "As many tracks as the story needs",
          subtitle: "Zooms, masks, captions and shortcuts, each on its own lane."),
    Slide(file: "4-light.png", image: "\(shots)/shots/editor-light.jpg",
          title: "Private by design",
          subtitle: "Recording, captions and export all run on your Mac. No account."),
    Slide(file: "5-result.png", image: "\(shots)/demos/hero.mp4", seconds: 8,
          title: "Zooms that follow your clicks",
          subtitle: "Export as MP4, ProRes or GIF, in wide, square or vertical."),
]

let paper = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF3 / 255.0, blue: 0xEE / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x17 / 255.0, green: 0x16 / 255.0, blue: 0x14 / 255.0, alpha: 1)
let ink2 = NSColor(srgbRed: 0x4A / 255.0, green: 0x47 / 255.0, blue: 0x41 / 255.0, alpha: 1)

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func drawCentered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let box = attributed.boundingRect(with: NSSize(width: CGFloat(width) - 240, height: 400), options: [.usesLineFragmentOrigin])
    // AppKit draws bottom-up: convert the top edge.
    let rect = NSRect(x: 120, y: CGFloat(height) - top - box.height, width: CGFloat(width) - 240, height: box.height)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
    return top + box.height
}

for slide in slides {
    let cg: CGImage
    if let seconds = slide.seconds {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: slide.image)))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        cg = try! generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    } else if let image = NSImage(contentsOfFile: slide.image),
              let still = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        cg = still
    } else {
        fatalError("Cannot read \(slide.image)")
    }
    // No alpha channel: the store rejects screenshots with one.
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    var y = drawCentered(slide.title, font: serif(104, .semibold), color: ink, top: 130)
    y = drawCentered(slide.subtitle, font: .systemFont(ofSize: 50, weight: .regular), color: ink2, top: y + 28)

    // The shot fills the space under the text, keeping its aspect ratio.
    let areaTop = y + 90
    let areaBottom: CGFloat = 110
    let maxW = CGFloat(width) - 320
    let maxH = CGFloat(height) - areaTop - areaBottom
    let aspect = CGFloat(cg.width) / CGFloat(cg.height)
    var w = maxW, h = maxW / aspect
    if h > maxH { h = maxH; w = h * aspect }
    let x = (CGFloat(width) - w) / 2
    let shotTop = areaTop + (maxH - h) / 2
    let rect = NSRect(x: x, y: CGFloat(height) - shotTop - h, width: w, height: h)

    let radius: CGFloat = 26
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 60
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    ink.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
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
