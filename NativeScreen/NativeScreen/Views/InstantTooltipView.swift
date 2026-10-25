import SwiftUI

/// instant hover tooltip & button highlight modifier.
/// Uses explicit geometric offset (`(buttonSize + bubbleSize) * 0.5 + gap`) on a centered `.overlay`
/// so the tooltip's pointer tip ALWAYS sits cleanly outside the button's highlight border on all 4 edges!
public enum TooltipEdge: Sendable {
    case leading
    case trailing
    case top
    case bottom
}

public struct InstantTooltipButton<LabelContent: View>: View {
    let tooltip: String
    let edge: TooltipEdge
    let isActive: Bool
    let isDisabled: Bool
    let activeColor: Color
    let size: CGFloat
    let cornerRadius: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent

    @State private var isHovered = false
    @State private var bubbleSize: CGSize = CGSize(width: 90, height: 28)

    public init(
        tooltip: String,
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
                            .fill(Color(red: 0.60, green: 0.50, blue: 1.0))
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
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = isDisabled ? false : hovering
            }
        }
        .onChange(of: isDisabled) { _, disabled in
            if disabled && isHovered {
                isHovered = false
            }
        }
        .overlay(alignment: .center) {
            if isHovered && !isDisabled && !tooltip.isEmpty {
                InstantTooltipBubble(text: tooltip, edge: edge)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    bubbleSize = geo.size
                                }
                                .onChange(of: geo.size) { _, newSize in
                                    bubbleSize = newSize
                                }
                        }
                    )
                    .offset(x: computedOffsetX, y: computedOffsetY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(999)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 500 : 1)
    }

    private var computedOffsetX: CGFloat {
        let gap: CGFloat = 6.0
        switch edge {
        case .leading:
            // Move left by half the button width + half the bubble width + gap
            return -((size * 0.5) + (bubbleSize.width * 0.5) + gap)
        case .trailing:
            // Move right by half the button width + half the bubble width + gap
            return (size * 0.5) + (bubbleSize.width * 0.5) + gap
        case .top, .bottom:
            return 0.0
        }
    }

    private var computedOffsetY: CGFloat {
        let gap: CGFloat = 6.0
        switch edge {
        case .top:
            return -((size * 0.5) + (bubbleSize.height * 0.5) + gap)
        case .bottom:
            return (size * 0.5) + (bubbleSize.height * 0.5) + gap
        case .leading, .trailing:
            return 0.0
        }
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.clear
        }
        if isActive {
            return isHovered ? activeColor.opacity(0.95) : activeColor
        }
        return isHovered ? Color.white.opacity(0.14) : Color.clear
    }
}

/// Pill Button with generous hitbox (`height: 30`), smooth hover highlight,
/// active purple state (like `Reel mode` in), and optional instant hover tooltip!
public struct SubToolbarPillButton<LabelContent: View>: View {
    let tooltip: String?
    let edge: TooltipEdge
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent

    @State private var isHovered = false
    @State private var buttonSize: CGSize = CGSize(width: 96, height: 30)
    @State private var bubbleSize: CGSize = CGSize(width: 120, height: 28)

    public init(
        tooltip: String? = nil,
        edge: TooltipEdge = .top,
        isActive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.tooltip = tooltip
        self.edge = edge
        self.isActive = isActive
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(fillColor)
                            .onAppear { buttonSize = geo.size }
                            .onChange(of: geo.size) { _, s in buttonSize = s }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .center) {
            if isHovered, let tooltip = tooltip, !tooltip.isEmpty {
                InstantTooltipBubble(text: tooltip, edge: edge)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { bubbleSize = geo.size }
                                .onChange(of: geo.size) { _, s in bubbleSize = s }
                        }
                    )
                    .offset(
                        x: 0,
                        y: edge == .top
                            ? -((buttonSize.height * 0.5) + (bubbleSize.height * 0.5) + 6)
                            : ((buttonSize.height * 0.5) + (bubbleSize.height * 0.5) + 6)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(999)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 500 : 1)
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

public struct InstantTooltipBubble: View {
    let text: String
    let edge: TooltipEdge

    private let bubbleFill = Color(red: 0.14, green: 0.15, blue: 0.19)
    private let borderStroke = Color.white.opacity(0.15)

    public var body: some View {
        Group {
            switch edge {
            case .trailing:
                HStack(spacing: -1) {
                    TooltipPointerTriangle(direction: .left)
                        .fill(bubbleFill)
                        .frame(width: 6, height: 11)
                    bubbleBox
                }
            case .leading:
                HStack(spacing: -1) {
                    bubbleBox
                    TooltipPointerTriangle(direction: .right)
                        .fill(bubbleFill)
                        .frame(width: 6, height: 11)
                }
            case .top:
                VStack(spacing: -1) {
                    bubbleBox
                    TooltipPointerTriangle(direction: .down)
                        .fill(bubbleFill)
                        .frame(width: 11, height: 6)
                }
            case .bottom:
                VStack(spacing: -1) {
                    TooltipPointerTriangle(direction: .up)
                        .fill(bubbleFill)
                        .frame(width: 11, height: 6)
                    bubbleBox
                }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
    }

    private var bubbleBox: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(bubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderStroke, lineWidth: 0.8)
            )
    }
}

private struct TooltipPointerTriangle: Shape {
    enum Direction {
        case left, right, up, down
    }
    let direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .up:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .down:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}
