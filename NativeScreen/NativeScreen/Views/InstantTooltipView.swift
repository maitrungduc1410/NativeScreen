import SwiftUI

/// instant hover tooltip & button highlight modifier.
/// Places the speech-bubble tooltip cleanly outside the button's highlight border (zero overlap with the icon
/// and zero clipping against window edges!).
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
            label()
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: overlayAlignment) {
            if isHovered && !tooltip.isEmpty {
                InstantTooltipBubble(text: tooltip, edge: edge)
                    .fixedSize()
                    .alignmentGuide(horizontalAlignmentGuide) { d in
                        switch edge {
                        case .trailing:
                            // Place the left tip of the bubble 6pt to the RIGHT of the button's trailing edge
                            return d[.leading] - 6
                        case .leading:
                            // Place the right tip of the bubble 6pt to the LEFT of the button's leading edge
                            return d[.trailing] + 6
                        case .top, .bottom:
                            return d[HorizontalAlignment.center]
                        }
                    }
                    .alignmentGuide(verticalAlignmentGuide) { d in
                        switch edge {
                        case .top:
                            return d[.bottom] + 6
                        case .bottom:
                            return d[.top] - 6
                        case .leading, .trailing:
                            return d[VerticalAlignment.center]
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(999)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 200 : 1)
    }

    private var backgroundColor: Color {
        if isActive {
            return isHovered ? activeColor.opacity(0.95) : activeColor.opacity(0.80)
        }
        return isHovered ? Color.white.opacity(0.14) : Color.clear
    }

    private var overlayAlignment: Alignment {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private var horizontalAlignmentGuide: HorizontalAlignment {
        switch edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top, .bottom: return .center
        }
    }

    private var verticalAlignmentGuide: VerticalAlignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading, .trailing: return .center
        }
    }
}

public struct InstantTooltipBubble: View {
    let text: String
    let edge: TooltipEdge

    private let bubbleFill = Color(red: 0.14, green: 0.15, blue: 0.19)

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
        .shadow(color: .black.opacity(0.50), radius: 8, y: 3)
    }

    private var bubbleBox: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(bubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
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
