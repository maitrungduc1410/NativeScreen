import SwiftUI
import AppKit

/// instant hover tooltip & button highlight system:
/// 1. **Standalone Borderless `NSPanel` (`SharedFloatingTooltipWindowController`)**:
///    Every tooltip in the entire app (Editor window, Sub-Toolbar, Quick Dock, Inspector Rail, and Recording HUD)
///    is rendered inside a dedicated floating `NSPanel` above the window, so it **overflows outside the Editor window bounds**
///    whenever there is room on the monitor (`Split clip ⌥` overflowing left of the window edge!).
/// 2. **Smart Screen-Edge Clamping & Dynamic Anchor Shift**:
///    When the window/button is near the physical edge of the monitor, the tooltip bubble clamps inside the screen's
///    `visibleFrame` while its pointer arrow (`anchorOffset`) **dynamically shifts** to stay pointed at the exact center of the button!
/// 3. **Unified Single-Path Callout Shape (`UnifiedTooltipCalloutShape`)**:
///    Draws the rounded rectangle AND the rounded-tip pointer arrow as **one continuous closed `Path`** with smooth fillets,
///    so the fill and the `1px` inner border trace seamlessly around the entire bubble + arrow with zero seam!
public enum TooltipEdge: Sendable {
    case leading
    case trailing
    case top
    case bottom
}

// MARK: - 1. Shared Floating Tooltip `NSPanel` Controller (Used Everywhere in NativeScreen)

@MainActor
public final class SharedFloatingTooltipWindowController {
    public static let shared = SharedFloatingTooltipWindowController()

    private var tooltipPanel: NSPanel?
    private weak var activeOwnerView: NSView?

    private init() {}

    public func showTooltip(
        text: String,
        shortcutBadge: String? = nil,
        edge: TooltipEdge,
        forButtonScreenRect buttonRect: NSRect,
        ownerView: NSView? = nil
    ) {
        guard !text.isEmpty, buttonRect.width > 0, buttonRect.height > 0 else {
            hideTooltip()
            return
        }
        activeOwnerView = ownerView

        let shadowPad: CGFloat = 10.0

        // First measure intrinsic size with centered arrow (`anchorOffset = 0`)
        let measureHosting = NSHostingView(
            rootView: InstantTooltipBubble(
                text: text,
                shortcutBadge: shortcutBadge,
                edge: edge,
                anchorOffset: 0.0
            )
            .fixedSize()
            .padding(shadowPad)
        )
        let fitting = measureHosting.fittingSize
        let panelW = max(56.0, ceil(fitting.width))
        let panelH = max(32.0, ceil(fitting.height))
        let bubbleW = panelW - shadowPad * 2.0
        let bubbleH = panelH - shadowPad * 2.0

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonRect) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let screenMargin: CGFloat = 6.0
        let buttonGap: CGFloat = 5.0

        var panelOriginX: CGFloat = 0.0
        var panelOriginY: CGFloat = 0.0
        var anchorOffset: CGFloat = 0.0

        switch edge {
        case .top, .bottom:
            // Ideal horizontally-centered panel origin
            let idealX = round(buttonRect.midX - panelW * 0.5)
            // Clamp bubble inside the monitor's visibleFrame (`vf`), while allowing it to overflow outside the Editor `NSWindow`!
            let minPanelX = vf.minX + screenMargin - shadowPad
            let maxPanelX = vf.maxX - screenMargin - panelW + shadowPad
            panelOriginX = min(max(idealX, minPanelX), maxPanelX)

            // Compute exact horizontal shift so the arrow tip still points directly at `buttonRect.midX`
            let bubbleCenterOnScreenX = panelOriginX + panelW * 0.5
            let rawDeltaX = buttonRect.midX - bubbleCenterOnScreenX
            let maxArrowShiftX = max(0.0, bubbleW * 0.5 - 15.0)
            anchorOffset = min(max(rawDeltaX, -maxArrowShiftX), maxArrowShiftX)

            if edge == .top {
                // Arrow tip at bottom of bubble sits `buttonGap` above `buttonRect.maxY`
                panelOriginY = round(buttonRect.maxY + buttonGap - shadowPad)
            } else {
                // Arrow tip at top of bubble sits `buttonGap` below `buttonRect.minY`
                panelOriginY = round(buttonRect.minY - buttonGap - bubbleH - shadowPad)
            }

        case .leading, .trailing:
            // Ideal vertically-centered panel origin
            let idealY = round(buttonRect.midY - panelH * 0.5)
            let minPanelY = vf.minY + screenMargin - shadowPad
            let maxPanelY = vf.maxY - screenMargin - panelH + shadowPad
            panelOriginY = min(max(idealY, minPanelY), maxPanelY)

            let bubbleCenterOnScreenY = panelOriginY + panelH * 0.5
            // Note: SwiftUI Y increases downward while AppKit screen Y increases upward
            let rawDeltaY = bubbleCenterOnScreenY - buttonRect.midY
            let maxArrowShiftY = max(0.0, bubbleH * 0.5 - 11.0)
            anchorOffset = min(max(rawDeltaY, -maxArrowShiftY), maxArrowShiftY)

            if edge == .leading {
                // Bubble sits to the LEFT of the button (`buttonRect.minX`)
                panelOriginX = round(buttonRect.minX - buttonGap - bubbleW - shadowPad)
            } else {
                // Bubble sits to the RIGHT of the button (`buttonRect.maxX`)
                panelOriginX = round(buttonRect.maxX + buttonGap - shadowPad)
            }
        }

        if tooltipPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: panelOriginX, y: panelOriginY, width: panelW, height: panelH),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false // Shadow is rendered smoothly inside SwiftUI so WindowServer never draws a dark contour!
            panel.ignoresMouseEvents = true
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.tooltipPanel = panel
        }

        guard let panel = tooltipPanel else { return }

        let finalHosting = NSHostingView(
            rootView: InstantTooltipBubble(
                text: text,
                shortcutBadge: shortcutBadge,
                edge: edge,
                anchorOffset: anchorOffset
            )
            .fixedSize()
            .padding(shadowPad)
        )
        panel.contentView = finalHosting
        panel.setFrame(NSRect(x: panelOriginX, y: panelOriginY, width: panelW, height: panelH), display: true)
        panel.orderFrontRegardless()
    }

    public func hideTooltip(ifOwnedBy ownerView: NSView? = nil) {
        if let ownerView, let activeOwnerView, ownerView !== activeOwnerView {
            return
        }
        activeOwnerView = nil
        tooltipPanel?.orderOut(nil)
    }
}

// MARK: - 2. Unified Single-Path Callout Shape (Continuous Border + Rounded Pointer Tip!)

/// Draws the rounded rectangle bubble and its pointer arrow as a **single continuous closed `Path`**
/// with a softly rounded arrow tip (`tipRadius`) and smooth base corners (`baseRadius`),
/// seamless tooltip silhouette (Images 1–5).
public struct UnifiedTooltipCalloutShape: InsettableShape {
    public var edge: TooltipEdge
    public var cornerRadius: CGFloat
    public var arrowWidth: CGFloat
    public var arrowHeight: CGFloat
    public var anchorOffset: CGFloat
    public var insetAmount: CGFloat = 0.0

    public init(
        edge: TooltipEdge,
        cornerRadius: CGFloat = 8.5,
        arrowWidth: CGFloat = 11.0,
        arrowHeight: CGFloat = 5.2,
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

        let aw = arrowWidth
        let ah = arrowHeight
        let halfW = aw * 0.5
        let tipRound: CGFloat = 1.6

        // Compute the rectangular body box (excluding `arrowHeight` on the pointer side)
        let box: CGRect
        switch edge {
        case .top:
            // Bubble is ABOVE button -> arrow points DOWN from bottom edge
            box = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(4, rect.height - ah))
        case .bottom:
            // Bubble is BELOW button -> arrow points UP from top edge
            box = CGRect(x: rect.minX, y: rect.minY + ah, width: rect.width, height: max(4, rect.height - ah))
        case .leading:
            // Bubble is LEFT of button -> arrow points RIGHT from right edge
            box = CGRect(x: rect.minX, y: rect.minY, width: max(4, rect.width - ah), height: rect.height)
        case .trailing:
            // Bubble is RIGHT of button -> arrow points LEFT from left edge
            box = CGRect(x: rect.minX + ah, y: rect.minY, width: max(4, rect.width - ah), height: rect.height)
        }

        let r = min(cornerRadius - insetAmount * 0.5, min(box.width, box.height) * 0.45)

        let clampMinX = box.minX + r + halfW + 2.0
        let clampMaxX = box.maxX - r - halfW - 2.0
        let arrowCenterX = min(max(box.midX + anchorOffset, clampMinX), max(clampMinX, clampMaxX))

        let clampMinY = box.minY + r + halfW + 2.0
        let clampMaxY = box.maxY - r - halfW - 2.0
        let arrowCenterY = min(max(box.midY + anchorOffset, clampMinY), max(clampMinY, clampMaxY))

        var p = Path()

        // Start at Top-Left after corner curve, tracing clockwise:
        p.move(to: CGPoint(x: box.minX + r, y: box.minY))

        // 1. TOP EDGE (with upward arrow if `edge == .bottom`)
        if edge == .bottom {
            let leftBase = CGPoint(x: arrowCenterX - halfW, y: box.minY)
            let tip = CGPoint(x: arrowCenterX, y: box.minY - ah)
            let rightBase = CGPoint(x: arrowCenterX + halfW, y: box.minY)

            p.addLine(to: CGPoint(x: leftBase.x - 1.5, y: box.minY))
            p.addQuadCurve(to: CGPoint(x: leftBase.x + 1.2, y: box.minY - 1.1), control: leftBase)
            p.addLine(to: CGPoint(x: tip.x - tipRound, y: tip.y + tipRound * 0.85))
            p.addQuadCurve(to: CGPoint(x: tip.x + tipRound, y: tip.y + tipRound * 0.85), control: tip)
            p.addLine(to: CGPoint(x: rightBase.x - 1.2, y: box.minY - 1.1))
            p.addQuadCurve(to: CGPoint(x: rightBase.x + 1.5, y: box.minY), control: rightBase)
        }
        p.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))

        // Top-Right Corner
        p.addArc(
            center: CGPoint(x: box.maxX - r, y: box.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // 2. RIGHT EDGE (with rightward arrow if `edge == .leading`)
        if edge == .leading {
            let topBase = CGPoint(x: box.maxX, y: arrowCenterY - halfW)
            let tip = CGPoint(x: box.maxX + ah, y: arrowCenterY)
            let bottomBase = CGPoint(x: box.maxX, y: arrowCenterY + halfW)

            p.addLine(to: CGPoint(x: box.maxX, y: topBase.y - 1.5))
            p.addQuadCurve(to: CGPoint(x: box.maxX + 1.1, y: topBase.y + 1.2), control: topBase)
            p.addLine(to: CGPoint(x: tip.x - tipRound * 0.85, y: tip.y - tipRound))
            p.addQuadCurve(to: CGPoint(x: tip.x - tipRound * 0.85, y: tip.y + tipRound), control: tip)
            p.addLine(to: CGPoint(x: box.maxX + 1.1, y: bottomBase.y - 1.2))
            p.addQuadCurve(to: CGPoint(x: box.maxX, y: bottomBase.y + 1.5), control: bottomBase)
        }
        p.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))

        // Bottom-Right Corner
        p.addArc(
            center: CGPoint(x: box.maxX - r, y: box.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // 3. BOTTOM EDGE (with downward arrow if `edge == .top`)
        if edge == .top {
            let rightBase = CGPoint(x: arrowCenterX + halfW, y: box.maxY)
            let tip = CGPoint(x: arrowCenterX, y: box.maxY + ah)
            let leftBase = CGPoint(x: arrowCenterX - halfW, y: box.maxY)

            p.addLine(to: CGPoint(x: rightBase.x + 1.5, y: box.maxY))
            p.addQuadCurve(to: CGPoint(x: rightBase.x - 1.2, y: box.maxY + 1.1), control: rightBase)
            p.addLine(to: CGPoint(x: tip.x + tipRound, y: tip.y - tipRound * 0.85))
            p.addQuadCurve(to: CGPoint(x: tip.x - tipRound, y: tip.y - tipRound * 0.85), control: tip)
            p.addLine(to: CGPoint(x: leftBase.x + 1.2, y: box.maxY + 1.1))
            p.addQuadCurve(to: CGPoint(x: leftBase.x - 1.5, y: box.maxY), control: leftBase)
        }
        p.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))

        // Bottom-Left Corner
        p.addArc(
            center: CGPoint(x: box.minX + r, y: box.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // 4. LEFT EDGE (with leftward arrow if `edge == .trailing`)
        if edge == .trailing {
            let bottomBase = CGPoint(x: box.minX, y: arrowCenterY + halfW)
            let tip = CGPoint(x: box.minX - ah, y: arrowCenterY)
            let topBase = CGPoint(x: box.minX, y: arrowCenterY - halfW)

            p.addLine(to: CGPoint(x: box.minX, y: bottomBase.y + 1.5))
            p.addQuadCurve(to: CGPoint(x: box.minX - 1.1, y: bottomBase.y - 1.2), control: bottomBase)
            p.addLine(to: CGPoint(x: tip.x + tipRound * 0.85, y: tip.y + tipRound))
            p.addQuadCurve(to: CGPoint(x: tip.x + tipRound * 0.85, y: tip.y - tipRound), control: tip)
            p.addLine(to: CGPoint(x: box.minX - 1.1, y: topBase.y + 1.2))
            p.addQuadCurve(to: CGPoint(x: box.minX, y: topBase.y - 1.5), control: topBase)
        }
        p.addLine(to: CGPoint(x: box.minX, y: box.minY + r))

        // Top-Left Corner
        p.addArc(
            center: CGPoint(x: box.minX + r, y: box.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        p.closeSubpath()
        return p
    }
}

// MARK: - 3. Unified InstantTooltipBubble View (With Optional Keyboard Shortcut Keycap Badge!)

public struct InstantTooltipBubble: View {
    public let text: String
    public let shortcutBadge: String?
    public let edge: TooltipEdge
    public let anchorOffset: CGFloat

    private let bubbleFill = Color(red: 0.14, green: 0.15, blue: 0.19)
    private let borderStroke = Color.white.opacity(0.16)
    private let arrowHeight: CGFloat = 5.2

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
        let calloutShape = UnifiedTooltipCalloutShape(
            edge: edge,
            cornerRadius: 8.5,
            arrowWidth: 11.0,
            arrowHeight: arrowHeight,
            anchorOffset: anchorOffset
        )

        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let badge = shortcutBadge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6.5)
        .padding(.top, edge == .bottom ? arrowHeight : 0)
        .padding(.bottom, edge == .top ? arrowHeight : 0)
        .padding(.leading, edge == .trailing ? arrowHeight : 0)
        .padding(.trailing, edge == .leading ? arrowHeight : 0)
        .background(
            calloutShape
                .fill(bubbleFill)
        )
        .overlay(
            calloutShape
                .strokeBorder(borderStroke, lineWidth: 1.0)
        )
        .shadow(color: .black.opacity(0.48), radius: 7, y: 2.5)
    }

    /// Automatically extracts trailing shortcuts like `"Undo (⌘Z)"` -> `("Undo", "⌘Z")` or `"Split clip (⌥)"` -> `("Split clip", "⌥")`
    /// so every tooltip with a shortcut renders a sleek keycap badge (Images 4 & 5)!
    private static func extractTrailingParenthesizedShortcut(
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

                // Active dot indicator on the right side for active rail tabs (style)
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
            withAnimation(.easeOut(duration: 0.10)) {
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
                // Inspector sidebar tab active style (subtle dark card with glowing icon + purple dot)
                return isHovered ? Color.white.opacity(0.14) : Color.white.opacity(0.09)
            }
            // Active tool button style (dark purple pill background when Split Clip is active!)
            return isHovered ? activeColor.opacity(0.38) : activeColor.opacity(0.28)
        }
        return isHovered ? Color.white.opacity(0.12) : Color.clear
    }
}

/// Pill Button with generous hitbox (`height: 30`), smooth hover highlight,
/// active purple state (like `Reel mode`), and standalone floating tooltip!
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
            withAnimation(.easeOut(duration: 0.12)) {
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
        DispatchQueue.main.async { onViewReady(nsView) }
    }
}
