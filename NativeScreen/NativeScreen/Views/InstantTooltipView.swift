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
        activeColor: Color = Color(red: 0.45, green: 0.36, blue: 0.96),
        size: CGFloat = 32,
        cornerRadius: CGFloat = 8,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.tooltip = tooltip
        self.edge = edge
        self.isActive = isActive
        self.activeColor = activeColor
        self.size = size
        self.cornerRadius = cornerRadius
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                label()

                // Active dot indicator on the right side for active rail tabs (style)
                if isActive && edge == .leading {
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
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .center) {
            if isHovered && !tooltip.isEmpty {
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
        if isActive {
            return isHovered ? activeColor.opacity(0.95) : activeColor
        }
        return isHovered ? Color.white.opacity(0.14) : Color.clear
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
