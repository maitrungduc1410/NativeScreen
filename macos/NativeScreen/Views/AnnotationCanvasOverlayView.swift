import SwiftUI
import AppKit

/// Handles for annotations on the preview canvas. Only the annotations themselves take clicks, so the masks, captions
/// and keycaps underneath keep theirs. Positions come from `AnnotationRenderer` and the compositor's crop, layout and
/// zoom (`ProjectSession.canvasTransform`), so a handle sits on what is drawn.
struct AnnotationCanvasOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    /// The item being dragged, as it was when the drag started.
    @State private var dragStart: DragStart?
    @FocusState private var isTextFieldFocused: Bool

    private struct DragStart {
        let id: String
        let item: AnnotationItem
        let center: CGPoint
        let from: CGPoint
        let to: CGPoint
        let size: CGSize
        let cornerDistance: CGFloat
    }

    private let accent = Color(red: 0.302, green: 0.184, blue: 0.961)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !session.isPlaying {
                // Read only while paused, as the mask handles do: during playback the handles are hidden.
                let srcMs = session.currentSourceTimeMs
                let items = session.activeAnnotations(atSourceMs: srcMs)
                if !items.isEmpty {
                    let transform = session.canvasTransform(atSourceMs: srcMs, canvasSize: canvasSize)
                    // Bottom layer first, so the top layer takes the click where items overlap.
                    ForEach(items) { item in
                        if item.kind == .arrow {
                            arrowHandles(item, transform: transform)
                        } else {
                            boxHandles(item, transform: transform)
                        }
                    }
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .coordinateSpace(name: "annotationCanvasSpace")
        .onChange(of: session.selectedAnnotationId) { _, newId in
            if session.editingAnnotationTextId != nil && session.editingAnnotationTextId != newId {
                endTextEditing()
            }
        }
        .onChange(of: session.isPlaying) { _, playing in
            if playing { endTextEditing() }
        }
    }

    // MARK: Coordinates

    private func toCanvas(_ p: Point01, _ item: AnnotationItem, _ transform: CanvasCoordinateTransform) -> CGPoint {
        switch item.anchor {
        case .screen: return transform.canvasPoint(fromSource01: p)
        case .canvas: return CGPoint(x: CGFloat(p.x) * canvasSize.width, y: CGFloat(p.y) * canvasSize.height)
        }
    }

    private func fromCanvas(_ c: CGPoint, _ item: AnnotationItem, _ transform: CanvasCoordinateTransform) -> Point01 {
        let p: Point01
        switch item.anchor {
        case .screen: p = transform.sourcePoint01(fromCanvasPoint: c)
        case .canvas: p = Point01(x: Double(c.x / max(1, canvasSize.width)), y: Double(c.y / max(1, canvasSize.height)))
        }
        return Point01(x: min(1.0, max(0.0, p.x)), y: min(1.0, max(0.0, p.y)))
    }

    /// Canvas points per unit of the item's coordinates, horizontally and vertically.
    private func pointsPerUnit(_ item: AnnotationItem, _ transform: CanvasCoordinateTransform) -> CGSize {
        let c = toCanvas(item.position01, item, transform)
        let dx = toCanvas(Point01(x: item.position01.x + 0.1, y: item.position01.y), item, transform)
        let dy = toCanvas(Point01(x: item.position01.x, y: item.position01.y + 0.1), item, transform)
        return CGSize(width: max(0.001, hypot(dx.x - c.x, dx.y - c.y) / 0.1), height: max(0.001, hypot(dy.x - c.x, dy.y - c.y) / 0.1))
    }

    private func boxSize(_ item: AnnotationItem, _ transform: CanvasCoordinateTransform) -> CGSize {
        if item.kind.isShape {
            let half = AnnotationRenderer.shapeHalfSize(for: item) { toCanvas($0, item, transform) }
            return CGSize(width: half.width * 2, height: half.height * 2)
        }
        return AnnotationRenderer.boxSize(for: item, canvasSize: canvasSize, packageURL: session.packageURL)
    }

    /// Geometry edits go to the keyframe at the playhead when the item has keyframes.
    private func editGeometry(_ item: AnnotationItem, _ change: (inout AnnotationItem) -> Void) {
        session.editAnnotationGeometry(id: item.id, atSourceMs: session.currentSourceTimeMs, change)
    }

    /// `point`, moved onto a click recorded around the item's time when one is within 12 points. Only items pinned to
    /// the screen snap: a click is a place in the recording.
    private func snapped(_ point: CGPoint, _ item: AnnotationItem, _ transform: CanvasCoordinateTransform) -> CGPoint {
        guard item.anchor == .screen else { return point }
        var best: (distance: CGFloat, point: CGPoint)?
        for click in session.recordedClicks(from: item.sourceStartMs - 1000, to: item.sourceEndMs + 1000) {
            let c = transform.canvasPoint(fromSource01: click)
            let d = hypot(c.x - point.x, c.y - point.y)
            if d < 12, d < (best?.distance ?? .infinity) { best = (d, c) }
        }
        return best?.point ?? point
    }

    private func beginDrag(_ item: AnnotationItem, _ transform: CanvasCoordinateTransform, cornerDistance: CGFloat = 1) {
        guard dragStart?.id != item.id else { return }
        if session.selectedAnnotationId != item.id {
            session.selectAnnotation(item.id)
        }
        session.beginInteractiveEdit()
        dragStart = DragStart(
            id: item.id,
            item: item,
            center: toCanvas(item.position01, item, transform),
            from: toCanvas(item.from01, item, transform),
            to: toCanvas(item.to01, item, transform),
            size: boxSize(item, transform),
            cornerDistance: max(1, cornerDistance)
        )
    }

    private func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        session.endInteractiveEdit()
    }

    private func offset(_ p: CGPoint, _ t: CGSize) -> CGPoint {
        CGPoint(x: p.x + t.width, y: p.y + t.height)
    }

    private func endTextEditing() {
        guard session.editingAnnotationTextId != nil else { return }
        session.editingAnnotationTextId = nil
        isTextFieldFocused = false
        session.renderRevision &+= 1
    }

    // MARK: Text, steps and shapes

    @ViewBuilder
    private func boxHandles(_ item: AnnotationItem, transform: CanvasCoordinateTransform) -> some View {
        let center = toCanvas(item.position01, item, transform)
        let size = boxSize(item, transform)
        let isSelected = session.selectedAnnotationId == item.id
        let isEditingText = session.editingAnnotationTextId == item.id
        let halfDiagonal = hypot(size.width, size.height) * 0.5

        ZStack {
            Group {
                if item.kind == .ellipse || item.kind == .step {
                    Ellipse().fill(Color.white.opacity(0.001))
                } else {
                    Rectangle().fill(Color.white.opacity(0.001))
                }
            }
            .overlay(
                Rectangle().strokeBorder(accent.opacity(isSelected && !isEditingText ? 0.95 : 0.0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
            .onTapGesture(count: 2) {
                guard item.kind == .text else { return }
                session.selectAnnotation(item.id)
                session.editingAnnotationTextId = item.id
                session.renderRevision &+= 1
                isTextFieldFocused = true
            }
            .onTapGesture { session.selectAnnotation(item.id) }
            .accessibleButton(item.displayTitle, isSelected: isSelected) { session.selectAnnotation(item.id) }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
                    .onChanged { value in
                        beginDrag(item, transform)
                        guard let start = dragStart else { return }
                        // Steps and shapes mark a spot, so they snap onto recorded clicks.
                        let target = offset(start.center, value.translation)
                        let moved = fromCanvas(item.kind == .step || item.kind.isShape ? snapped(target, item, transform) : target, item, transform)
                        editGeometry(item) { $0.position01 = moved }
                    }
                    .onEnded { _ in endDrag() }
            )

            if isEditingText {
                inlineTextField(item, size: size)
            } else if isSelected {
                ForEach(0..<4, id: \.self) { corner in
                    let sx: CGFloat = corner % 2 == 0 ? -1 : 1
                    let sy: CGFloat = corner < 2 ? -1 : 1
                    handleDot()
                        .position(x: size.width * 0.5 * (1 + sx), y: size.height * 0.5 * (1 + sy))
                        .gesture(cornerDrag(item, transform, sx: sx, sy: sy, halfDiagonal: halfDiagonal))
                }
                if item.kind.canRotate {
                    rotationHandle(item, transform: transform)
                        .position(x: size.width * 0.5, y: -17)
                }
            }
        }
        .frame(width: max(12, size.width), height: max(12, size.height))
        .rotationEffect(.degrees(item.rotationDegrees))
        .position(center)
    }

    /// Text and steps scale about their center; a shape keeps the opposite corner where it is.
    private func cornerDrag(_ item: AnnotationItem, _ transform: CanvasCoordinateTransform, sx: CGFloat, sy: CGFloat, halfDiagonal: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
            .onChanged { value in
                beginDrag(item, transform, cornerDistance: halfDiagonal)
                guard let start = dragStart else { return }
                if !item.kind.isShape {
                    let distance = hypot(value.location.x - start.center.x, value.location.y - start.center.y)
                    let ratio = Double(distance / start.cornerDistance)
                    session.updateAnnotation(id: item.id) {
                        if item.kind == .image {
                            $0.maxWidthRatio = AnnotationItem.clampedMaxWidth(start.item.maxWidthRatio * ratio)
                        } else {
                            $0.fontSizeRatio = AnnotationItem.clampedFontSize(start.item.fontSizeRatio * ratio)
                        }
                    }
                    return
                }
                // Work in the shape's own (unrotated) axes.
                let angle = CGFloat(start.item.rotationDegrees) * .pi / 180
                let cosA = cos(angle), sinA = sin(angle)
                let rel = CGPoint(x: value.location.x - start.center.x, y: value.location.y - start.center.y)
                let local = CGPoint(x: rel.x * cosA + rel.y * sinA, y: -rel.x * sinA + rel.y * cosA)
                let opposite = CGPoint(x: -sx * start.size.width * 0.5, y: -sy * start.size.height * 0.5)
                let newSize = CGSize(width: max(8, abs(local.x - opposite.x)), height: max(8, abs(local.y - opposite.y)))
                let midLocal = CGPoint(x: (local.x + opposite.x) * 0.5, y: (local.y + opposite.y) * 0.5)
                let newCenter = CGPoint(
                    x: start.center.x + midLocal.x * cosA - midLocal.y * sinA,
                    y: start.center.y + midLocal.x * sinA + midLocal.y * cosA
                )
                let units = pointsPerUnit(start.item, transform)
                let position = fromCanvas(newCenter, item, transform)
                editGeometry(item) {
                    $0.position01 = position
                    $0.size01 = Size01(
                        width: AnnotationItem.clampedSize(Double(newSize.width / units.width)),
                        height: AnnotationItem.clampedSize(Double(newSize.height / units.height))
                    )
                }
            }
            .onEnded { _ in endDrag() }
    }

    /// A knob above the box on a short stem; straight up is 0 degrees, and it snaps to multiples of 45 within 4 degrees.
    private func rotationHandle(_ item: AnnotationItem, transform: CanvasCoordinateTransform) -> some View {
        ZStack {
            Rectangle()
                .fill(accent.opacity(0.9))
                .frame(width: 1.2, height: 18)
                .offset(y: 9)
                .allowsHitTesting(false)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(accent))
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .contentShape(Circle().inset(by: -5))
                .accessibilityLabel(Text("Rotate"))
                .offset(y: -9)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
                        .onChanged { value in
                            beginDrag(item, transform)
                            guard let start = dragStart else { return }
                            // The handle sits above the center, so straight up is 0 degrees.
                            var degrees = Double(atan2(value.location.y - start.center.y, value.location.x - start.center.x)) * 180 / .pi + 90
                            let nearest = (degrees / 45).rounded() * 45
                            if abs(degrees - nearest) < 4 { degrees = nearest }
                            editGeometry(item) { $0.rotationDegrees = AnnotationItem.normalizedRotation(degrees) }
                        }
                        .onEnded { _ in endDrag() }
                )
        }
        .frame(width: 16, height: 34)
    }

    @ViewBuilder
    private func inlineTextField(_ item: AnnotationItem, size: CGSize) -> some View {
        let fontSize = AnnotationRenderer.fontSize(for: item, canvasSize: canvasSize)
        let layout = AnnotationRenderer.textLayout(for: item, canvasSize: canvasSize)
        TextField("", text: Binding(
            get: { session.annotation(id: item.id)?.text ?? item.text },
            set: { newText in session.updateAnnotation(id: item.id) { $0.text = newText } }
        ), axis: .vertical)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: fontSize, weight: item.bold ? .bold : .medium))
            .foregroundStyle(Color(hex: item.color))
            .focused($isTextFieldFocused)
            .padding(.horizontal, layout.padding.width)
            .padding(.vertical, layout.padding.height)
            .frame(minWidth: max(size.width, fontSize * 4), minHeight: size.height)
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .fill(item.textBackground == .solid ? Color(hex: item.backgroundColor) : Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(2, layout.cornerRadius), style: .continuous)
                    .strokeBorder(accent, lineWidth: 1.5)
            )
            .onSubmit { endTextEditing() }
            .onExitCommand { endTextEditing() }
            .onChange(of: isTextFieldFocused) { _, focused in
                if !focused { endTextEditing() }
            }
            .onAppear { isTextFieldFocused = true }
    }

    // MARK: Arrow

    @ViewBuilder
    private func arrowHandles(_ item: AnnotationItem, transform: CanvasCoordinateTransform) -> some View {
        let tail = toCanvas(item.from01, item, transform)
        let head = toCanvas(item.to01, item, transform)
        let stroke = AnnotationRenderer.strokeWidth(for: item, canvasSize: canvasSize)
        let geometry = AnnotationRenderer.arrowGeometry(tail: tail, head: head, bend: item.bend, strokeWidth: stroke, yUp: false)
        let middle = CGPoint(
            x: 0.25 * tail.x + 0.5 * geometry.control.x + 0.25 * head.x,
            y: 0.25 * tail.y + 0.5 * geometry.control.y + 0.25 * head.y
        )
        let isSelected = session.selectedAnnotationId == item.id
        let curve = Path { path in
            path.move(to: tail)
            path.addQuadCurve(to: head, control: geometry.control)
        }
        let hitShape = curve.strokedPath(StrokeStyle(lineWidth: max(14, stroke + 10), lineCap: .round))

        ZStack(alignment: .topLeading) {
            hitShape
                .fill(Color.white.opacity(0.001))
                .contentShape(hitShape)
                .onTapGesture { session.selectAnnotation(item.id) }
                .accessibleButton(item.displayTitle, isSelected: isSelected) { session.selectAnnotation(item.id) }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
                        .onChanged { value in
                            beginDrag(item, transform)
                            guard let start = dragStart else { return }
                            // The head snaps onto a recorded click and the tail follows.
                            let head = offset(start.to, value.translation)
                            let snappedHead = snapped(head, item, transform)
                            let shift = CGSize(width: snappedHead.x - start.to.x, height: snappedHead.y - start.to.y)
                            let newFrom = fromCanvas(offset(start.from, shift), item, transform)
                            let newTo = fromCanvas(snappedHead, item, transform)
                            editGeometry(item) {
                                $0.from01 = newFrom
                                $0.to01 = newTo
                            }
                        }
                        .onEnded { _ in endDrag() }
                )

            if isSelected {
                curve
                    .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    .allowsHitTesting(false)

                handleDot()
                    .position(tail)
                    .gesture(endpointDrag(item, transform, movesHead: false))
                handleDot()
                    .position(head)
                    .gesture(endpointDrag(item, transform, movesHead: true))
                handleDot(isBend: true)
                    .position(middle)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
                            .onChanged { value in
                                beginDrag(item, transform)
                                // The curve passes through the pointer: its middle is (tail + 2 * control + head) / 4.
                                let control = CGPoint(
                                    x: 2 * value.location.x - (tail.x + head.x) * 0.5,
                                    y: 2 * value.location.y - (tail.y + head.y) * 0.5
                                )
                                let dx = head.x - tail.x
                                let dy = head.y - tail.y
                                let length = max(1, hypot(dx, dy))
                                // Left of the direction of travel in a y-down space, as `arrowGeometry(yUp: false)`.
                                let normal = CGPoint(x: dy / length, y: -dx / length)
                                let offsetFromMid = CGPoint(x: control.x - (tail.x + head.x) * 0.5, y: control.y - (tail.y + head.y) * 0.5)
                                let bend = Double((offsetFromMid.x * normal.x + offsetFromMid.y * normal.y) / length)
                                session.updateAnnotation(id: item.id) { $0.bend = AnnotationItem.clampedBend(bend) }
                            }
                            .onEnded { _ in endDrag() }
                    )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func endpointDrag(_ item: AnnotationItem, _ transform: CanvasCoordinateTransform, movesHead: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("annotationCanvasSpace"))
            .onChanged { value in
                beginDrag(item, transform)
                guard let start = dragStart else { return }
                let moved = fromCanvas(snapped(offset(movesHead ? start.to : start.from, value.translation), item, transform), item, transform)
                editGeometry(item) {
                    if movesHead { $0.to01 = moved } else { $0.from01 = moved }
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func handleDot(isBend: Bool = false) -> some View {
        Circle()
            .fill(isBend ? accent : Color.white)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(isBend ? Color.white : accent, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .contentShape(Circle().inset(by: -5))
    }
}
