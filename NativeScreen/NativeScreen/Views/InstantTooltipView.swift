import SwiftUI
import AppKit
import QuartzCore

/// Instant tooltips and the `.hover-magnet` button system:
/// 1. **Standalone Borderless `TooltipPanel` + `NSVisualEffectView` (`.popover` material, `.behindWindow`)**:
///    Every tooltip in the app is drawn by AppKit in a dedicated panel (`CGWindowLevelForKey(.popUpMenuWindow)`)
///    with `panel.sharingType` mirrored from the owner window (`ownerWindow.sharingType != .none ? .readOnly : .none`),
///    so screenshots (`⇧⌘4`) capture tooltips normally while private HUD windows remain hidden if needed.
/// 2. **`BubbleShape` Boolean CSG Silhouette (`margin = 7.0`, `cornerRadius = min(W/6, H/6, 6.667)`, `caretReach = 5.8`, `tipRadius = 2.0`)**:
///    Constructs the exact union of `bodyPath` and `caretPath` with rounded inner fillet joints (`strokeWidth: 9.0` & `4.0` CSG rounding),
///    applied as `NSVisualEffectView.maskImage` and stroked with a seamless `1px` inner border (`white.opacity(0.16)`).
/// 3. **Directional Slide-In (`4pt` offset, `0.13s easeOut`) & Smooth Reposition (`0.12s`)**:
///    When appearing from hidden, the tooltip slides in by `4pt` from the placement direction while fading in (`0 -> 1` alpha over `0.13s`).
///    When moving directly from one hovered button to an adjacent button, it glides (`0.12s`) to the new frame.
/// 4. **Directional `.hover-magnet` Button Highlight**:
///    Every button tracks cursor entry, movement, and exit via a zero-SwiftUI-overhead AppKit `NSTrackingArea` + `CALayer` spring solver
///    (`stiffness = 1500, damping = 100, mass = 2`, `2pt` magnetic pull, `10x` escape distance, `0.8` entry scale).
///    When the cursor enters from any angle (e.g. top-right corner), the highlight layer starts `22pt` outside in that exact direction
///    and flies into the button (`overflow: visible`), tracks the cursor magnetically while inside, and flies out in the exit direction on leave!
///
/// Architecture & Performance References:
/// - `spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` (§7 Retained-Layer `.hover-magnet` Physics, §8 CSG Fillet Tooltip Geometry & `sharingType` Inheritance)
/// - `spec/platforms/macos-metal-videotoolbox.md` (§3 AppKit & SwiftUI Integration)
public enum TooltipEdge: Sendable {
    case leading
    case trailing
    case top
    case bottom

    var isVertical: Bool {
        switch self {
        case .top, .bottom: return true
        case .leading, .trailing: return false
        }
    }

    var opposite: TooltipEdge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    /// The side of the tooltip bubble where the caret arrow protrudes (opposite to the placement side relative to the button).
    var caretEdge: TooltipEdge {
        opposite
    }
}

// MARK: - 1. `BubbleShape`

public struct BubbleShape: Sendable, Equatable {
    /// Extra margin around `bodySize` inside the `NSPanel` so the `5.8pt` caret tip fits cleanly inside the mask image.
    public static let margin: CGFloat = 7.0

    public var panelSize: CGSize
    /// Side of the bubble where the caret arrow protrudes (`.bottom` when tooltip is `.top` of button, `.trailing` when tooltip is `.leading` of button, etc.).
    public var caretSide: TooltipEdge
    /// Caret center coordinate along the protruding edge (relative to `bodyRect.origin`).
    public var caretOffset: CGFloat

    public init(panelSize: CGSize, caretSide: TooltipEdge, caretOffset: CGFloat) {
        self.panelSize = panelSize
        self.caretSide = caretSide
        self.caretOffset = caretOffset
    }

    public var bodyRect: CGRect {
        CGRect(origin: .zero, size: panelSize).insetBy(dx: Self.margin, dy: Self.margin)
    }

    /// `BubbleShape.cornerRadius`: `min(bodyRect.width / 6.0, bodyRect.height / 6.0, 6.666666666666667)`.
    /// For a standard `28pt` tall tooltip, `28 / 6 = 4.67pt` `border-radius: 5px`!).
    public var cornerRadius: CGFloat {
        let br = bodyRect
        return min(min(br.width / 6.0, br.height / 6.0), 20.0 / 3.0)
    }

    public var bodyPath: CGPath {
        let br = bodyRect
        guard br.width > 4, br.height > 4 else {
            return CGPath(rect: br, transform: nil)
        }
        let r = cornerRadius
        return CGPath(roundedRect: br, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// `BubbleShape.caretPath`:
    /// Builds the rounded-tip triangle (`reach = 5.8`, `tipRadius = 2.0`) extending outward from `bodyRect` and overlapping deep into `bodyRect`.
    public var caretPath: CGPath {
        let br = bodyRect
        let r = cornerRadius

        let anchorX: CGFloat
        let anchorY: CGFloat
        let nx: CGFloat
        let ny: CGFloat
        let tx: CGFloat
        let ty: CGFloat

        switch caretSide {
        case .top:
            anchorX = br.minX + caretOffset
            anchorY = br.maxY
            nx = 0.0; ny = 1.0
            tx = -1.0; ty = 0.0
        case .bottom:
            anchorX = br.minX + caretOffset
            anchorY = br.minY
            nx = 0.0; ny = -1.0
            tx = 1.0; ty = 0.0
        case .leading:
            anchorX = br.minX
            anchorY = br.minY + caretOffset
            nx = -1.0; ny = 0.0
            tx = 0.0; ty = -1.0
        case .trailing:
            anchorX = br.maxX
            anchorY = br.minY + caretOffset
            nx = 1.0; ny = 0.0
            tx = 0.0; ty = 1.0
        }

        let depthIntoBody = caretSide.isVertical ? br.height : br.width
        let d12 = max(0.0, min(depthIntoBody - r, r))
        let reach: CGFloat = 5.8
        let halfSpan: CGFloat = (d12 / reach + 1.0) * 4.8

        let startPt = CGPoint(
            x: anchorX - tx * halfSpan - nx * d12,
            y: anchorY - ty * halfSpan - ny * d12
        )
        let preTipPt = CGPoint(
            x: anchorX - tx * 1.5134848 + nx * 3.9916203,
            y: anchorY - ty * 1.5134848 + ny * 3.9916203
        )
        let tipApexPt = CGPoint(
            x: anchorX + nx * reach,
            y: anchorY + ny * reach
        )
        let postTipPt = CGPoint(
            x: anchorX + tx * 1.5134848 + nx * 3.9916203,
            y: anchorY + ty * 1.5134848 + ny * 3.9916203
        )
        let endPt = CGPoint(
            x: anchorX + tx * halfSpan - nx * d12,
            y: anchorY + ty * halfSpan - ny * d12
        )

        let path = CGMutablePath()
        path.move(to: startPt)
        path.addLine(to: preTipPt)
        path.addArc(tangent1End: tipApexPt, tangent2End: postTipPt, radius: 2.0)
        path.addLine(to: endPt)
        path.closeSubpath()
        return path
    }

    /// `BubbleShape.outline`:
    /// Unions `bodyPath` and `caretPath`, and uses CoreGraphics path stroke-union/subtraction CSG (`9.0pt` outer fillet, `4.0pt` inner fillet)
    /// so the caret base blends into the bubble edge with zero internal seam or dashed artifact!
    public var outline: CGPath {
        let br = bodyRect
        let clipBox = caretSide.isVertical
            ? br.insetBy(dx: 0.0, dy: -Self.margin)
            : br.insetBy(dx: -Self.margin, dy: 0.0)
        let clipRectPath = CGPath(rect: clipBox, transform: nil)

        let clippedCaret = clipRectPath.intersection(caretPath, using: .winding)
        let baseUnion = clippedCaret.union(bodyPath, using: .winding)

        let expand9 = baseUnion.copy(strokingWithWidth: 9.0, lineCap: .round, lineJoin: .round, miterLimit: 1.0)
        let grown = expand9.union(baseUnion, using: .winding)
        let shrink9 = grown.copy(strokingWithWidth: 9.0, lineCap: .round, lineJoin: .round, miterLimit: 1.0)
        let filletedOuter = grown.subtracting(shrink9, using: .winding)

        let shrink4 = filletedOuter.copy(strokingWithWidth: 4.0, lineCap: .round, lineJoin: .round, miterLimit: 1.0)
        let eroded = filletedOuter.subtracting(shrink4, using: .winding)
        let expand4 = eroded.copy(strokingWithWidth: 4.0, lineCap: .round, lineJoin: .round, miterLimit: 1.0)
        return expand4.union(eroded, using: .winding)
    }

    /// Builds the `NSImage` mask for `NSVisualEffectView.maskImage` (`flipped: false`).
    public var maskImage: NSImage {
        let size = panelSize
        let outlinePath = outline
        return NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(outlinePath)
            ctx.fillPath(using: .winding)
            return true
        }
    }
}

// MARK: - 2. `TooltipPanel`, `TooltipContentView` & `SharedFloatingTooltipWindowController`

@MainActor
private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Renders the tooltip label (`12pt Medium`), optional `KeycapView` (`11pt Medium`, `secondaryLabelColor`, `cornerRadius = 3.0`,
/// `labelColor.withAlphaComponent(0.1)` background), and a subtle `1px` inner border along `BubbleShape.outline`.
@MainActor
private final class TooltipContentView: NSView {
    private var text: String = ""
    private var badge: String? = nil
    private var bubbleShape: BubbleShape?

    private static let labelFont = NSFont.systemFont(ofSize: 12.0, weight: .medium)
    private static let badgeFont = NSFont.systemFont(ofSize: 11.0, weight: .medium)
    private static let lineHeight: CGFloat = {
        let tf = NSTextField(labelWithString: " ")
        tf.font = NSFont.systemFont(ofSize: 12.0, weight: .medium)
        return tf.intrinsicContentSize.height
    }()

    override var isFlipped: Bool { false }

    static func computeBodySize(text: String, badge: String?) -> CGSize {
        let labelSize = (text as NSString).size(withAttributes: [.font: labelFont])
        let labelW = ceil(labelSize.width)
        let labelH = ceil(labelSize.height)

        let rightExtra: CGFloat
        if let badge, !badge.isEmpty {
            let bSize = (badge as NSString).size(withAttributes: [.font: badgeFont])
            let keycapW = max(24.0, ceil(bSize.width) + 14.0)
            rightExtra = 8.0 + keycapW + 5.0
        } else {
            rightExtra = 11.0
        }

        let verticalPad = (14.0 - 0.5 * lineHeight) * 2.0
        let bodyW = 11.0 + labelW + rightExtra
        let bodyH = max(28.0, labelH + verticalPad)
        return CGSize(width: bodyW, height: bodyH)
    }

    func configure(text: String, badge: String?, shape: BubbleShape) {
        self.text = text
        self.badge = badge
        self.bubbleShape = shape
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let shape = bubbleShape else { return }

        let outlinePath = shape.outline

        // 1. Subtle dark tint + crisp 1px inner border clipped to `outlinePath` so the bubble edge & caret tip look razor-sharp
        ctx.saveGState()
        ctx.addPath(outlinePath)
        ctx.clip()

        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.58).cgColor)
        ctx.fill(bounds)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(outlinePath)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. Draw Label & Optional Keycap inside `bodyRect` (inset by `BubbleShape.margin = 7.0`)
        let br = shape.bodyRect
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor
        ]
        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: textAttrs)
        let textX = br.minX + 10.0
        let textY = br.minY + floor((br.height - textSize.height) * 0.5)
        nsText.draw(at: CGPoint(x: textX, y: textY), withAttributes: textAttrs)

        if let badge = badge, !badge.isEmpty {
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let nsBadge = badge as NSString
            let bSize = nsBadge.size(withAttributes: badgeAttrs)
            let keycapW = max(24.0, ceil(bSize.width) + 14.0)
            let keycapH: CGFloat = 18.0
            let keycapX = br.maxX - 5.0 - keycapW
            let keycapY = br.minY + (br.height - keycapH) * 0.5
            let keycapRect = CGRect(x: keycapX, y: keycapY, width: keycapW, height: keycapH)

            let keycapPath = CGPath(roundedRect: keycapRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.10).cgColor)
            ctx.addPath(keycapPath)
            ctx.fillPath()
            ctx.restoreGState()

            let bX = keycapRect.minX + (keycapW - bSize.width) * 0.5
            let bY = keycapRect.minY + (keycapH - bSize.height) * 0.5
            nsBadge.draw(at: CGPoint(x: bX, y: bY), withAttributes: badgeAttrs)
        }
    }
}

@MainActor
public final class SharedFloatingTooltipWindowController {
    public static let shared = SharedFloatingTooltipWindowController()

    private let panel: TooltipPanel
    private let blurView: NSVisualEffectView
    private let contentView: TooltipContentView
    private weak var activeOwnerView: NSView?
    private var isCurrentlyShown: Bool = false
    private var showCount: Int = 0

    private init() {
        let p = TooltipPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.level = NSWindow.Level(rawValue: max(Int(CGWindowLevelForKey(.popUpMenuWindow)), NSWindow.Level.screenSaver.rawValue + 2))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let content = TooltipContentView(frame: .zero)
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        p.contentView = blur

        self.panel = p
        self.blurView = blur
        self.contentView = content
    }

    /// `TooltipPanelController.layOut(placement:bodySize:anchor:screen:)`.
    private static func layOut(
        placement: TooltipEdge,
        bodySize: CGSize,
        anchor: CGRect,
        screen: CGRect
    ) -> (panelFrame: CGRect, shape: BubbleShape) {
        let gap: CGFloat = 6.63158
        let screenMargin: CGFloat = 6.0

        var bodyOrigin = CGPoint.zero
        let caretOffset: CGFloat

        switch placement {
        case .top, .bottom:
            if placement == .top {
                bodyOrigin.y = anchor.maxY + gap
            } else {
                bodyOrigin.y = anchor.minY - gap - bodySize.height
            }
            let idealX = anchor.midX - bodySize.width * 0.5
            let minX = screen.minX + screenMargin
            let maxX = screen.maxX - screenMargin - bodySize.width
            bodyOrigin.x = min(max(idealX, minX), max(minX, maxX))

            if bodySize.width < 25.6 {
                caretOffset = bodySize.width * 0.5
            } else {
                let raw = anchor.midX - bodyOrigin.x
                caretOffset = min(max(raw, 12.8), bodySize.width - 12.8)
            }

        case .leading, .trailing:
            if placement == .leading {
                bodyOrigin.x = anchor.minX - gap - bodySize.width
            } else {
                bodyOrigin.x = anchor.maxX + gap
            }
            let idealY = anchor.midY - bodySize.height * 0.5
            let minY = screen.minY + screenMargin
            let maxY = screen.maxY - screenMargin - bodySize.height
            bodyOrigin.y = min(max(idealY, minY), max(minY, maxY))

            if bodySize.height < 25.6 {
                caretOffset = bodySize.height * 0.5
            } else {
                let raw = anchor.midY - bodyOrigin.y
                caretOffset = min(max(raw, 12.8), bodySize.height - 12.8)
            }
        }

        let bodyFrame = CGRect(origin: bodyOrigin, size: bodySize)
        let panelFrame = bodyFrame.insetBy(dx: -BubbleShape.margin, dy: -BubbleShape.margin)
        let shape = BubbleShape(
            panelSize: panelFrame.size,
            caretSide: placement.caretEdge,
            caretOffset: caretOffset
        )
        return (panelFrame, shape)
    }

    public func showTooltip(
        text: String,
        shortcutBadge: String? = nil,
        edge requestedEdge: TooltipEdge,
        forButtonScreenRect buttonRect: NSRect,
        ownerView: NSView? = nil
    ) {
        guard !text.isEmpty, buttonRect.width > 0, buttonRect.height > 0 else {
            hideTooltip()
            return
        }

        activeOwnerView = ownerView

        if let ownerWindow = ownerView?.window {
            let bestMatch = ownerWindow.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .darkAqua
            panel.appearance = NSAppearance(named: bestMatch)
            panel.sharingType = (ownerWindow.sharingType != .none) ? .readOnly : .none
            let baseLevel = max(Int(CGWindowLevelForKey(.popUpMenuWindow)), NSWindow.Level.screenSaver.rawValue + 2)
            panel.level = NSWindow.Level(rawValue: max(baseLevel, ownerWindow.level.rawValue + 1))
        } else {
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.sharingType = .readOnly
        }

        let parsed = InstantTooltipBubble.extractTrailingParenthesizedShortcut(from: text, explicitBadge: shortcutBadge)
        let bodySize = TooltipContentView.computeBodySize(text: parsed.cleanText, badge: parsed.badge)

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let gap: CGFloat = 6.63158
        var effectiveEdge = requestedEdge
        let fitsRequested: Bool = {
            switch requestedEdge {
            case .top:
                return buttonRect.maxY + gap + bodySize.height <= vf.maxY - 6.0
            case .bottom:
                return buttonRect.minY - gap - bodySize.height >= vf.minY + 6.0
            case .leading:
                return buttonRect.minX - gap - bodySize.width >= vf.minX + 6.0
            case .trailing:
                return buttonRect.maxX + gap + bodySize.width <= vf.maxX - 6.0
            }
        }()
        if !fitsRequested {
            let opp = requestedEdge.opposite
            let fitsOpposite: Bool = {
                switch opp {
                case .top:
                    return buttonRect.maxY + gap + bodySize.height <= vf.maxY - 6.0
                case .bottom:
                    return buttonRect.minY - gap - bodySize.height >= vf.minY + 6.0
                case .leading:
                    return buttonRect.minX - gap - bodySize.width >= vf.minX + 6.0
                case .trailing:
                    return buttonRect.maxX + gap + bodySize.width <= vf.maxX - 6.0
                }
            }()
            if fitsOpposite {
                effectiveEdge = opp
            }
        }

        let (targetFrame, shape) = Self.layOut(
            placement: effectiveEdge,
            bodySize: bodySize,
            anchor: buttonRect,
            screen: vf
        )

        blurView.frame = CGRect(origin: .zero, size: targetFrame.size)
        blurView.maskImage = shape.maskImage
        contentView.frame = CGRect(origin: .zero, size: targetFrame.size)
        contentView.configure(text: parsed.cleanText, badge: parsed.badge, shape: shape)

        showCount &+= 1
        let currentShowID = showCount

        if isCurrentlyShown && panel.isVisible && panel.alphaValue > 0.05 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        } else {
            // Reduce Motion: fade in place, no slide.
            let slideOffset: CGPoint = AccessibilityText.reduceMotion ? .zero : {
                switch effectiveEdge {
                case .top:      return CGPoint(x: 0.0, y: -4.0)
                case .bottom:   return CGPoint(x: 0.0, y: 4.0)
                case .leading:  return CGPoint(x: 4.0, y: 0.0)
                case .trailing: return CGPoint(x: -4.0, y: 0.0)
                }
            }()
            let startFrame = targetFrame.offsetBy(dx: slideOffset.x, dy: slideOffset.y)
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            isCurrentlyShown = true

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        }
        panel.invalidateShadow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, self.showCount == currentShowID else { return }
            self.hideTooltip()
        }
    }

    public func hideTooltip(ifOwnedBy ownerView: NSView? = nil) {
        if let ownerView, let activeOwnerView, ownerView !== activeOwnerView {
            return
        }
        activeOwnerView = nil
        isCurrentlyShown = false
        showCount &+= 1
        let hideID = showCount

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCurrentlyShown, self.showCount == hideID else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}

// MARK: - 3. Unified Single-Path Callout Shape & SwiftUI `InstantTooltipBubble`

public struct UnifiedTooltipCalloutShape: InsettableShape {
    public var edge: TooltipEdge
    public var cornerRadius: CGFloat
    public var arrowWidth: CGFloat
    public var arrowHeight: CGFloat
    public var anchorOffset: CGFloat
    public var insetAmount: CGFloat = 0.0

    public init(
        edge: TooltipEdge,
        cornerRadius: CGFloat = 5.0,
        arrowWidth: CGFloat = 10.0,
        arrowHeight: CGFloat = 5.8,
        anchorOffset: CGFloat = 0.0
    ) {
        self.edge = edge
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.anchorOffset = anchorOffset
    }

    public func inset(by amount: CGFloat) -> UnifiedTooltipCalloutShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    public func path(in fullRect: CGRect) -> Path {
        let rect = fullRect.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 8, rect.height > 8 else { return Path() }

        let panelSize = CGSize(
            width: rect.width + BubbleShape.margin * 2.0,
            height: rect.height + BubbleShape.margin * 2.0
        )
        let caretOffset = (edge.isVertical ? rect.width : rect.height) * 0.5 + anchorOffset
        let shape = BubbleShape(
            panelSize: panelSize,
            caretSide: edge.caretEdge,
            caretOffset: caretOffset
        )
        var transform = CGAffineTransform(
            translationX: rect.minX - BubbleShape.margin,
            y: rect.minY - BubbleShape.margin
        )
        if let cgPath = shape.outline.copy(using: &transform) {
            return Path(cgPath)
        }
        return Path(roundedRect: rect, cornerRadius: cornerRadius)
    }
}

public struct InstantTooltipBubble: View {
    public let text: String
    public let shortcutBadge: String?
    public let edge: TooltipEdge
    public let anchorOffset: CGFloat

    public init(
        text: String,
        shortcutBadge: String? = nil,
        edge: TooltipEdge,
        anchorOffset: CGFloat = 0.0
    ) {
        let parsed = Self.extractTrailingParenthesizedShortcut(from: text, explicitBadge: shortcutBadge)
        self.text = parsed.cleanText
        self.shortcutBadge = parsed.badge
        self.edge = edge
        self.anchorOffset = anchorOffset
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(text.localizedUI)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let badge = shortcutBadge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, shortcutBadge != nil ? 5 : 10)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(red: 0.14, green: 0.15, blue: 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1.0)
        )
    }

    /// Automatically extracts trailing shortcuts like `"Undo (⌘Z)"` -> `("Undo", "⌘Z")` or `"Split clip (⌥)"` -> `("Split clip", "⌥")`
    /// so every tooltip with a shortcut renders a sleek keycap badge!
    static func extractTrailingParenthesizedShortcut(
        from rawText: String,
        explicitBadge: String?
    ) -> (cleanText: String, badge: String?) {
        if let explicitBadge, !explicitBadge.isEmpty {
            return (rawText, explicitBadge)
        }
        guard rawText.hasSuffix(")"),
              let openIdx = rawText.lastIndex(of: "("),
              openIdx > rawText.startIndex else {
            return (rawText, nil)
        }
        let prefixText = String(rawText[..<openIdx]).trimmingCharacters(in: .whitespaces)
        let inside = String(rawText[rawText.index(after: openIdx)..<rawText.index(before: rawText.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !prefixText.isEmpty, !inside.isEmpty, inside.count <= 7 else {
            return (rawText, nil)
        }
        return (prefixText, inside)
    }
}

// MARK: - 4. 120Hz Directional `.hover-magnet` AppKit Layer Engine

private struct TooltipHoverBlockedEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var isTooltipAndHoverBlocked: Bool {
        get { self[TooltipHoverBlockedEnvironmentKey.self] }
        set { self[TooltipHoverBlockedEnvironmentKey.self] = newValue }
    }
}

private struct ScalarSpring1D {
    var value: Double = 0.0
    var velocity: Double = 0.0
    var target: Double = 0.0

    var isAtRest: Bool {
        abs(value - target) < 0.002 && abs(velocity) < 0.01
    }

    mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0.0
    }

    mutating func step(dt: Double, stiffness: Double = 1500.0, damping: Double = 100.0, mass: Double = 2.0, clampOvershoot: Bool = true) {
        guard !isAtRest else {
            value = target
            velocity = 0.0
            return
        }
        let prevDelta = value - target
        let force = -stiffness * prevDelta - damping * velocity
        let accel = force / mass
        velocity += accel * dt
        value += velocity * dt

        if clampOvershoot && ((prevDelta < 0.0 && value > target) || (prevDelta > 0.0 && value < target)) {
            value = target
            velocity = 0.0
        } else if isAtRest {
            value = target
            velocity = 0.0
        }
    }
}

/// Pure AppKit `NSView` that renders the directional `.hover-magnet` `CALayer` (`overflow: visible`)
/// and drives `SharedFloatingTooltipWindowController` with zero SwiftUI `@State` invalidations during hover/move!
@MainActor
public final class HoverMagnetTrackingNSView: NSView {
    var tooltip: String = ""
    var shortcutBadge: String? = nil
    var edge: TooltipEdge = .trailing
    var cornerRadius: CGFloat = 6.0 {
        didSet {
            if abs(oldValue - cornerRadius) > 0.05 {
                magnetLayer.cornerRadius = cornerRadius
            }
        }
    }
    var isButtonActive: Bool = false {
        didSet {
            if oldValue != isButtonActive {
                applyMagnetTransform()
            }
        }
    }
    var isButtonDisabled: Bool = false {
        didSet {
            guard oldValue != isButtonDisabled else { return }
            if isButtonDisabled && !allowHoverWhenDisabled {
                isHoveredSpring.target = 0.0
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: self)
                startSpringTimerIfNeeded()
            } else {
                applyMagnetTransform()
            }
        }
    }
    var allowHoverWhenDisabled: Bool = false {
        didSet {
            if oldValue != allowHoverWhenDisabled {
                applyMagnetTransform()
            }
        }
    }
    var isHoverBlocked: Bool = false {
        didSet {
            guard oldValue != isHoverBlocked else { return }
            if isHoverBlocked {
                if let existing = trackingAreaRef {
                    removeTrackingArea(existing)
                    trackingAreaRef = nil
                }
                isHoveredSpring.target = 0.0
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: self)
                startSpringTimerIfNeeded()
            } else {
                updateTrackingAreas()
            }
        }
    }
    var isCurrentlyHovered: Bool {
        isHoveredSpring.target > 0.5 && (!isButtonDisabled || allowHoverWhenDisabled) && !isHoverBlocked
    }
    var isRailTab: Bool = false {
        didSet {
            if oldValue != isRailTab {
                applyMagnetTransform()
            }
        }
    }
    var hasActiveBorder: Bool = false {
        didSet {
            if oldValue != hasActiveBorder {
                applyMagnetTransform()
            }
        }
    }
    var activeRGB: (CGFloat, CGFloat, CGFloat) = (0.45, 0.36, 0.96) {
        didSet {
            applyMagnetTransform()
        }
    }

    private let magnetLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?
    private var springTimer: Timer?

    // Springs (`isHoveredSpring`, `offsetSpring.x`, `offsetSpring.y`)
    private var isHoveredSpring = ScalarSpring1D()
    private var offsetXSpring = ScalarSpring1D()
    private var offsetYSpring = ScalarSpring1D()

    // Magnet constants: pull 2pt, escape at 10x, entry scale 0.8
    private let magnetMaxOffset: Double = 2.0
    private let escapeMultiplier: Double = 10.0
    private let entryScale: Double = 0.80

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        magnetLayer.cornerRadius = cornerRadius
        magnetLayer.cornerCurve = .continuous
        magnetLayer.masksToBounds = false
        magnetLayer.opacity = 0.0
        layer?.addSublayer(magnetLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pass all mouse clicks straight through to the SwiftUI `Button` while `NSTrackingArea` still receives hover/move events!
    public override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
            trackingAreaRef = nil
        }
        guard !isHoverBlocked else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    public override func layout() {
        super.layout()
        layer?.masksToBounds = false
        applyMagnetTransform()
    }

    private func computeMagnetTargetOffset(for event: NSEvent) -> CGPoint {
        let localPt = convert(event.locationInWindow, from: nil)
        let w = max(1.0, Double(bounds.width))
        let h = max(1.0, Double(bounds.height))
        let u = min(max(Double(localPt.x) / w, 0.0), 1.0)
        let v = min(max(Double(localPt.y) / h, 0.0), 1.0)
        let sx = u * 2.0 - 1.0
        let sy = v * 2.0 - 1.0
        return CGPoint(x: sx * magnetMaxOffset, y: sy * magnetMaxOffset)
    }

    public override func mouseEntered(with event: NSEvent) {
        guard (!isButtonDisabled || allowHoverWhenDisabled), !isHoverBlocked, window?.attachedSheet == nil else { return }
        let targetOff = computeMagnetTargetOffset(for: event)

        // On enter, snap the offset spring straight to its target:
        // When entering from idle, snap the offset spring to the entry angle so the highlight flies in from that exact angle!
        if isHoveredSpring.value < 0.15 {
            offsetXSpring.snap(to: Double(targetOff.x))
            offsetYSpring.snap(to: Double(targetOff.y))
        } else {
            offsetXSpring.target = Double(targetOff.x)
            offsetYSpring.target = Double(targetOff.y)
        }
        isHoveredSpring.target = 1.0
        startSpringTimerIfNeeded()
        presentTooltipIfNeeded()
    }

    public override func mouseMoved(with event: NSEvent) {
        guard (!isButtonDisabled || allowHoverWhenDisabled), !isHoverBlocked, window?.attachedSheet == nil else { return }
        let targetOff = computeMagnetTargetOffset(for: event)
        offsetXSpring.target = Double(targetOff.x)
        offsetYSpring.target = Double(targetOff.y)
        if isHoveredSpring.target < 0.5 {
            isHoveredSpring.target = 1.0
            presentTooltipIfNeeded()
        }
        startSpringTimerIfNeeded()
    }

    public override func mouseExited(with event: NSEvent) {
        let targetOff = computeMagnetTargetOffset(for: event)
        offsetXSpring.target = Double(targetOff.x)
        offsetYSpring.target = Double(targetOff.y)
        isHoveredSpring.target = 0.0
        startSpringTimerIfNeeded()
        SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: self)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopSpringTimer()
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func presentTooltipIfNeeded() {
        guard (!isButtonDisabled || allowHoverWhenDisabled), !isHoverBlocked, !tooltip.isEmpty, let win = window, win.attachedSheet == nil else { return }
        let rectInWin = convert(bounds, to: nil)
        let screenRect = win.convertToScreen(rectInWin)
        SharedFloatingTooltipWindowController.shared.showTooltip(
            text: tooltip.localizedUI,
            shortcutBadge: isButtonDisabled ? nil : shortcutBadge,
            edge: edge,
            forButtonScreenRect: screenRect,
            ownerView: self
        )
    }

    private func startSpringTimerIfNeeded() {
        // Reduce Motion: the highlight appears and leaves in place, without flying in or following the cursor.
        if AccessibilityText.reduceMotion {
            stopSpringTimer()
            isHoveredSpring.snap(to: isHoveredSpring.target)
            offsetXSpring.snap(to: 0.0)
            offsetYSpring.snap(to: 0.0)
            applyMagnetTransform()
            return
        }
        guard springTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepSprings()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func stopSpringTimer() {
        springTimer?.invalidate()
        springTimer = nil
    }

    private func stepSprings() {
        let dt = 1.0 / 120.0
        // Spring `{ damping: 100, stiffness: 1500, mass: 2 }`
        isHoveredSpring.step(dt: dt, stiffness: 1500.0, damping: 100.0, mass: 2.0)
        offsetXSpring.step(dt: dt, stiffness: 1500.0, damping: 100.0, mass: 2.0, clampOvershoot: false)
        offsetYSpring.step(dt: dt, stiffness: 1500.0, damping: 100.0, mass: 2.0, clampOvershoot: false)

        applyMagnetTransform()

        if isHoveredSpring.isAtRest && offsetXSpring.isAtRest && offsetYSpring.isAtRest {
            if isHoveredSpring.target == 0.0 {
                offsetXSpring.snap(to: 0.0)
                offsetYSpring.snap(to: 0.0)
            }
            stopSpringTimer()
        }
    }

    private func applyMagnetTransform() {
        let b = bounds
        guard b.width > 1.0, b.height > 1.0 else { return }

        let h = min(max(isHoveredSpring.value, 0.0), 1.0)
        let offX = offsetXSpring.value
        let offY = offsetYSpring.value

        // Active tool buttons (except rail tabs) stay visible at rest
        let isPersistentActive = isButtonActive && !isRailTab
        let enableEscape = !isPersistentActive

        let tx: Double
        let ty: Double
        let scale: Double
        let layerOpacity: Float

        if enableEscape {
            let escapeFactor = (1.0 - h) * escapeMultiplier
            tx = offX + offX * escapeFactor
            ty = offY + offY * escapeFactor
            scale = entryScale + (1.0 - entryScale) * h
            layerOpacity = h < 0.01 ? 0.0 : Float(h)
        } else {
            tx = offX
            ty = offY
            scale = 1.0
            layerOpacity = 1.0
        }

        // Transform origin in normalized `[0, 1]` coordinates:
        let scalarX = offX / magnetMaxOffset
        let scalarY = offY / magnetMaxOffset
        let originX = CGFloat((scalarX + 1.0) * 0.5) * b.width
        let originY = CGFloat((scalarY + 1.0) * 0.5) * b.height

        let cx = b.midX
        let cy = b.midY
        let s = CGFloat(scale)

        // Equivalent to CSS `transform-origin: originX originY; transform: translate(tx, ty) scale(s)`
        let posX = cx + (cx - originX) * (s - 1.0) + CGFloat(tx)
        let posY = cy + (cy - originY) * (s - 1.0) + CGFloat(ty)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        magnetLayer.bounds = b
        magnetLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        magnetLayer.position = CGPoint(x: posX, y: posY)
        magnetLayer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        magnetLayer.cornerRadius = cornerRadius
        if isButtonDisabled {
            magnetLayer.opacity = allowHoverWhenDisabled ? (layerOpacity * 0.48) : 0.0
        } else {
            magnetLayer.opacity = layerOpacity
        }

        if isPersistentActive {
            let alpha = 0.24 + 0.12 * CGFloat(h)
            magnetLayer.backgroundColor = NSColor(
                srgbRed: activeRGB.0,
                green: activeRGB.1,
                blue: activeRGB.2,
                alpha: alpha
            ).cgColor
            if hasActiveBorder {
                magnetLayer.borderWidth = 1.0
                magnetLayer.borderColor = NSColor(
                    srgbRed: min(1.0, activeRGB.0 + 0.12),
                    green: min(1.0, activeRGB.1 + 0.12),
                    blue: min(1.0, activeRGB.2 + 0.12),
                    alpha: 0.38 + 0.18 * CGFloat(h)
                ).cgColor
            } else {
                magnetLayer.borderWidth = 0.0
            }
        } else {
            // `#ffffff14`
            magnetLayer.backgroundColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.095).cgColor
            magnetLayer.borderWidth = 0.0
        }

        CATransaction.commit()
    }
}

public struct HoverMagnetBackgroundRepresentable: NSViewRepresentable {
    public let tooltip: String
    public let shortcutBadge: String?
    public let edge: TooltipEdge
    public let cornerRadius: CGFloat
    public let isActive: Bool
    public let isDisabled: Bool
    public let allowHoverWhenDisabled: Bool
    public let isHoverBlocked: Bool
    public let isRailTab: Bool
    public let hasActiveBorder: Bool
    public let activeRGB: (CGFloat, CGFloat, CGFloat)
    public let onViewReady: (HoverMagnetTrackingNSView) -> Void

    public init(
        tooltip: String,
        shortcutBadge: String? = nil,
        edge: TooltipEdge,
        cornerRadius: CGFloat,
        isActive: Bool,
        isDisabled: Bool = false,
        allowHoverWhenDisabled: Bool = false,
        isHoverBlocked: Bool = false,
        isRailTab: Bool = false,
        hasActiveBorder: Bool = false,
        activeRGB: (CGFloat, CGFloat, CGFloat) = (0.45, 0.36, 0.96),
        onViewReady: @escaping (HoverMagnetTrackingNSView) -> Void
    ) {
        self.tooltip = tooltip
        self.shortcutBadge = shortcutBadge
        self.edge = edge
        self.cornerRadius = cornerRadius
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.allowHoverWhenDisabled = allowHoverWhenDisabled
        self.isHoverBlocked = isHoverBlocked
        self.isRailTab = isRailTab
        self.hasActiveBorder = hasActiveBorder
        self.activeRGB = activeRGB
        self.onViewReady = onViewReady
    }

    public func makeNSView(context: Context) -> HoverMagnetTrackingNSView {
        let v = HoverMagnetTrackingNSView(frame: .zero)
        v.tooltip = tooltip
        v.shortcutBadge = shortcutBadge
        v.edge = edge
        v.cornerRadius = cornerRadius
        v.isButtonActive = isActive
        v.allowHoverWhenDisabled = allowHoverWhenDisabled
        v.isButtonDisabled = isDisabled
        v.isHoverBlocked = isHoverBlocked
        v.isRailTab = isRailTab
        v.hasActiveBorder = hasActiveBorder
        v.activeRGB = activeRGB
        DispatchQueue.main.async {
            onViewReady(v)
        }
        return v
    }

    public func updateNSView(_ nsView: HoverMagnetTrackingNSView, context: Context) {
        let tooltipChanged = (nsView.tooltip != tooltip || nsView.shortcutBadge != shortcutBadge)
        nsView.tooltip = tooltip
        nsView.shortcutBadge = shortcutBadge
        nsView.edge = edge
        nsView.cornerRadius = cornerRadius
        nsView.isButtonActive = isActive
        nsView.allowHoverWhenDisabled = allowHoverWhenDisabled
        nsView.isButtonDisabled = isDisabled
        nsView.isHoverBlocked = isHoverBlocked
        nsView.isRailTab = isRailTab
        nsView.hasActiveBorder = hasActiveBorder
        nsView.activeRGB = activeRGB
        if tooltipChanged && nsView.isCurrentlyHovered {
            nsView.presentTooltipIfNeeded()
        }
    }
}

// MARK: - 5. Reusable Tooltip & Directional `.hover-magnet` Buttons (`InstantTooltipButton` & `SubToolbarPillButton`)

public struct InstantTooltipButton<LabelContent: View>: View {
    let tooltip: String
    let shortcutBadge: String?
    let edge: TooltipEdge
    let isActive: Bool
    let isDisabled: Bool
    let allowHoverWhenDisabled: Bool
    let activeColor: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Read after the name when the icon shows a state, e.g. the playback speed (already translated).
    let accessibilityValue: String?
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent

    @Environment(\.isTooltipAndHoverBlocked) private var isTooltipAndHoverBlocked
    @State private var magnetNSView: HoverMagnetTrackingNSView?

    public init(
        tooltip: String,
        shortcutBadge: String? = nil,
        edge: TooltipEdge = .trailing,
        isActive: Bool = false,
        isDisabled: Bool = false,
        allowHoverWhenDisabled: Bool = false,
        activeColor: Color = Color(red: 0.45, green: 0.36, blue: 0.96),
        size: CGFloat = 38,
        cornerRadius: CGFloat = 6,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.accessibilityValue = accessibilityValue
        self.tooltip = tooltip
        self.shortcutBadge = shortcutBadge
        self.edge = edge
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.allowHoverWhenDisabled = allowHoverWhenDisabled
        self.activeColor = activeColor
        self.size = size
        self.cornerRadius = cornerRadius
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button {
            guard !isDisabled, !isTooltipAndHoverBlocked else { return }
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: magnetNSView)
            action()
        } label: {
            ZStack {
                label()
                    .opacity(isDisabled ? 0.28 : 1.0)

                // Active dot indicator on the right side for active rail tabs
                if isActive && !isDisabled && edge == .leading {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color(red: 0.65, green: 0.58, blue: 0.99))
                            .frame(width: 4.0, height: 4.0)
                            .padding(.trailing, 5)
                    }
                }
            }
            .frame(width: size, height: size)
            .background(
                HoverMagnetBackgroundRepresentable(
                    tooltip: tooltip,
                    shortcutBadge: shortcutBadge,
                    edge: edge,
                    cornerRadius: cornerRadius,
                    isActive: isActive,
                    isDisabled: isDisabled,
                    allowHoverWhenDisabled: allowHoverWhenDisabled,
                    isHoverBlocked: isTooltipAndHoverBlocked,
                    isRailTab: edge == .leading,
                    hasActiveBorder: false,
                    activeRGB: (0.45, 0.36, 0.96)
                ) { v in
                    magnetNSView = v
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !allowHoverWhenDisabled)
        // Icon-only: the tooltip is the name VoiceOver reads; the shortcut stays in the tooltip.
        .accessibilityLabel(Text(AccessibilityText.label(fromTooltip: tooltip)))
        .accessibilityValue(Text(accessibilityValue ?? ""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// `control` Pill Button (`height: 36`, `paddingX: 12`, `cornerRadius: 6`) with directional `.hover-magnet` highlight!
public struct SubToolbarPillButton<LabelContent: View>: View {
    let tooltip: String?
    let edge: TooltipEdge
    let isActive: Bool
    let height: CGFloat
    let horizontalPadding: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    let onActionWithAnchorView: ((NSView?) -> Void)?
    /// What VoiceOver reads when the visible text alone does not say what the pill does (catalog keys).
    let accessibilityLabel: String?
    let accessibilityValue: String?
    @ViewBuilder let label: () -> LabelContent

    @Environment(\.isTooltipAndHoverBlocked) private var isTooltipAndHoverBlocked
    @State private var magnetNSView: HoverMagnetTrackingNSView?

    public init(
        tooltip: String? = nil,
        edge: TooltipEdge = .top,
        isActive: Bool = false,
        height: CGFloat = 34,
        horizontalPadding: CGFloat = 12,
        cornerRadius: CGFloat = 6,
        action: @escaping () -> Void = {},
        onActionWithAnchorView: ((NSView?) -> Void)? = nil,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.tooltip = tooltip
        self.edge = edge
        self.isActive = isActive
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.cornerRadius = cornerRadius
        self.action = action
        self.onActionWithAnchorView = onActionWithAnchorView
        self.label = label
    }

    public var body: some View {
        Button {
            guard !isTooltipAndHoverBlocked else { return }
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: magnetNSView)
            if let onActionWithAnchorView {
                onActionWithAnchorView(magnetNSView)
            } else {
                action()
            }
        } label: {
            label()
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(
                    HoverMagnetBackgroundRepresentable(
                        tooltip: tooltip ?? "",
                        shortcutBadge: nil,
                        edge: edge,
                        cornerRadius: cornerRadius,
                        isActive: isActive,
                        isDisabled: false,
                        isHoverBlocked: isTooltipAndHoverBlocked,
                        isRailTab: false,
                        hasActiveBorder: isActive,
                        activeRGB: (0.35, 0.28, 0.72)
                    ) { v in
                        magnetNSView = v
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabelIfAny(accessibilityLabel)
        .accessibilityValue(Text(accessibilityValue ?? ""))
        .accessibilityHint(Text(accessibilityLabel == nil ? (tooltip ?? "").localizedUI : ""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

public struct TooltipScreenRectProbe: NSViewRepresentable {
    public let onViewReady: (NSView) -> Void

    public init(onViewReady: @escaping (NSView) -> Void) {
        self.onViewReady = onViewReady
    }

    public func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onViewReady(v) }
        return v
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
    }
}
