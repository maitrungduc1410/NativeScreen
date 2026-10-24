import SwiftUI

/// instant hover tooltip & button highlight modifier.
/// Shows a dark speech-bubble tooltip with a pointer triangle immediately on mouse hover (zero OS delay!)
/// and smoothly highlights the button background.
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
                    .offset(x: tooltipOffsetX, y: tooltipOffsetY)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(999)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 100 : 1)
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

    private var tooltipOffsetX: CGFloat {
        switch edge {
        case .leading: return -(size + 8)
        case .trailing: return (size + 8)
        case .top, .bottom: return 0
        }
    }

    private var tooltipOffsetY: CGFloat {
        switch edge {
        case .top: return -(size + 6)
        case .bottom: return (size + 6)
        case .leading, .trailing: return 0
        }
    }
}

public struct InstantTooltipBubble: View {
    let text: String
    let edge: TooltipEdge

    public var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing {
                TooltipTriangle(direction: .left)
                    .fill(Color(red: 0.14, green: 0.15, blue: 0.19))
                    .frame(width: 6, height: 10)
            }

            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(red: 0.14, green: 0.15, blue: 0.19))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
                )

            if edge == .leading {
                TooltipTriangle(direction: .right)
                    .fill(Color(red: 0.14, green: 0.15, blue: 0.19))
                    .frame(width: 6, height: 10)
            }
        }
    }
}

private struct TooltipTriangle: Shape {
    enum Direction {
        case left
        case right
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
        }
        path.closeSubpath()
        return path
    }
}
