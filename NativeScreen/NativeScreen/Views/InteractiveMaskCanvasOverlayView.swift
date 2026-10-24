import SwiftUI

/// Interactive overlay placed directly above the `MTKView` preview canvas so users can drag and resize
/// multiple simultaneous Blur / Pixelate / Spotlight Masks in real time.
public struct InteractiveMaskCanvasOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    @State private var dragInitialRect: Rect01?

    public var body: some View {
        let srcMs = session.currentSourceTimeMs
        let activeMasks = session.activeMasks(atSourceMs: srcMs)
        let screenRect = calculateScreenRect(in: canvasSize)

        ZStack(alignment: .topLeading) {
            ForEach(activeMasks) { mask in
                let rect01 = mask.interpolatedRect(at: srcMs)
                let boxX = screenRect.minX + CGFloat(rect01.x) * screenRect.width
                let boxY = screenRect.minY + CGFloat(rect01.y) * screenRect.height
                let boxW = max(24.0, CGFloat(rect01.width) * screenRect.width)
                let boxH = max(24.0, CGFloat(rect01.height) * screenRect.height)
                let isSelected = (session.selectedMaskId == mask.id)

                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.teal : Color.white.opacity(0.55),
                            style: StrokeStyle(lineWidth: isSelected ? 2.0 : 1.2, dash: isSelected ? [] : [5, 3])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.teal.opacity(isSelected ? 0.12 : 0.03))
                        )
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                Image(systemName: mask.type == .blur ? "eye.slash.fill" : "flashlight.on.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text(mask.style.rawValue.capitalized)
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.85), in: Capsule())
                            .padding(5)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            session.selectedMaskId = mask.id
                            session.selectedInspectorTab = .masks
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    session.selectedMaskId = mask.id
                                    if dragInitialRect == nil {
                                        session.beginInteractiveEdit()
                                        dragInitialRect = rect01
                                    }
                                    guard let start = dragInitialRect else { return }
                                    let dx01 = Double(value.translation.width / max(1.0, screenRect.width))
                                    let dy01 = Double(value.translation.height / max(1.0, screenRect.height))
                                    let updated = Rect01(
                                        x: start.x + dx01,
                                        y: start.y + dy01,
                                        width: start.width,
                                        height: start.height
                                    ).clamped()
                                    session.updateMaskRect(maskId: mask.id, newRect01: updated, atSourceMs: srcMs)
                                }
                                .onEnded { _ in
                                    dragInitialRect = nil
                                    session.endInteractiveEdit()
                                }
                        )

                    // Bottom-Right Resize Handle
                    Circle()
                        .fill(Color.teal)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 5, y: 5)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    session.selectedMaskId = mask.id
                                    if dragInitialRect == nil {
                                        session.beginInteractiveEdit()
                                        dragInitialRect = rect01
                                    }
                                    guard let start = dragInitialRect else { return }
                                    let dw01 = Double(value.translation.width / max(1.0, screenRect.width))
                                    let dh01 = Double(value.translation.height / max(1.0, screenRect.height))
                                    let updated = Rect01(
                                        x: start.x,
                                        y: start.y,
                                        width: max(0.04, start.width + dw01),
                                        height: max(0.04, start.height + dh01)
                                    ).clamped()
                                    session.updateMaskRect(maskId: mask.id, newRect01: updated, atSourceMs: srcMs)
                                }
                                .onEnded { _ in
                                    dragInitialRect = nil
                                    session.endInteractiveEdit()
                                }
                        )
                }
                .frame(width: boxW, height: boxH)
                .position(x: boxX + boxW * 0.5, y: boxY + boxH * 0.5)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func calculateScreenRect(in size: CGSize) -> CGRect {
        let padding = CGFloat(session.document.canvas.paddingRatio)
        let insetX = size.width * min(0.42, max(0.0, padding))
        let insetY = size.height * min(0.42, max(0.0, padding))
        let available = CGRect(origin: .zero, size: size).insetBy(dx: insetX, dy: insetY)

        let sourceW = CGFloat(max(640, session.metadata.captureTarget.pixelSize.width))
        let sourceH = CGFloat(max(400, session.metadata.captureTarget.pixelSize.height))
        let aspect = sourceW / sourceH

        var w = available.width
        var h = w / aspect
        if h > available.height {
            h = available.height
            w = h * aspect
        }
        return CGRect(
            x: size.width * 0.5 - w * 0.5,
            y: size.height * 0.5 - h * 0.5,
            width: w,
            height: h
        )
    }
}
