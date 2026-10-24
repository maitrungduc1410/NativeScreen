import SwiftUI
import AppKit

/// Clean, zero-jitter interactive mask handle overlay on the Preview Canvas.
/// - Uses `CanvasCoordinateTransform` so mask handles move and scale with the Virtual Camera Zoom & Pan.
/// - Solid subtle border (no dashed lines!) when hovered or selected.
/// - Displays zero text badges on the preview canvas.
public struct InteractiveMaskCanvasOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    @State private var dragStartRect01: Rect01?
    @State private var hoveredMaskId: String?

    public init(session: ProjectSession, canvasSize: CGSize) {
        self.session = session
        self.canvasSize = canvasSize
    }

    public var body: some View {
        let srcMs = session.currentSourceTimeMs
        let activeMasks = session.activeMasks(atSourceMs: srcMs)
        let eval = session.trajectorySolver.evaluate(atSourceMs: srcMs)
        let transform = CanvasCoordinateTransform(
            canvasSize: canvasSize,
            sourcePixelSize: CGSize(
                width: max(640, session.metadata.captureTarget.pixelSize.width),
                height: max(400, session.metadata.captureTarget.pixelSize.height)
            ),
            paddingRatio: session.document.canvas.paddingRatio,
            cropRect01: session.document.canvas.cropRect01,
            cameraCenter01: eval.camera.isLoupeMode ? .center : eval.camera.center01,
            cameraScale: eval.camera.isLoupeMode ? 1.0 : eval.camera.scale
        )

        ZStack(alignment: .topLeading) {
            // Clicking empty canvas deselects mask
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    session.selectedMaskId = nil
                }

            if !session.isPlaying {
                ForEach(activeMasks) { mask in
                    let rect01 = mask.interpolatedRect(at: srcMs)
                    let mappedRect = transform.canvasRect(fromSourceRect01: rect01)
                    let boxW = max(16.0, mappedRect.width)
                    let boxH = max(16.0, mappedRect.height)
                    let isSelected = (session.selectedMaskId == mask.id)
                    let isHovered = (hoveredMaskId == mask.id)

                    ZStack {
                        // Zero outline around the mask body — only an invisible hit-testing rectangle for dragging
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    if hovering {
                                        hoveredMaskId = mask.id
                                    } else if hoveredMaskId == mask.id {
                                        hoveredMaskId = nil
                                    }
                                }
                            }
                            .onTapGesture {
                                session.selectMask(mask.id)
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("previewCanvasSpace"))
                                    .onChanged { value in
                                        if session.selectedMaskId != mask.id {
                                            session.selectMask(mask.id)
                                        }
                                        if dragStartRect01 == nil {
                                            session.beginInteractiveEdit()
                                            dragStartRect01 = rect01
                                        }
                                        guard let start = dragStartRect01 else { return }
                                        let delta01 = transform.sourceDelta01(fromCanvasDelta: value.translation)
                                        let updated = Rect01(
                                            x: start.x + delta01.x,
                                            y: start.y + delta01.y,
                                            width: start.width,
                                            height: start.height
                                        ).clamped()
                                        session.updateMaskRect(maskId: mask.id, newRect01: updated, atSourceMs: srcMs)
                                    }
                                    .onEnded { _ in
                                        dragStartRect01 = nil
                                        session.endInteractiveEdit()
                                    }
                            )

                        // 4 Corner Resize Handles (Smooth fade in/out when selected or hovered)
                        Group {
                            cornerHandle(
                                maskId: mask.id,
                                currentRect01: rect01,
                                transform: transform,
                                srcMs: srcMs,
                                xSign: -1,
                                ySign: -1
                            )
                            .position(x: 0, y: 0)

                            cornerHandle(
                                maskId: mask.id,
                                currentRect01: rect01,
                                transform: transform,
                                srcMs: srcMs,
                                xSign: 1,
                                ySign: -1
                            )
                            .position(x: boxW, y: 0)

                            cornerHandle(
                                maskId: mask.id,
                                currentRect01: rect01,
                                transform: transform,
                                srcMs: srcMs,
                                xSign: -1,
                                ySign: 1
                            )
                            .position(x: 0, y: boxH)

                            cornerHandle(
                                maskId: mask.id,
                                currentRect01: rect01,
                                transform: transform,
                                srcMs: srcMs,
                                xSign: 1,
                                ySign: 1
                            )
                            .position(x: boxW, y: boxH)
                        }
                        .opacity(isSelected || isHovered ? 1.0 : 0.0)
                        .animation(.easeOut(duration: 0.14), value: isSelected || isHovered)
                    }
                    .frame(width: boxW, height: boxH)
                    .position(x: mappedRect.minX + boxW * 0.5, y: mappedRect.minY + boxH * 0.5)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: "previewCanvasSpace")
    }

    @ViewBuilder
    private func cornerHandle(
        maskId: String,
        currentRect01: Rect01,
        transform: CanvasCoordinateTransform,
        srcMs: Double,
        xSign: Int,
        ySign: Int
    ) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.indigo, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("previewCanvasSpace"))
                    .onChanged { value in
                        if dragStartRect01 == nil {
                            session.beginInteractiveEdit()
                            dragStartRect01 = currentRect01
                        }
                        guard let start = dragStartRect01 else { return }
                        let delta01 = transform.sourceDelta01(fromCanvasDelta: value.translation)

                        var newX = start.x
                        var newY = start.y
                        var newW = start.width
                        var newH = start.height

                        if xSign < 0 {
                            let maxDx = start.width - 0.03
                            let dx = min(maxDx, delta01.x)
                            newX = start.x + dx
                            newW = start.width - dx
                        } else {
                            newW = max(0.03, start.width + delta01.x)
                        }

                        if ySign < 0 {
                            let maxDy = start.height - 0.03
                            let dy = min(maxDy, delta01.y)
                            newY = start.y + dy
                            newH = start.height - dy
                        } else {
                            newH = max(0.03, start.height + delta01.y)
                        }

                        let updated = Rect01(x: newX, y: newY, width: newW, height: newH).clamped()
                        session.updateMaskRect(maskId: maskId, newRect01: updated, atSourceMs: srcMs)
                    }
                    .onEnded { _ in
                        dragStartRect01 = nil
                        session.endInteractiveEdit()
                    }
            )
    }
}
