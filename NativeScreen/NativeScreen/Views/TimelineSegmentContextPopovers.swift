import SwiftUI
import AppKit

/// Native macOS `NSMenu` Context Menu Presenter.
/// - Uses a real macOS `NSMenu` popped up at the exact mouse cursor position (`menu.popUp(positioning: nil, at: mouseLocation, in: view)`).
/// - Automatically receives macOS's genuine system Liquid Glass / Vibrancy material with ZERO popover arrow!
/// - Embeds custom interactive rows (`PaletteRow`, `SliderRow`) via `NSMenuItem.view` alongside native `NSMenuItem` command rows.
@MainActor
public final class NativeSegmentContextMenuPresenter: NSObject {
    public static let shared = NativeSegmentContextMenuPresenter()

    private var activeMenu: NSMenu?
    private var retainedTargets: [AnyObject] = []

    private override init() {
        super.init()
    }

    // MARK: - 1. Present Clip Slice Native Context Menu

    public func presentClipContextMenu(
        session: ProjectSession,
        sliceId: String,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        guard let slice = session.document.timeline.slices.first(where: { $0.id == sliceId }) else { return }
        let sliceIdx = session.document.timeline.slices.firstIndex(where: { $0.id == sliceId }) ?? 0
        let canMergeWithNext = (sliceIdx + 1 < session.document.timeline.slices.count)

        let menu = NSMenu(title: "Clip Context Menu")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        // 1. Split at current time (C)
        menu.addItem(makeCommandItem(title: "Split at current time", keyEquivalent: "c", modifiers: []) {
            session.splitSlice(id: sliceId, atTimelineMs: session.effectivePreviewTimelineMs)
        })

        // 2. Merge with next
        let mergeItem = makeCommandItem(title: "Merge with next", keyEquivalent: "", modifiers: []) {
            session.mergeSliceWithNext(id: sliceId)
        }
        mergeItem.isEnabled = canMergeWithNext
        menu.addItem(mergeItem)

        // 3. Reset trim
        menu.addItem(makeCommandItem(title: "Reset trim", keyEquivalent: "", modifiers: []) {
            session.resetSliceTrim(id: sliceId)
        })

        menu.addItem(.separator())

        // 4. Set speed submenu
        let speedSubmenu = NSMenu(title: "Set speed")
        for spd in [0.5, 1.0, 1.25, 1.5, 2.0, 4.0] {
            let subItem = makeCommandItem(title: String(format: "%gx", spd), keyEquivalent: "", modifiers: []) {
                session.setSliceSpeed(id: sliceId, speed: spd)
            }
            subItem.state = abs(slice.speed - spd) < 0.03 ? .on : .off
            speedSubmenu.addItem(subItem)
        }
        let speedParentItem = NSMenuItem(title: "Set speed", action: nil, keyEquivalent: "")
        speedParentItem.submenu = speedSubmenu
        menu.addItem(speedParentItem)

        menu.addItem(.separator())

        // 5. System audio volume SliderRow inside NSMenuItem.view
        let volumeItem = NSMenuItem()
        let volumeView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "System audio volume",
                initialValue: session.document.audio.systemAudioVolume,
                range: 0.0...1.5,
                formatValue: { "\(Int(round($0 * 100)))%" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.mutate { $0.audio.systemAudioVolume = newVal }
                }
            )
        )
        volumeView.frame = NSRect(x: 0, y: 0, width: 256, height: 54)
        volumeItem.view = volumeView
        menu.addItem(volumeItem)

        menu.addItem(.separator())

        // 6. Hide mouse cursor & Disable smooth mouse movement
        let hideCursorItem = makeCommandItem(
            title: "Hide mouse cursor",
            keyEquivalent: "",
            modifiers: []
        ) {
            session.toggleSliceHideCursor(id: sliceId)
        }
        hideCursorItem.state = slice.hideCursor ? .on : .off
        menu.addItem(hideCursorItem)

        let disableSmoothItem = makeCommandItem(
            title: "Disable smooth mouse movement",
            keyEquivalent: "",
            modifiers: []
        ) {
            session.toggleSliceDisableSmoothCursor(id: sliceId)
        }
        disableSmoothItem.state = slice.disableSmoothCursor ? .on : .off
        menu.addItem(disableSmoothItem)

        menu.addItem(.separator())

        // 7. Remove & Reset trims and cuts for all slices (Destructive Red)
        let removeItem = makeDestructiveCommandItem(
            title: "Remove",
            symbolName: "delete.left"
        ) {
            session.selectSlice(sliceId)
            session.deleteSelectedSlice()
        }
        removeItem.isEnabled = session.document.timeline.slices.count > 1
        menu.addItem(removeItem)

        let resetAllItem = makeDestructiveCommandItem(
            title: "Reset trims and cuts for all slices",
            symbolName: nil
        ) {
            session.resetAllSlicesTrimAndCuts()
        }
        menu.addItem(resetAllItem)

        activeMenu = menu
        menu.popUp(positioning: nil, at: pointInView, in: parentView)
    }

    // MARK: - 2. Present Zoom Block Native Context Menu

    public func presentZoomContextMenu(
        session: ProjectSession,
        zoomId: String,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        guard let zoom = session.document.timeline.zooms.first(where: { $0.id == zoomId }) else { return }

        let menu = NSMenu(title: "Zoom Context Menu")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        // 1. Top 2-Card PaletteRow: Classic vs Loupe (embedded via NSMenuItem.view)
        let paletteItem = NSMenuItem()
        let paletteView = NSHostingView(
            rootView: ZoomPaletteHeaderRowView(
                session: session,
                zoomId: zoomId
            )
        )
        paletteView.frame = NSRect(x: 0, y: 0, width: 258, height: 64)
        paletteItem.view = paletteView
        menu.addItem(paletteItem)

        menu.addItem(.separator())

        // 2. Zoom level SliderRow (`100%` - `350%`)
        let sliderItem = NSMenuItem()
        let sliderView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "Zoom level",
                initialValue: zoom.scale,
                range: 1.1...3.5,
                formatValue: { "\(Int(round($0 * 100)))%" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.setZoomScale(id: zoomId, scale: newVal)
                }
            )
        )
        sliderView.frame = NSRect(x: 0, y: 0, width: 258, height: 54)
        sliderItem.view = sliderView
        menu.addItem(sliderItem)

        // 3. Apply zoom level to all other zooms
        menu.addItem(makeCommandItem(title: "Apply zoom level to all other zooms", keyEquivalent: "", modifiers: []) {
            session.applyZoomLevelToAllOtherZooms(fromId: zoomId)
        })

        menu.addItem(.separator())

        // 4. Split zoom at current time (C), Duplicate (⌘D), Disable (D)
        menu.addItem(makeCommandItem(title: "Split zoom at current time", keyEquivalent: "c", modifiers: []) {
            session.splitZoom(id: zoomId, atSourceMs: session.currentSourceTimeMs)
        })

        menu.addItem(makeCommandItem(title: "Duplicate", keyEquivalent: "d", modifiers: [.command]) {
            session.duplicateZoom(id: zoomId)
        })

        menu.addItem(makeCommandItem(title: zoom.disabled ? "Enable" : "Disable", keyEquivalent: "d", modifiers: []) {
            session.toggleZoomDisabled(id: zoomId)
        })

        menu.addItem(.separator())

        // 5. Copy zoom range (⌘C), Cut to clipboard (⌘X)
        menu.addItem(makeCommandItem(title: "Copy zoom range", keyEquivalent: "c", modifiers: [.command]) {
            session.copyZoomToClipboard(id: zoomId)
        })

        menu.addItem(makeCommandItem(title: "Cut to clipboard", keyEquivalent: "x", modifiers: [.command]) {
            session.cutZoomToClipboard(id: zoomId)
        })

        menu.addItem(.separator())

        // 6. Remove (Destructive Red)
        menu.addItem(makeDestructiveCommandItem(title: "Remove", symbolName: "delete.left") {
            session.deleteZoom(zoomId: zoomId)
        })

        activeMenu = menu
        menu.popUp(positioning: nil, at: pointInView, in: parentView)
    }

    // MARK: - 3. Present Mask Block Native Context Menu

    public func presentMaskContextMenu(
        session: ProjectSession,
        maskId: String,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        var foundMask: MaskItem?
        for track in session.document.timeline.maskTracks {
            if let m = track.items.first(where: { $0.id == maskId }) {
                foundMask = m
                break
            }
        }
        guard let mask = foundMask else { return }

        let menu = NSMenu(title: "Mask Context Menu")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        // 1. Top 2-Card PaletteRow: Highlight vs Sensitive data (embedded via NSMenuItem.view)
        let paletteItem = NSMenuItem()
        let paletteView = NSHostingView(
            rootView: MaskPaletteHeaderRowView(
                session: session,
                maskId: maskId
            )
        )
        paletteView.frame = NSRect(x: 0, y: 0, width: 252, height: 64)
        paletteItem.view = paletteView
        menu.addItem(paletteItem)

        menu.addItem(.separator())

        // 2. Split mask at current time (C), Disable (D)
        menu.addItem(makeCommandItem(title: "Split mask at current time", keyEquivalent: "c", modifiers: []) {
            session.splitMask(id: maskId, atSourceMs: session.currentSourceTimeMs)
        })

        menu.addItem(makeCommandItem(title: mask.disabled ? "Enable" : "Disable", keyEquivalent: "d", modifiers: []) {
            session.toggleMaskDisabled(id: maskId)
        })

        menu.addItem(.separator())

        // 3. Copy mask (⌘C), Cut to clipboard (⌘X)
        menu.addItem(makeCommandItem(title: "Copy mask", keyEquivalent: "c", modifiers: [.command]) {
            session.copyMaskToClipboard(id: maskId)
        })

        menu.addItem(makeCommandItem(title: "Cut to clipboard", keyEquivalent: "x", modifiers: [.command]) {
            session.cutMaskToClipboard(id: maskId)
        })

        menu.addItem(.separator())

        // 4. Remove (Destructive Red)
        menu.addItem(makeDestructiveCommandItem(title: "Remove", symbolName: "delete.left") {
            session.deleteMask(maskId: maskId)
        })

        activeMenu = menu
        menu.popUp(positioning: nil, at: pointInView, in: parentView)
    }

    // MARK: - NSMenuItem Builders

    private func makeCommandItem(
        title: String,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let handler = ClosureMenuTarget(action: action)
        retainedTargets.append(handler)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = handler
        return item
    }

    private func makeDestructiveCommandItem(
        title: String,
        symbolName: String?,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let handler = ClosureMenuTarget(action: action)
        retainedTargets.append(handler)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
        item.target = handler
        let redColor = NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: redColor,
                .font: NSFont.menuFont(ofSize: 13)
            ]
        )
        if let sym = symbolName {
            item.keyEquivalent = "\u{8}" // Shows `⌫` delete symbol on the right side!
            item.keyEquivalentModifierMask = []
            _ = sym
        }
        return item
    }
}

@MainActor
private final class ClosureMenuTarget: NSObject {
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: Any?) {
        action()
    }
}

// MARK: - Embedded `NSMenuItem.view` Custom Rows (PaletteRow & SliderRow)

private struct ZoomPaletteHeaderRowView: View {
    @Bindable var session: ProjectSession
    let zoomId: String

    private var currentPresentation: ZoomPresentation {
        session.document.timeline.zooms.first(where: { $0.id == zoomId })?.presentation ?? .screen
    }

    var body: some View {
        HStack(spacing: 6) {
            paletteCardButton(
                title: "Classic",
                systemImage: "plus.magnifyingglass",
                isSelected: currentPresentation == .screen
            ) {
                session.setZoomPresentation(id: zoomId, presentation: .screen)
            }

            paletteCardButton(
                title: "Loupe",
                systemImage: "sparkle.magnifyingglass",
                isSelected: currentPresentation == .loupe
            ) {
                session.setZoomPresentation(id: zoomId, presentation: .loupe)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func paletteCardButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color(red: 0.35, green: 0.65, blue: 1.0) : .white.opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected
                    ? Color.blue.opacity(0.24)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MaskPaletteHeaderRowView: View {
    @Bindable var session: ProjectSession
    let maskId: String

    private var currentType: MaskType {
        for track in session.document.timeline.maskTracks {
            if let found = track.items.first(where: { $0.id == maskId }) {
                return found.type
            }
        }
        return .blur
    }

    var body: some View {
        HStack(spacing: 6) {
            paletteCardButton(
                title: "Highlight",
                systemImage: "viewfinder.rectangular",
                isSelected: currentType == .spotlight
            ) {
                session.setMaskType(id: maskId, type: .spotlight)
            }

            paletteCardButton(
                title: "Sensitive data",
                systemImage: "eye.slash",
                isSelected: currentType == .blur
            ) {
                session.setMaskType(id: maskId, type: .blur)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func paletteCardButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color(red: 0.35, green: 0.65, blue: 1.0) : .white.opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected
                    ? Color.blue.opacity(0.24)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MenuEmbeddedSliderRowView: View {
    let title: String
    @State var currentValue: Double
    let range: ClosedRange<Double>
    let formatValue: (Double) -> String
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    init(
        title: String,
        initialValue: Double,
        range: ClosedRange<Double>,
        formatValue: @escaping (Double) -> String,
        onEditingChanged: @escaping (Bool) -> Void,
        onValueChanged: @escaping (Double) -> Void
    ) {
        self.title = title
        self._currentValue = State(initialValue: initialValue)
        self.range = range
        self.formatValue = formatValue
        self.onEditingChanged = onEditingChanged
        self.onValueChanged = onValueChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(formatValue(currentValue))
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.50))
            }

            Slider(
                value: Binding(
                    get: { currentValue },
                    set: { newVal in
                        currentValue = newVal
                        onValueChanged(newVal)
                    }
                ),
                in: range,
                onEditingChanged: onEditingChanged
            )
            .tint(.blue)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - 4. Output Aspect Ratio & Reel Mode Native `NSMenu` Presenters (Zero Arrow, Genuine macOS Liquid Glass!)

extension NativeSegmentContextMenuPresenter {
    public func presentAspectRatioMenu(session: ProjectSession, below buttonView: NSView?) {
        let menu = NSMenu(title: "Output Aspect Ratio")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let autoItem = makeCommandItem(title: "Auto", keyEquivalent: "", modifiers: []) {
            session.mutate { $0.canvas.aspectRatioMode = .auto }
        }
        autoItem.state = (session.document.canvas.aspectRatioMode == .auto) ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        let presets: [AspectRatioPreset] = [
            .widescreen16x9,
            .square1x1,
            .classic4x3,
            .vertical9x16,
            .tall3x4,
            .portrait4x5
        ]

        for preset in presets {
            let item = makeCommandItem(title: preset.label, keyEquivalent: "", modifiers: []) {
                session.mutate {
                    $0.canvas.aspectRatioMode = .preset
                    $0.canvas.aspectRatioPreset = preset
                }
            }
            let isSelected = (session.document.canvas.aspectRatioMode == .preset && session.document.canvas.aspectRatioPreset == preset)
            item.state = isSelected ? .on : .off
            item.image = renderAspectRatioIconNSImage(size: preset.iconSize)

            let attr = NSMutableAttributedString(
                string: "\(preset.titleName) ",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.menuFont(ofSize: 13)
                ]
            )
            attr.append(
                NSAttributedString(
                    string: preset.ratioString,
                    attributes: [
                        .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                        .font: NSFont.menuFont(ofSize: 13)
                    ]
                )
            )
            item.attributedTitle = attr
            menu.addItem(item)
        }

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let ptInWin = win.convertPoint(fromScreen: mouseLoc)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 24, y: ptInView.y - 12), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    public func presentReelModeMenu(session: ProjectSession) {
        let menu = NSMenu(title: "Reel Mode")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let disableItem = makeCommandItem(title: "Disable", keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.isReelModeActive = false
            }
        }
        disableItem.state = !session.isReelModeActive ? .on : .off
        menu.addItem(disableItem)

        menu.addItem(.separator())

        let igItem = makeCommandItem(title: "Instagram", keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.reelPlatformStyle = .instagramReels
                session.isReelModeActive = true
                session.mutate {
                    $0.canvas.aspectRatioMode = .preset
                    $0.canvas.aspectRatioPreset = .vertical9x16
                }
            }
        }
        igItem.state = (session.isReelModeActive && session.reelPlatformStyle == .instagramReels) ? .on : .off
        menu.addItem(igItem)

        let ttItem = makeCommandItem(title: "TikTok", keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.reelPlatformStyle = .tiktok
                session.isReelModeActive = true
                session.mutate {
                    $0.canvas.aspectRatioMode = .preset
                    $0.canvas.aspectRatioPreset = .vertical9x16
                }
            }
        }
        ttItem.state = (session.isReelModeActive && session.reelPlatformStyle == .tiktok) ? .on : .off
        menu.addItem(ttItem)

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let ptInWin = win.convertPoint(fromScreen: mouseLoc)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 24, y: ptInView.y - 12), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    public func presentPlaybackSpeedMenu(session: ProjectSession) {
        let menu = NSMenu(title: "Playback Speed")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let rates: [Double] = [0.25, 0.5, 1.0, 1.25, 1.5, 2.0]
        for rate in rates {
            let item = makeCommandItem(title: String(format: "%gx", rate), keyEquivalent: "", modifiers: []) {
                session.previewPlaybackRate = rate
            }
            item.state = abs(session.previewPlaybackRate - rate) < 0.03 ? .on : .off
            menu.addItem(item)
        }

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let ptInWin = win.convertPoint(fromScreen: mouseLoc)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 16, y: ptInView.y + 12), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    private func renderAspectRatioIconNSImage(size: CGSize) -> NSImage {
        let canvasSize = NSSize(width: 18, height: 16)
        let img = NSImage(size: canvasSize, flipped: false) { _ in
            let rect = NSRect(
                x: (18.0 - size.width) * 0.5,
                y: (16.0 - size.height) * 0.5,
                width: size.width,
                height: size.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.2, yRadius: 2.2)
            path.lineWidth = 1.4
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - 5. Custom Aspect Ratio Icon & Reel Mode Phone Icon

public struct AspectIconView: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let outerRect = CGRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
            let outerPath = Path(roundedRect: outerRect, cornerRadius: 2.2)
            context.stroke(outerPath, with: .color(.white.opacity(0.92)), lineWidth: 1.4)

            var inner1 = Path()
            inner1.move(to: CGPoint(x: outerRect.minX, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.maxY))
            context.stroke(inner1, with: .color(.white.opacity(0.85)), lineWidth: 1.2)

            var inner2 = Path()
            inner2.move(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.minY + outerRect.height * 0.42))
            inner2.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.maxY))
            context.stroke(inner2, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
        }
        .frame(width: 16, height: 15)
    }
}

public struct ReelPhoneIconView: View {
    public var isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    public var body: some View {
        let color = isActive ? Color(red: 0.58, green: 0.52, blue: 1.0) : Color.white.opacity(0.88)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4)
                .frame(width: 11, height: 15)

            RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 3.5)
                .padding(.bottom, 2.2)
        }
        .frame(width: 14, height: 15)
    }
}
