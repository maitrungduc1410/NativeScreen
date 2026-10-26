import SwiftUI
import AppKit
import QuartzCore

/// & AppKit Tooltip System:
/// 1. **Standalone Borderless `TooltipPanel` + `NSVisualEffectView` (`.tooltip` material, `.behindWindow`)**:
///    Every tooltip in the app is drawn by AppKit in a dedicated panel (`CGWindowLevelForKey(.popUpMenuWindow)`)
///    with `panel.sharingType` mirrored from the owner window (`ownerWindow.sharingType != .none ? .readOnly : .none`),
///    so screenshots (`⇧⌘4`) capture tooltips normally while private HUD windows remain hidden if needed.
/// 2. **Exact `BubbleShape` Boolean CSG Silhouette (`margin = 7.0`, `cornerRadius = min(W/6, H/6, 6.667)`, `caretReach = 5.8`, `tipRadius = 2.0`)**:
///    Constructs the exact union of `bodyPath` and `caretPath` with rounded inner fillet joints (`strokeWidth: 9.0` & `4.0` CSG rounding),
///    applied as `NSVisualEffectView.maskImage` and stroked with a seamless `1px` inner border (`white.opacity(0.14)`).
///    This completely eliminates any broken/dashed line seam on the left/right/top/bottom pointer arrow!
/// 3. **Directional Slide-In (`4pt` offset, `0.13s easeOut`) & Smooth Reposition (`0.12s`)**:
///    When appearing from hidden, the tooltip slides in by `4pt` from the placement direction while fading in (`0 -> 1` alpha over `0.13s`).
///    When moving directly from one hovered button to an adjacent button, it glides (`0.12s`) to the new frame.
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

// MARK: - 1. Exact `BubbleShape`

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

    /// Exact `BubbleShape.cornerRadius`: `min(bodyRect.width / 6.0, bodyRect.height / 6.0, 6.666666666666667)`.
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

    /// Exact `BubbleShape.caretPath`:
    /// Builds the rounded-tip triangle (`reach = 5.8`, `tipRadius = 2.0`) extending outward from `bodyRect` and overlapping deep into `bodyRect`.
    public var caretPath: CGPath {
        let br = bodyRect
        let r = cornerRadius

        // Unit normal `(nx, ny)` pointing outward from the caret side, and unit tangent `(tx, ty)` along the edge
        let anchorX: CGFloat
        let anchorY: CGFloat
        let nx: CGFloat
        let ny: CGFloat
        let tx: CGFloat
        let ty: CGFloat

        switch caretSide {
        case .top:
            // Protruding UP from top edge of bubble (in unflipped CoreGraphics coordinates where maxY is top, or we use consistent unflipped coordinates)
            anchorX = br.minX + caretOffset
            anchorY = br.maxY
            nx = 0.0; ny = 1.0
            tx = -1.0; ty = 0.0
        case .bottom:
            // Protruding DOWN from bottom edge of bubble
            anchorX = br.minX + caretOffset
            anchorY = br.minY
            nx = 0.0; ny = -1.0
            tx = 1.0; ty = 0.0
        case .leading:
            // Protruding LEFT from left edge of bubble
            anchorX = br.minX
            anchorY = br.minY + caretOffset
            nx = -1.0; ny = 0.0
            tx = 0.0; ty = -1.0
        case .trailing:
            // Protruding RIGHT from right edge of bubble
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

    /// Exact `BubbleShape.outline`:
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

        // Apply CSG fillet smoothing at the caret-body neck:
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

// MARK: - 2. Exact `TooltipPanel`, `TooltipContentView` & `SharedFloatingTooltipWindowController`

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
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
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

    /// Exact `TooltipPanelController.layOut(placement:bodySize:anchor:screen:)`.
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

        // Mirror owner window appearance & sharingType.
        if let ownerWindow = ownerView?.window {
            let bestMatch = ownerWindow.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .darkAqua
            panel.appearance = NSAppearance(named: bestMatch)
            panel.sharingType = (ownerWindow.sharingType != .none) ? .readOnly : .none
        } else {
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.sharingType = .readOnly
        }

        let parsed = InstantTooltipBubble.extractTrailingParenthesizedShortcut(from: text, explicitBadge: shortcutBadge)
        let bodySize = TooltipContentView.computeBodySize(text: parsed.cleanText, badge: parsed.badge)

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // Flip to opposite side if `requestedEdge` would overflow the screen edge (`6pt` margin)
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
            // Already visible -> smoothly glide to the new button over `0.12s`
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        } else {
            // Appearing from hidden -> start `4.0pt` closer to the button along `effectiveEdge` and slide into `targetFrame` over `0.13s easeOut`!
            let slideOffset: CGPoint = {
                switch effectiveEdge {
                case .top:      return CGPoint(x: 0.0, y: -4.0) // starts 4pt lower (closer to button), slides UP
                case .bottom:   return CGPoint(x: 0.0, y: 4.0)  // starts 4pt higher (closer to button), slides DOWN
                case .leading:  return CGPoint(x: 4.0, y: 0.0)  // starts 4pt right (closer to button), slides LEFT
                case .trailing: return CGPoint(x: -4.0, y: 0.0) // starts 4pt left (closer to button), slides RIGHT
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

        // Auto-hide safety timeout after 15s
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
            Text(text)
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

// MARK: - 4. Reusable Tooltip Buttons (`InstantTooltipButton` & `SubToolbarPillButton`)

public struct InstantTooltipButton<LabelContent: View>: View {
    let tooltip: String
    let shortcutBadge: String?
    let edge: TooltipEdge
    let isActive: Bool
    let isDisabled: Bool
    let activeColor: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent

    @State private var isHovered = false
    @State private var anchorNSView: NSView?

    public init(
        tooltip: String,
        shortcutBadge: String? = nil,
        edge: TooltipEdge = .trailing,
        isActive: Bool = false,
        isDisabled: Bool = false,
        activeColor: Color = Color(red: 0.45, green: 0.36, blue: 0.96),
        size: CGFloat = 32,
        cornerRadius: CGFloat = 8,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.tooltip = tooltip
        self.shortcutBadge = shortcutBadge
        self.edge = edge
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.activeColor = activeColor
        self.size = size
        self.cornerRadius = cornerRadius
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button {
            guard !isDisabled else { return }
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            action()
        } label: {
            ZStack {
                label()
                    .opacity(isDisabled ? 0.25 : 1.0)

                // Active dot indicator on the right side for active rail tabs
                if isActive && !isDisabled && edge == .leading {
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color(red: 0.68, green: 0.60, blue: 1.0))
                            .frame(width: 4.5, height: 4.5)
                            .padding(.trailing, 3)
                    }
                }
            }
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .background(
                TooltipScreenRectProbe { v in
                    anchorNSView = v
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            let nextHover = isDisabled ? false : hovering
            if isHovered != nextHover {
                isHovered = nextHover
            }
            if nextHover && !tooltip.isEmpty {
                presentFloatingTooltip()
            } else {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled && isHovered {
                isHovered = false
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .onChange(of: tooltip) { _, newTooltip in
            if isHovered && !isDisabled && !newTooltip.isEmpty {
                presentFloatingTooltip()
            }
        }
        .onDisappear {
            if isHovered {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
    }

    private func presentFloatingTooltip() {
        guard let v = anchorNSView, let win = v.window else { return }
        let rectInWin = v.convert(v.bounds, to: nil)
        let screenRect = win.convertToScreen(rectInWin)
        SharedFloatingTooltipWindowController.shared.showTooltip(
            text: tooltip,
            shortcutBadge: shortcutBadge,
            edge: edge,
            forButtonScreenRect: screenRect,
            ownerView: v
        )
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.clear
        }
        if isActive {
            if edge == .leading {
                return isHovered ? Color.white.opacity(0.14) : Color.white.opacity(0.09)
            }
            return isHovered ? activeColor.opacity(0.38) : activeColor.opacity(0.28)
        }
        return isHovered ? Color.white.opacity(0.12) : Color.clear
    }
}

public struct SubToolbarPillButton<LabelContent: View>: View {
    let tooltip: String?
    let edge: TooltipEdge
    let isActive: Bool
    let action: () -> Void
    let onActionWithAnchorView: ((NSView?) -> Void)?
    @ViewBuilder let label: () -> LabelContent

    @State private var isHovered = false
    @State private var anchorNSView: NSView?

    public init(
        tooltip: String? = nil,
        edge: TooltipEdge = .top,
        isActive: Bool = false,
        action: @escaping () -> Void = {},
        onActionWithAnchorView: ((NSView?) -> Void)? = nil,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.tooltip = tooltip
        self.edge = edge
        self.isActive = isActive
        self.action = action
        self.onActionWithAnchorView = onActionWithAnchorView
        self.label = label
    }

    public var body: some View {
        Button {
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            if let onActionWithAnchorView {
                onActionWithAnchorView(anchorNSView)
            } else {
                action()
            }
        } label: {
            label()
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .background(
                    TooltipScreenRectProbe { v in
                        anchorNSView = v
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
            if hovering, let tooltip = tooltip, !tooltip.isEmpty,
               let v = anchorNSView, let win = v.window {
                let rectInWin = v.convert(v.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                SharedFloatingTooltipWindowController.shared.showTooltip(
                    text: tooltip,
                    edge: edge,
                    forButtonScreenRect: screenRect,
                    ownerView: v
                )
            } else {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .onDisappear {
            if isHovered {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
    }

    private var fillColor: Color {
        if isActive {
            return isHovered
                ? Color(red: 0.20, green: 0.18, blue: 0.34)
                : Color(red: 0.14, green: 0.13, blue: 0.24)
        }
        return isHovered ? Color.white.opacity(0.10) : Color.clear
    }

    private var borderColor: Color {
        if isActive {
            return Color(red: 0.50, green: 0.44, blue: 0.95).opacity(isHovered ? 0.55 : 0.35)
        }
        return Color.clear
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
        // Crucial: do NOT re-invoke `onViewReady` on every SwiftUI update, otherwise mutating `@State anchorNSView`
        // during `.onHover` triggers redundant SwiftUI body invalidations!
    }
}
