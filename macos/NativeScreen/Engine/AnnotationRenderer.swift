import AppKit
import CoreImage

/// Draws annotations for the compositor, and measures them for the canvas handles. Both read the same numbers, so a
/// handle always sits on what is drawn. Everything is drawn at output resolution: text and lines stay sharp at 4K and
/// under any zoom, because the zoom moves an annotation without enlarging a raster of it.
@MainActor
final class AnnotationRenderer {

    // MARK: Text layout

    struct TextLayout: Equatable {
        /// The box, padding included, in pixels of the frame it was measured for.
        let boxSize: CGSize
        let fontSize: CGFloat
        let padding: CGSize
        let cornerRadius: CGFloat
    }

    static func font(for item: AnnotationItem, size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: item.bold ? .bold : .medium)
    }

    /// `visibleCharacters` hides the rest in clear ink, so typing on keeps the final layout instead of reflowing.
    private static func attributedText(for item: AnnotationItem, fontSize: CGFloat, visibleCharacters: Int? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = item.text.isEmpty ? " " : item.text
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font(for: item, size: fontSize),
            .foregroundColor: NSColor(hexString: item.color),
            .paragraphStyle: paragraph
        ])
        if let visible = visibleCharacters {
            let characters = Array(text)
            let shown = String(characters.prefix(max(0, visible))).utf16.count
            let hidden = NSRange(location: shown, length: (text as NSString).length - shown)
            if hidden.length > 0 {
                attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: hidden)
            }
        }
        return attributed
    }

    static func fontSize(for item: AnnotationItem, canvasSize: CGSize) -> CGFloat {
        max(4.0, CGFloat(item.fontSizeRatio) * max(1.0, min(canvasSize.width, canvasSize.height)))
    }

    /// The text box for a frame of `canvasSize`. Font size and wrap width are shares of that frame.
    static func textLayout(for item: AnnotationItem, canvasSize: CGSize) -> TextLayout {
        let fontSize = fontSize(for: item, canvasSize: canvasSize)
        let hasPlate = item.textBackground == .solid
        let padding = hasPlate
            ? CGSize(width: fontSize * 0.55, height: fontSize * 0.32)
            : CGSize(width: fontSize * 0.12, height: fontSize * 0.06)
        let wrapWidth = max(fontSize * 2.0, CGFloat(item.maxWidthRatio) * canvasSize.width - padding.width * 2.0)
        let bounds = attributedText(for: item, fontSize: fontSize).boundingRect(
            with: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return TextLayout(
            boxSize: CGSize(
                width: ceil(bounds.width + padding.width * 2.0),
                height: ceil(bounds.height + padding.height * 2.0)
            ),
            fontSize: fontSize,
            padding: padding,
            cornerRadius: hasPlate ? fontSize * 0.42 : 0.0
        )
    }

    /// Diameter of a step badge.
    static func stepDiameter(for item: AnnotationItem, canvasSize: CGSize) -> CGFloat {
        (fontSize(for: item, canvasSize: canvasSize) * 1.75).rounded()
    }

    /// Size of the box the canvas handles draw around a text, step or image, before rotation.
    static func boxSize(for item: AnnotationItem, canvasSize: CGSize, packageURL: URL?) -> CGSize {
        switch item.kind {
        case .step:
            let d = stepDiameter(for: item, canvasSize: canvasSize)
            return CGSize(width: d, height: d)
        case .image:
            return imageSize(for: item, canvasSize: canvasSize, packageURL: packageURL)
        default:
            return textLayout(for: item, canvasSize: canvasSize).boxSize
        }
    }

    // MARK: Images

    private static var decodedImages: [URL: CGImage] = [:]

    static func cgImage(for item: AnnotationItem, packageURL: URL?) -> CGImage? {
        guard let packageURL, !item.imagePath.isEmpty else { return nil }
        let url = packageURL.appendingPathComponent(item.imagePath)
        if let hit = decodedImages[url] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // The thumbnail call applies the EXIF orientation; 4096 px is more than any frame needs.
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { return nil }
        if decodedImages.count > 32 { decodedImages.removeAll() }
        decodedImages[url] = image
        return image
    }

    /// `maxWidthRatio` of the frame wide, at the picture's own aspect. A missing file shows as a 16:9 placeholder.
    static func imageSize(for item: AnnotationItem, canvasSize: CGSize, packageURL: URL?) -> CGSize {
        let width = max(8.0, CGFloat(item.maxWidthRatio) * canvasSize.width).rounded()
        guard let image = cgImage(for: item, packageURL: packageURL), image.width > 0 else {
            return CGSize(width: width, height: (width * 9 / 16).rounded())
        }
        return CGSize(width: width, height: (width * CGFloat(image.height) / CGFloat(image.width)).rounded())
    }

    // MARK: Arrow geometry

    struct ArrowGeometry {
        let tail: CGPoint
        let control: CGPoint
        let shaftEnd: CGPoint
        let head: CGPoint
        let headBaseLeft: CGPoint
        let headBaseRight: CGPoint
    }

    /// Geometry of a curved arrow between two points. `yUp` says which way the coordinate space points, so "left of
    /// the direction of travel" is the same side on screen in the compositor (y up) and in the canvas handles (y down).
    static func arrowGeometry(tail: CGPoint, head: CGPoint, bend: Double, strokeWidth: CGFloat, yUp: Bool) -> ArrowGeometry {
        let dx = head.x - tail.x
        let dy = head.y - tail.y
        let length = max(0.001, hypot(dx, dy))
        let normal = yUp
            ? CGPoint(x: -dy / length, y: dx / length)
            : CGPoint(x: dy / length, y: -dx / length)
        let offset = CGFloat(bend) * length
        let control = CGPoint(
            x: (tail.x + head.x) * 0.5 + normal.x * offset,
            y: (tail.y + head.y) * 0.5 + normal.y * offset
        )

        // A quadratic curve ends along control -> head.
        let tx = head.x - control.x
        let ty = head.y - control.y
        let tLength = max(0.001, hypot(tx, ty))
        let dir = CGPoint(x: tx / tLength, y: ty / tLength)
        let headLength = min(length * 0.45, max(strokeWidth * 3.6, 6.0))
        let headHalfWidth = headLength * 0.62
        let base = CGPoint(x: head.x - dir.x * headLength, y: head.y - dir.y * headLength)
        let side = CGPoint(x: -dir.y, y: dir.x)
        return ArrowGeometry(
            tail: tail,
            control: control,
            shaftEnd: CGPoint(x: head.x - dir.x * headLength * 0.6, y: head.y - dir.y * headLength * 0.6),
            head: head,
            headBaseLeft: CGPoint(x: base.x + side.x * headHalfWidth, y: base.y + side.y * headHalfWidth),
            headBaseRight: CGPoint(x: base.x - side.x * headHalfWidth, y: base.y - side.y * headHalfWidth)
        )
    }

    static func strokeWidth(for item: AnnotationItem, canvasSize: CGSize) -> CGFloat {
        max(1.0, CGFloat(item.strokeRatio) * min(canvasSize.width, canvasSize.height))
    }

    /// Half the width and height of a shape in pixels, from where `point` puts its center and two edge midpoints.
    static func shapeHalfSize(for item: AnnotationItem, point: (Point01) -> CGPoint) -> CGSize {
        let c = point(item.position01)
        let right = point(Point01(x: item.position01.x + item.size01.width * 0.5, y: item.position01.y))
        let down = point(Point01(x: item.position01.x, y: item.position01.y + item.size01.height * 0.5))
        return CGSize(width: hypot(right.x - c.x, right.y - c.y), height: hypot(down.x - c.x, down.y - c.y))
    }

    // MARK: Pen strokes

    static func drawSteps(for item: AnnotationItem) -> Double {
        guard item.kind == .pen, let drawnMs = item.pointTimesMs.last else { return 120 }
        return max(120, (drawnMs / 16).rounded(.up))
    }

    static func penHash(_ item: AnnotationItem) -> Int {
        var h = Hasher()
        h.combine(item.highlighter)
        h.combine(item.strokeStarts)
        for p in item.points01 { h.combine(p.x); h.combine(p.y) }
        return h.finalize()
    }

    /// The stroke in the item's local frame (center at the origin, y up, `halfSize` to the box edges), up to `progress`
    /// of its drawing time (of its points when it has no times). Corners are rounded through the midpoints.
    static func penPath(for item: AnnotationItem, halfSize h: CGSize, progress: Double) -> CGPath {
        let local = item.points01.map { CGPoint(x: -h.width + CGFloat($0.x) * 2 * h.width, y: h.height - CGFloat($0.y) * 2 * h.height) }
        let starts = Set(item.strokeStarts)
        var count = local.count
        var tail: CGPoint?
        if progress < 0.999, local.count > 1 {
            let times = item.pointTimesMs.count == local.count ? item.pointTimesMs : local.indices.map(Double.init)
            let cutoff = (times.last ?? 0) * progress
            let next = times.firstIndex { $0 > cutoff } ?? local.count
            count = max(1, next)
            // Part of the segment being drawn, unless the pen was up before the next point.
            if next > 0, next < local.count, !starts.contains(next) {
                let t0 = times[next - 1], t1 = times[next]
                let f = CGFloat((cutoff - t0) / max(0.001, t1 - t0))
                let p0 = local[next - 1], p1 = local[next]
                tail = CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)
            }
        }
        let path = CGMutablePath()
        var strokeStart = 0
        for i in 0..<count where i == count - 1 || starts.contains(i + 1) {
            var points = Array(local[strokeStart...i])
            if i == count - 1, let tail { points.append(tail) }
            addStroke(points, to: path)
            strokeStart = i + 1
        }
        return path
    }

    /// One pen stroke: through the midpoints of its points, with the points as controls.
    private static func addStroke(_ points: [CGPoint], to path: CGMutablePath) {
        guard let first = points.first else { return }
        path.move(to: first)
        if points.count == 1 {
            // A dot.
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) * 0.5, y: (points[i].y + points[i + 1].y) * 0.5)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
    }

    // MARK: Compositing

    private struct TextKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let maxWidthRatio: Double
        let canvasWidth: CGFloat
        let bold: Bool
        let color: String
        let background: AnnotationTextBackground
        let backgroundColor: String
        let visibleCharacters: Int?
    }

    private struct ImageKey: Hashable {
        let path: String
        let size: CGSize
        let corner: CGFloat
    }

    private struct StepKey: Hashable {
        let number: Int
        let diameter: CGFloat
        let color: String
    }

    private struct LineKey: Hashable {
        let kind: AnnotationKind
        let a: CGPoint
        let b: CGPoint
        let bend: Double
        let rotation: Double
        let stroke: CGFloat
        let color: String
        let fill: Double
        let corner: CGFloat
        let progress: Int
        let clip: CGRect
        /// A pen stroke's points and style (0 for other kinds).
        let stroke2: Int
    }

    private var textCache: [TextKey: (image: CIImage, boxOrigin: CGPoint)] = [:]
    private var stepCache: [StepKey: (image: CIImage, boxOrigin: CGPoint)] = [:]
    private var imageCache: [ImageKey: (image: CIImage, boxOrigin: CGPoint)] = [:]
    private var lineCache: [LineKey: CIImage] = [:]

    /// Composites `items` (bottom layer first) over `background`. `point` maps an item's normalized point to compositor
    /// pixels (y up).
    func composite(
        _ items: [AnnotationItem],
        over background: CIImage,
        sourceTimeMs: Double,
        canvasRect: CGRect,
        stepNumbers: [String: Int],
        packageURL: URL?,
        point: (AnnotationItem, Point01) -> CGPoint
    ) -> CIImage {
        guard !items.isEmpty else { return background }
        let shortSide = min(canvasRect.width, canvasRect.height)
        var result = background
        for item in items {
            let state = item.animationState(atSourceMs: sourceTimeMs)
            guard state.opacity > 0.003, state.drawProgress > 0.001 else { continue }
            // Down in the frame is minus y here.
            let lift = CGFloat(-state.offsetY) * shortSide
            let shift = CGFloat(state.offsetX) * shortSide
            let scale = CGFloat(state.scale)
            let angle = -CGFloat(item.rotationDegrees) * .pi / 180.0
            let image: CIImage?
            switch item.kind {
            case .text, .step, .image:
                let center = point(item, item.position01)
                let placed: CIImage?
                switch item.kind {
                case .text:
                    let count = Array(item.text).count
                    let visible = state.reveal < 0.999 ? Int((Double(count) * state.reveal).rounded(.up)) : nil
                    guard visible != 0 else { continue }
                    placed = textImage(for: item, canvasRect: canvasRect, center: center, visibleCharacters: visible)
                case .step:
                    placed = stepImage(for: item, number: stepNumbers[item.id] ?? 1, canvasRect: canvasRect, center: center)
                default:
                    placed = pictureImage(for: item, canvasRect: canvasRect, center: center, packageURL: packageURL)
                }
                image = placed?.transformed(by: Self.about(center, rotate: angle, scale: scale, lift: lift, shift: shift))
            case .arrow:
                let tail = point(item, item.from01)
                let head = point(item, item.to01)
                let mid = CGPoint(x: (tail.x + head.x) * 0.5, y: (tail.y + head.y) * 0.5)
                let move = Self.about(mid, rotate: 0, scale: scale, lift: lift, shift: shift)
                image = lineImage(
                    for: item,
                    canvasRect: canvasRect,
                    a: tail.applying(move),
                    b: head.applying(move),
                    rotation: 0,
                    strokeScale: scale,
                    progress: state.drawProgress
                )
            case .rectangle, .ellipse, .pen:
                let center = point(item, item.position01)
                let half = Self.shapeHalfSize(for: item) { point(item, $0) }
                image = lineImage(
                    for: item,
                    canvasRect: canvasRect,
                    a: CGPoint(x: center.x + shift, y: center.y + lift),
                    b: CGPoint(x: half.width * scale, y: half.height * scale),
                    rotation: angle,
                    strokeScale: scale,
                    progress: state.drawProgress
                )
            }
            guard var placed = image else { continue }
            if state.opacity < 0.997 {
                // CIColorMatrix works on unpremultiplied color, so scaling alpha alone fades the image. Scaling the
                // color channels too would darken it instead.
                placed = placed.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(state.opacity))
                ])
            }
            result = placed.composited(over: result)
        }
        return result
    }

    /// Rotation and scale about `center`, then a move.
    private static func about(_ center: CGPoint, rotate angle: CGFloat, scale: CGFloat, lift: CGFloat, shift: CGFloat) -> CGAffineTransform {
        guard abs(angle) > 0.0001 || abs(scale - 1) > 0.0001 || abs(lift) > 0.01 || abs(shift) > 0.01 else { return .identity }
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x + shift, y: center.y + lift))
    }

    // MARK: Text and steps

    private func textImage(for item: AnnotationItem, canvasRect: CGRect, center: CGPoint, visibleCharacters: Int?) -> CIImage? {
        let layout = Self.textLayout(for: item, canvasSize: canvasRect.size)
        let key = TextKey(
            text: item.text,
            fontSize: layout.fontSize,
            maxWidthRatio: item.maxWidthRatio,
            canvasWidth: canvasRect.width,
            bold: item.bold,
            color: item.color,
            background: item.textBackground,
            backgroundColor: item.backgroundColor,
            visibleCharacters: visibleCharacters
        )
        let rendered: (image: CIImage, boxOrigin: CGPoint)
        if let hit = textCache[key] {
            rendered = hit
        } else {
            guard let made = Self.drawText(item: item, layout: layout, visibleCharacters: visibleCharacters) else { return nil }
            if textCache.count > 128 { textCache.removeAll() }
            textCache[key] = made
            rendered = made
        }
        return Self.centered(rendered, size: layout.boxSize, at: center)
    }

    private static func centered(_ rendered: (image: CIImage, boxOrigin: CGPoint), size: CGSize, at center: CGPoint) -> CIImage {
        let minX = (center.x - size.width * 0.5).rounded()
        let minY = (center.y - size.height * 0.5).rounded()
        return rendered.image.transformed(by: CGAffineTransform(
            translationX: minX - rendered.boxOrigin.x,
            y: minY - rendered.boxOrigin.y
        ))
    }

    private static func drawText(item: AnnotationItem, layout: TextLayout, visibleCharacters: Int?) -> (image: CIImage, boxOrigin: CGPoint)? {
        // Room around the box for its shadow.
        let margin = ceil(layout.fontSize * 0.5)
        let width = Int(layout.boxSize.width + margin * 2.0)
        let height = Int(layout.boxSize.height + margin * 2.0)
        guard width > 0, height > 0, let ctx = makeContext(width: width, height: height) else { return nil }

        let box = CGRect(x: margin, y: margin, width: layout.boxSize.width, height: layout.boxSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(item.textBackground == .solid ? 0.30 : 0.55)
        shadow.shadowBlurRadius = layout.fontSize * (item.textBackground == .solid ? 0.30 : 0.18)
        shadow.shadowOffset = CGSize(width: 0, height: -layout.fontSize * 0.05)

        if item.textBackground == .solid {
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor(hexString: item.backgroundColor).setFill()
            NSBezierPath(roundedRect: box, xRadius: layout.cornerRadius, yRadius: layout.cornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            shadow.set()
        }
        attributedText(for: item, fontSize: layout.fontSize, visibleCharacters: visibleCharacters).draw(
            with: box.insetBy(dx: layout.padding.width, dy: layout.padding.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), CGPoint(x: margin, y: margin))
    }

    /// The picture scaled to its box with high quality resampling, rounded corners and a soft shadow.
    private func pictureImage(for item: AnnotationItem, canvasRect: CGRect, center: CGPoint, packageURL: URL?) -> CIImage? {
        let size = Self.imageSize(for: item, canvasSize: canvasRect.size, packageURL: packageURL)
        let corner = min(size.width, size.height) * 0.5 > 0
            ? min(CGFloat(item.cornerRatio) * min(canvasRect.width, canvasRect.height), min(size.width, size.height) * 0.5)
            : 0
        let key = ImageKey(path: item.imagePath, size: size, corner: corner)
        if let hit = imageCache[key] { return Self.centered(hit, size: size, at: center) }

        let margin = ceil(max(size.width, size.height) * 0.06)
        guard let ctx = Self.makeContext(width: Int(size.width + margin * 2), height: Int(size.height + margin * 2)) else { return nil }
        let box = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let path = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        // The shadow comes from the clipped picture's own alpha (one transparency layer), so a logo with transparent
        // corners casts the shape of the logo, not of its box.
        ctx.setShadow(offset: CGSize(width: 0, height: -margin * 0.15), blur: margin * 0.6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        if let picture = Self.cgImage(for: item, packageURL: packageURL) {
            ctx.draw(picture, in: box)
        } else {
            ctx.setFillColor(NSColor(white: 0.3, alpha: 1).cgColor)
            ctx.fill(box)
        }
        ctx.endTransparencyLayer()
        guard let cg = ctx.makeImage() else { return nil }
        let rendered = (CIImage(cgImage: cg), CGPoint(x: margin, y: margin))
        if imageCache.count > 32 { imageCache.removeAll() }
        imageCache[key] = rendered
        return Self.centered(rendered, size: size, at: center)
    }

    /// Black or white, whichever reads better on `hex`.
    static func contrastingTextColor(on hex: String) -> NSColor {
        let c = NSColor(hexString: hex)
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.62 ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1) : .white
    }

    private func stepImage(for item: AnnotationItem, number: Int, canvasRect: CGRect, center: CGPoint) -> CIImage? {
        let diameter = Self.stepDiameter(for: item, canvasSize: canvasRect.size)
        let key = StepKey(number: number, diameter: diameter, color: item.color)
        let rendered: (image: CIImage, boxOrigin: CGPoint)
        if let hit = stepCache[key] {
            rendered = hit
        } else {
            let margin = ceil(diameter * 0.35)
            let side = Int(diameter + margin * 2.0)
            guard let ctx = Self.makeContext(width: side, height: side) else { return nil }
            let circle = CGRect(x: margin, y: margin, width: diameter, height: diameter)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -diameter * 0.04), blur: diameter * 0.18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(NSColor(hexString: item.color).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.restoreGState()
            // A thin white ring keeps the badge visible on a background of its own color.
            let ring = diameter * 0.065
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(ring)
            ctx.strokeEllipse(in: circle.insetBy(dx: ring * 0.5, dy: ring * 0.5))

            var font = NSFont.systemFont(ofSize: diameter * (number >= 10 ? 0.46 : 0.56), weight: .bold)
            if let rounded = font.fontDescriptor.withDesign(.rounded), let roundedFont = NSFont(descriptor: rounded, size: font.pointSize) {
                font = roundedFont
            }
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: font,
                .foregroundColor: Self.contrastingTextColor(on: item.color)
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: circle.midX - size.width * 0.5, y: circle.midY - size.height * 0.5))
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage() else { return nil }
            rendered = (CIImage(cgImage: cg), CGPoint(x: margin, y: margin))
            if stepCache.count > 64 { stepCache.removeAll() }
            stepCache[key] = rendered
        }
        return Self.centered(rendered, size: CGSize(width: diameter, height: diameter), at: center)
    }

    // MARK: Arrows and shapes

    /// An arrow from `a` to `b`, or a shape centered on `a` with half size `b` turned by `rotation`. Only the part
    /// within the frame is drawn, because a zoom can push the geometry thousands of pixels away.
    private func lineImage(
        for item: AnnotationItem,
        canvasRect: CGRect,
        a: CGPoint,
        b: CGPoint,
        rotation: CGFloat,
        strokeScale: CGFloat,
        progress: Double
    ) -> CIImage? {
        let stroke = Self.strokeWidth(for: item, canvasSize: canvasRect.size) * max(0.2, strokeScale)
        let margin = stroke * 4.0
        let shortSide = min(canvasRect.width, canvasRect.height)
        let corner = CGFloat(item.cornerRatio) * shortSide

        let bounds: CGRect
        var arrow: ArrowGeometry?
        if item.kind == .arrow {
            let geometry = Self.arrowGeometry(tail: a, head: b, bend: item.bend, strokeWidth: stroke, yUp: true)
            arrow = geometry
            let points = [geometry.tail, geometry.control, geometry.head, geometry.headBaseLeft, geometry.headBaseRight]
            bounds = Self.boundingRect(points)
        } else {
            let corners = [CGPoint(x: -b.x, y: -b.y), CGPoint(x: b.x, y: -b.y), CGPoint(x: b.x, y: b.y), CGPoint(x: -b.x, y: b.y)]
            let turn = CGAffineTransform(rotationAngle: rotation)
            bounds = Self.boundingRect(corners.map { CGPoint(x: a.x + $0.applying(turn).x, y: a.y + $0.applying(turn).y) })
        }
        let clip = bounds.insetBy(dx: -margin, dy: -margin)
            .intersection(canvasRect.insetBy(dx: -margin, dy: -margin))
            .integral
        guard !clip.isEmpty, clip.width >= 1, clip.height >= 1 else { return nil }

        func q(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x * 4).rounded() / 4, y: (p.y * 4).rounded() / 4) }
        let key = LineKey(
            kind: item.kind,
            a: q(a),
            b: q(b),
            bend: item.bend,
            rotation: Double(rotation),
            stroke: stroke,
            color: item.color,
            fill: item.fillOpacity,
            corner: corner,
            // Lines re-rasterize in 120 steps of their draw-on; a drawn pen stroke replays its own timing, so it gets a
            // step every 16 ms of drawing time (one per frame at 60 fps) when that is finer.
            progress: Int((progress * Self.drawSteps(for: item)).rounded()),
            clip: clip,
            stroke2: item.kind == .pen ? Self.penHash(item) : 0
        )
        if let hit = lineCache[key] { return hit }

        guard let ctx = Self.makeContext(width: Int(clip.width), height: Int(clip.height)) else { return nil }
        ctx.translateBy(x: -clip.minX, y: -clip.minY)
        let isHighlighter = item.kind == .pen && item.highlighter
        if isHighlighter {
            // A marker: see-through and flat. The alpha applies to the whole layer, so crossings do not darken.
            ctx.setAlpha(0.42)
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -stroke * 0.35), blur: stroke * 1.6, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        }
        let color = NSColor(hexString: item.color)
        // One transparency layer, so the parts cast one shadow instead of overlapping ones.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if let g = arrow {
            let shaft = CGMutablePath()
            shaft.move(to: g.tail)
            shaft.addQuadCurve(to: g.shaftEnd, control: g.control)
            if progress < 0.999 {
                ctx.setLineDash(phase: 0, lengths: [Self.length(of: g) * CGFloat(progress), 1_000_000])
            }
            ctx.addPath(shaft)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            // The head appears over the last part of the stroke.
            let headAlpha = min(1.0, max(0.0, (progress - 0.8) / 0.2))
            if headAlpha > 0.001 {
                ctx.setAlpha(CGFloat(headAlpha))
                ctx.setFillColor(color.cgColor)
                ctx.move(to: g.head)
                ctx.addLine(to: g.headBaseLeft)
                ctx.addLine(to: g.headBaseRight)
                ctx.closePath()
                ctx.setLineWidth(stroke * 0.6)
                ctx.drawPath(using: .fillStroke)
            }
        } else if item.kind == .pen {
            ctx.translateBy(x: a.x, y: a.y)
            ctx.rotate(by: rotation)
            if isHighlighter { ctx.setLineCap(.butt) }
            ctx.addPath(Self.penPath(for: item, halfSize: CGSize(width: b.x, height: b.y), progress: progress))
            ctx.strokePath()
        } else {
            ctx.translateBy(x: a.x, y: a.y)
            ctx.rotate(by: rotation)
            let rect = CGRect(x: -b.x, y: -b.y, width: b.x * 2, height: b.y * 2)
            let path: CGPath
            let perimeter: CGFloat
            if item.kind == .ellipse {
                path = CGPath(ellipseIn: rect, transform: nil)
                // Ramanujan's approximation.
                let h = pow(b.x - b.y, 2) / max(0.001, pow(b.x + b.y, 2))
                perimeter = .pi * (b.x + b.y) * (1 + 3 * h / (10 + sqrt(4 - 3 * h)))
            } else {
                let r = min(corner, b.x, b.y)
                path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
                perimeter = 4 * (b.x + b.y) - (8 - 2 * .pi) * r
            }
            if item.fillOpacity > 0.001 {
                ctx.setFillColor(color.withAlphaComponent(CGFloat(item.fillOpacity * progress)).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            if progress < 0.999 {
                ctx.setLineDash(phase: 0, lengths: [perimeter * CGFloat(progress), 1_000_000])
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.endTransparencyLayer()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: clip.minX, y: clip.minY))
        if lineCache.count > 64 { lineCache.removeAll() }
        lineCache[key] = image
        return image
    }

    private static func boundingRect(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Length of the arrow's shaft, from 16 samples of the curve.
    private static func length(of g: ArrowGeometry) -> CGFloat {
        var total: CGFloat = 0
        var last = g.tail
        for i in 1...16 {
            let t = CGFloat(i) / 16
            let u = 1 - t
            let p = CGPoint(
                x: u * u * g.tail.x + 2 * u * t * g.control.x + t * t * g.shaftEnd.x,
                y: u * u * g.tail.y + 2 * u * t * g.control.y + t * t * g.shaftEnd.y
            )
            total += hypot(p.x - last.x, p.y - last.y)
            last = p
        }
        return total
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB. Anything else reads as white.
    convenience init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&rgb) else {
            self.init(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
