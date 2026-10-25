import SwiftUI
import AppKit

/// Unified Purple Accent used across Background Padding, Inspector Sliders, and Context Menus.
public let kNativeScreenPurpleAccent = Color(red: 0.44, green: 0.34, blue: 0.98)
public let kNativeScreenPurpleHighlight = Color(red: 0.60, green: 0.50, blue: 1.00)

/// Native macOS `NSMenu` Context Menu Presenter.
/// - Uses a real macOS `NSMenu` popped up at the exact mouse cursor position (`menu.popUp(positioning: nil, at: mouseLocation, in: view)`).
/// - Automatically receives macOS's genuine system Liquid Glass / Vibrancy material with ZERO popover arrow!
/// - Embeds custom interactive rows (`PaletteRow`, `SliderRow`, `AspectRatioRow`) via `NSMenuItem.view` alongside native `NSMenuItem` command rows.
@MainActor
public final class NativeSegmentContextMenuPresenter: NSObject {
    public static let shared = NativeSegmentContextMenuPresenter()

    private var activeMenu: NSMenu?
    private var retainedTargets: [AnyObject] = []

    private override init() {
        super.init()
    }

    public func dismissActiveMenu() {
        activeMenu?.cancelTracking()
        activeMenu = nil
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

        // 5. Per-Segment System audio volume SliderRow inside NSMenuItem.view (Applies ONLY to this `sliceId`!)
        let volumeItem = NSMenuItem()
        let volumeView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "System audio volume",
                initialValue: slice.muted ? 0.0 : slice.systemAudioVolume,
                range: 0.0...1.5,
                formatValue: { "\(Int(round($0 * 100)))%" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.setSliceSystemAudioVolume(id: sliceId, volume: newVal)
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
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
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

        // 2. Zoom level SliderRow (`100%` - `350%` — Uses unified Purple Accent!)
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
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
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
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    /// Pops up a timeline context menu so it ALWAYS extends **upward** above the clicked point (`top + right` by default),
    /// flips to `top + left` when clicking near the right edge of the timeline/window/screen, and stays 100% fully visible!
    private func popUpTimelineMenuAboveCursor(
        menu: NSMenu,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        let menuSize = menu.size
        let menuW = max(248.0, menuSize.width)
        let menuH = max(200.0, menuSize.height)

        guard let win = parentView.window, let contentView = win.contentView else {
            menu.popUp(positioning: nil, at: pointInView, in: parentView)
            return
        }

        // Convert the clicked point into global screen coordinates (unflipped: Y increases upward!)
        let clickInWin = parentView.convert(pointInView, to: nil)
        let clickOnScreen = win.convertPoint(toScreen: clickInWin)

        let screenFrame = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // Compute the right edge of the timeline area in screen coordinates (before the 292pt Inspector Sidebar on the right)
        let winScreenRect = win.frame
        let inspectorWidth: CGFloat = 292.0
        let timelineMaxScreenX = min(screenFrame.maxX - 10.0, winScreenRect.maxX - inspectorWidth - 8.0)
        let minScreenX = max(screenFrame.minX + 10.0, winScreenRect.minX + 10.0)

        // 1. Horizontal placement:
        // Default = Top + Right of click (`clickOnScreen.x`).
        // If `clickOnScreen.x + menuW` exceeds the right edge of the timeline or screen, flip to Top + Left (`clickOnScreen.x - menuW`)!
        var topLeftScreenX = clickOnScreen.x
        if topLeftScreenX + menuW > timelineMaxScreenX {
            topLeftScreenX = clickOnScreen.x - menuW
        }
        topLeftScreenX = min(max(topLeftScreenX, minScreenX), screenFrame.maxX - menuW - 10.0)

        // 2. Vertical placement:
        // In AppKit `menu.popUp(positioning: nil, at: loc, in: view)`, `loc` is the **TOP-LEFT corner** of the menu,
        // and the menu extends **DOWNWARD** by `menuH`!
        // Therefore, to make the menu appear **ABOVE** the cursor (`bottom of menu == clickOnScreen.y + 8`),
        // we place the menu's top-left corner at `clickOnScreen.y + menuH + 8`!
        var topLeftScreenY = clickOnScreen.y + menuH + 8.0
        topLeftScreenY = min(max(topLeftScreenY, screenFrame.minY + menuH + 10.0), screenFrame.maxY - 10.0)

        let targetWinPt = win.convertPoint(fromScreen: NSPoint(x: topLeftScreenX, y: topLeftScreenY))
        let targetContentPt = contentView.convert(targetWinPt, from: nil)

        menu.popUp(positioning: nil, at: targetContentPt, in: contentView)
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

// MARK: - Embedded `NSMenuItem.view` Custom Rows (PaletteRow & Custom Purple SliderRow)

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
            .foregroundStyle(isSelected ? kNativeScreenPurpleHighlight : .white.opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected
                    ? kNativeScreenPurpleAccent.opacity(0.28)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? kNativeScreenPurpleHighlight.opacity(0.55) : Color.clear, lineWidth: 1)
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
            .foregroundStyle(isSelected ? kNativeScreenPurpleHighlight : .white.opacity(0.88))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isSelected
                    ? kNativeScreenPurpleAccent.opacity(0.28)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? kNativeScreenPurpleHighlight.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Custom Purple Slider Row for `NSMenuItem.view` — immune to AppKit `NSMenu` vibrancy cyan color distortion!
/// Uses the exact same purple (`kNativeScreenPurpleAccent`) as Background Padding!
private struct MenuEmbeddedSliderRowView: View {
    let title: String
    @State var currentValue: Double
    let range: ClosedRange<Double>
    let formatValue: (Double) -> String
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    @State private var isDragging = false

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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Text(formatValue(currentValue))
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.50))
            }

            // Custom Smooth Purple Track + White Thumb Slider (Never distorted into cyan by NSMenu vibrancy!)
            GeometryReader { geo in
                let trackW = max(1.0, geo.size.width)
                let thumbSize: CGFloat = 14.0
                let span = max(0.0001, range.upperBound - range.lowerBound)
                let frac = CGFloat(min(1.0, max(0.0, (currentValue - range.lowerBound) / span)))
                let thumbCenterX = (thumbSize * 0.5) + frac * max(1.0, trackW - thumbSize)

                ZStack(alignment: .leading) {
                    // Unfilled Track
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 4.5)

                    // Filled Track (Exact Background Padding Purple!)
                    Capsule()
                        .fill(kNativeScreenPurpleAccent)
                        .frame(width: max(4.5, thumbCenterX), height: 4.5)

                    // Crisp White Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: thumbCenterX - thumbSize * 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged(true)
                            }
                            let usableW = max(1.0, trackW - thumbSize)
                            let clampedX = min(max(0.0, value.location.x - thumbSize * 0.5), usableW)
                            let newFrac = Double(clampedX / usableW)
                            let newVal = range.lowerBound + newFrac * (range.upperBound - range.lowerBound)
                            currentValue = newVal
                            onValueChanged(newVal)
                        }
                        .onEnded { _ in
                            if isDragging {
                                isDragging = false
                                onEditingChanged(false)
                            }
                        }
                )
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - 4. Output Aspect Ratio, Reel Mode & Playback Speed Native `NSMenu` Presenters ( 100%!)

extension NativeSegmentContextMenuPresenter {
    public func presentAspectRatioMenu(session: ProjectSession, below buttonView: NSView?) {
        let menu = NSMenu(title: "Output Aspect Ratio")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let contentItem = NSMenuItem()
        let rootView = AspectRatioMenuContentView(session: session) { [weak self] in
            self?.dismissActiveMenu()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 176, height: 228)
        contentItem.view = hostingView
        menu.addItem(contentItem)

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let ptInWin = win.convertPoint(fromScreen: mouseLoc)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 36, y: ptInView.y - 16), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    public func presentReelModeMenu(session: ProjectSession) {
        let menu = NSMenu(title: "Reel Mode")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let contentItem = NSMenuItem()
        let rootView = ReelModeMenuContentView(session: session) { [weak self] in
            self?.dismissActiveMenu()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 164, height: 108)
        contentItem.view = hostingView
        menu.addItem(contentItem)

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let ptInWin = win.convertPoint(fromScreen: mouseLoc)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 36, y: ptInView.y - 16), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    public func presentPlaybackSpeedMenu(session: ProjectSession) {
        let menu = NSMenu(title: "Playback Speed")
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let contentItem = NSMenuItem()
        let rootView = PlaybackSpeedMenuContentView(session: session) { [weak self] in
            self?.dismissActiveMenu()
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 124, height: 192)
        contentItem.view = hostingView
        menu.addItem(contentItem)

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let menuH = max(192.0, menu.size.height)
            let topLeftScreenPt = NSPoint(x: mouseLoc.x - 28, y: mouseLoc.y + menuH + 10)
            let ptInWin = win.convertPoint(fromScreen: topLeftScreenPt)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: ptInView, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }
}

// MARK: - Custom `NSMenu` Content Views for Aspect Ratio, Reel Mode & Playback Speed

private struct AspectRatioMenuContentView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    private let presets: [AspectRatioPreset] = [
        .widescreen16x9,
        .square1x1,
        .classic4x3,
        .vertical9x16,
        .tall3x4,
        .portrait4x5
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 1. Auto Row (Left-aligned, bright white text, right checkmark when active)
            let isAuto = (session.document.canvas.aspectRatioMode == .auto)
            AspectRatioMenuRowButton(isSelected: isAuto) {
                session.mutate { $0.canvas.aspectRatioMode = .auto }
                onDismiss()
            } content: {
                Text("Auto")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
            }

            // 2. Preset Rows (Proportional Rectangle Icon on Left + Bright Title + Dimmed Ratio + Right Checkmark)
            ForEach(presets) { preset in
                let isSelected = (session.document.canvas.aspectRatioMode == .preset && session.document.canvas.aspectRatioPreset == preset)
                AspectRatioMenuRowButton(isSelected: isSelected) {
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = preset
                    }
                    onDismiss()
                } content: {
                    HStack(spacing: 10) {
                        // Proportional Aspect Ratio Rectangle Icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.88), lineWidth: 1.4)
                                .frame(width: preset.iconSize.width, height: preset.iconSize.height)
                        }
                        .frame(width: 18, height: 16, alignment: .center)

                        HStack(spacing: 5) {
                            Text(preset.titleName)
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.96))

                            Text(preset.ratioString)
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct ReelModeMenuContentView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AspectRatioMenuRowButton(isSelected: !session.isReelModeActive) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.isReelModeActive = false
                }
                onDismiss()
            } content: {
                Text("Disable")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
            }

            Divider()
                .padding(.vertical, 3)

            AspectRatioMenuRowButton(isSelected: session.isReelModeActive && session.reelPlatformStyle == .instagramReels) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.reelPlatformStyle = .instagramReels
                    session.isReelModeActive = true
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = .vertical9x16
                    }
                }
                onDismiss()
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Instagram")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
                }
            }

            AspectRatioMenuRowButton(isSelected: session.isReelModeActive && session.reelPlatformStyle == .tiktok) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.reelPlatformStyle = .tiktok
                    session.isReelModeActive = true
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = .vertical9x16
                    }
                }
                onDismiss()
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("TikTok")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct PlaybackSpeedMenuContentView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    private let rates: [Double] = [0.25, 0.5, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rates, id: \.self) { rate in
                let isSelected = abs(session.previewPlaybackRate - rate) < 0.03
                AspectRatioMenuRowButton(isSelected: isSelected) {
                    session.previewPlaybackRate = rate
                    onDismiss()
                } content: {
                    Text(String(format: "%gx", rate))
                        .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct AspectRatioMenuRowButton<RowContent: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> RowContent

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
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
