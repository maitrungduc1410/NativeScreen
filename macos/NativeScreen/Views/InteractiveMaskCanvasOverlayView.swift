import SwiftUI
import AppKit

/// Clean, zero-jitter interactive mask handle & drag-to-create overlay on the Preview Canvas.
/// - Masks are created and edited under the zoom on screen: staying zoomed in is what makes small text easy to hit.
/// - In Add-Mask mode (`pendingAddMaskType != nil`), the cursor changes to `NSCursor.crosshair` **only inside the actual video area**
///   (`transform.screenFrameRect`), reverting to `NSCursor.arrow` over the outer background padding!
public struct InteractiveMaskCanvasOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    @State private var dragStartRect01: Rect01?
    @State private var hoveredMaskId: String?
    @State private var newMaskDragStartPt: CGPoint?
    @State private var newMaskDragCurrentPt: CGPoint?

    private let purpleAccent = Color(red: 0.302, green: 0.184, blue: 0.961) // `#4D2FF5`

    public init(session: ProjectSession, canvasSize: CGSize) {
        self.session = session
        self.canvasSize = canvasSize
    }

    public var body: some View {

        ZStack(alignment: .topLeading) {
            // Clicking empty preview canvas deselects any active mask (or cancels add-mask mode)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if session.pendingAddMaskType != nil {
                        session.cancelInteractiveMaskSelection()
                    } else {
                        session.selectedMaskId = nil
                        session.selectedAnnotationId = nil
                        session.selectedInspectorTab = .background
                    }
                }
                .accessibilityHidden(true)

            if !session.isPlaying {
                // Only read while paused: during playback the handles are hidden, and reading the playhead here
                // would re-evaluate this overlay on every frame.
                let srcMs = session.currentSourceTimeMs
                let activeMasks = session.activeMasks(atSourceMs: srcMs)
                let camera = session.evaluatedCamera(atSourceMs: srcMs)
                let crop = session.document.canvas.cropRect01
                let stage = MetalFrameCompositor.resolvedStageLayout(
                    session: session,
                    sourceTimeMs: srcMs,
                    canvasRect: CGRect(origin: .zero, size: canvasSize),
                    screenSourceSize: CGSize(
                        width: max(16.0, CGFloat(max(640, session.metadata.captureTarget.pixelSize.width)) * CGFloat(crop.width)),
                        height: max(16.0, CGFloat(max(400, session.metadata.captureTarget.pixelSize.height)) * CGFloat(crop.height))
                    ),
                    zoomScale: camera.scale
                )
                let transform = CanvasCoordinateTransform(
                    canvasSize: canvasSize,
                    screenRectBottomLeft: stage.screenRect,
                    cropRect01: crop,
                    cameraCenter01: camera.center01,
                    cameraScale: camera.scale
                )
                let videoRect = transform.visibleScreenRect
                // 1. Existing Mask Interactive Handles
                ForEach(activeMasks) { mask in
                    let rect01 = mask.interpolatedRect(at: srcMs)
                    let mappedRect = transform.canvasRect(fromSourceRect01: rect01)
                    let boxW = max(16.0, mappedRect.width)
                    let boxH = max(16.0, mappedRect.height)
                    let isSelected = (session.selectedMaskId == mask.id)
                    let isHovered = (hoveredMaskId == mask.id)

                    ZStack {
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
                            .accessibleButton(mask.type == .blur ? "Sensitive data mask" : "Highlight mask", isSelected: isSelected) {
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

                // 2. Interactive Drag-to-Select New Mask Overlay
                //    Scoped strictly to `videoRect` (`transform.visibleScreenRect`), so `NSCursor.crosshair` ONLY activates
                //    over the actual recorded video area and reverts to `NSCursor.arrow` over the background padding!
                if let pendingMaskType = session.pendingAddMaskType, videoRect.width > 10, videoRect.height > 10 {
                    ZStack(alignment: .topLeading) {
                        Color.white.opacity(0.001)

                        if let sPt = newMaskDragStartPt, let cPt = newMaskDragCurrentPt {
                            let minX = max(0, min(videoRect.width, min(sPt.x, cPt.x)))
                            let minY = max(0, min(videoRect.height, min(sPt.y, cPt.y)))
                            let maxX = max(0, min(videoRect.width, max(sPt.x, cPt.x)))
                            let maxY = max(0, min(videoRect.height, max(sPt.y, cPt.y)))
                            let selW = max(2, maxX - minX)
                            let selH = max(2, maxY - minY)

                            ZStack {
                                Rectangle()
                                    .fill(purpleAccent.opacity(0.16))

                                Rectangle()
                                    .strokeBorder(
                                        purpleAccent.opacity(0.95),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                                    )
                            }
                            .frame(width: selW, height: selH)
                            .offset(x: minX, y: minY)
                            .allowsHitTesting(false)
                        } else {
                            // Bottom instruction pill (`Drag to select the area for the new ...`)
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text(pendingMaskType == .blur ? "Drag to select the area for the new sensitive data mask" : "Drag to select the area for the new highlight mask")
                                        .font(.system(size: 12.5, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.black.opacity(0.72))
                                        )
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                        )
                                    Spacer()
                                }
                                .padding(.bottom, 16)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: videoRect.width, height: videoRect.height)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active:
                            NSCursor.crosshair.set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                NSCursor.crosshair.set()
                                if newMaskDragStartPt == nil {
                                    newMaskDragStartPt = value.startLocation
                                }
                                newMaskDragCurrentPt = value.location
                            }
                            .onEnded { value in
                                let startLocal = newMaskDragStartPt ?? value.startLocation
                                let endLocal = value.location
                                newMaskDragStartPt = nil
                                newMaskDragCurrentPt = nil

                                let clampedStartX = max(0, min(videoRect.width, startLocal.x))
                                let clampedStartY = max(0, min(videoRect.height, startLocal.y))
                                let clampedEndX = max(0, min(videoRect.width, endLocal.x))
                                let clampedEndY = max(0, min(videoRect.height, endLocal.y))

                                let dragW = abs(clampedEndX - clampedStartX)
                                let dragH = abs(clampedEndY - clampedStartY)

                                let crop = session.document.canvas.cropRect01
                                let finalRect01: Rect01

                                if dragW >= 6.0 && dragH >= 6.0 {
                                    let topLeft = transform.sourcePoint01(fromCanvasPoint: CGPoint(
                                        x: videoRect.minX + min(clampedStartX, clampedEndX),
                                        y: videoRect.minY + min(clampedStartY, clampedEndY)
                                    ))
                                    let bottomRight = transform.sourcePoint01(fromCanvasPoint: CGPoint(
                                        x: videoRect.minX + max(clampedStartX, clampedEndX),
                                        y: videoRect.minY + max(clampedStartY, clampedEndY)
                                    ))
                                    finalRect01 = Rect01(
                                        x: topLeft.x,
                                        y: topLeft.y,
                                        width: bottomRight.x - topLeft.x,
                                        height: bottomRight.y - topLeft.y
                                    ).clamped()
                                } else {
                                    // Single click without drag -> place a default 28% × 14% mask centered at click point
                                    let click = transform.sourcePoint01(fromCanvasPoint: CGPoint(
                                        x: videoRect.minX + clampedEndX,
                                        y: videoRect.minY + clampedEndY
                                    ))
                                    let srcX = click.x
                                    let srcY = click.y
                                    let defW = min(0.28, crop.width)
                                    let defH = min(0.14, crop.height)
                                    finalRect01 = Rect01(
                                        x: max(crop.x, min(crop.x + crop.width - defW, srcX - defW * 0.5)),
                                        y: max(crop.y, min(crop.y + crop.height - defH, srcY - defH * 0.5)),
                                        width: defW,
                                        height: defH
                                    ).clamped()
                                }

                                session.completeInteractiveMaskSelection(rect01: finalRect01)
                            }
                    )
                    .offset(x: videoRect.minX, y: videoRect.minY)
                    .zIndex(80)
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
