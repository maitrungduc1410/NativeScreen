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

        let menu = NSMenu(title: String(localized: "Clip Context Menu"))
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
        let speedSubmenu = NSMenu(title: String(localized: "Set speed"))
        for spd in [0.5, 1.0, 1.25, 1.5, 2.0, 4.0] {
            let subItem = makeCommandItem(title: String(format: "%gx", spd), keyEquivalent: "", modifiers: []) {
                session.setSliceSpeed(id: sliceId, speed: spd)
            }
            subItem.state = abs(slice.speed - spd) < 0.03 ? .on : .off
            speedSubmenu.addItem(subItem)
        }
        let speedParentItem = NSMenuItem(title: String(localized: "Set speed"), action: nil, keyEquivalent: "")
        speedParentItem.submenu = speedSubmenu
        menu.addItem(speedParentItem)

        menu.addItem(.separator())

        // 5. Per-segment volume sliders, one per recorded audio source. They apply ONLY to this `sliceId`.
        func addVolumeSlider(title: String, value: Double, onChange: @escaping @MainActor (Double) -> Void) {
            let volumeItem = NSMenuItem()
            let volumeView = NSHostingView(
                rootView: MenuEmbeddedSliderRowView(
                    title: title,
                    initialValue: value,
                    range: 0.0...1.0,
                    formatValue: { "\(Int(round($0 * 100)))%" },
                    onEditingChanged: { editing in
                        if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                    },
                    onValueChanged: onChange
                )
            )
            volumeView.sizingOptions = []
            volumeView.autoresizingMask = [.width]
            volumeView.frame = NSRect(x: 0, y: 0, width: 276, height: 54)
            volumeItem.view = volumeView
            menu.addItem(volumeItem)
        }
        let hasMicrophone = session.microphoneAudioFileURL != nil
        let hasSystemAudio = session.metadata.tracks.systemAudio != nil
        if hasMicrophone {
            addVolumeSlider(title: "Microphone volume", value: slice.muted ? 0.0 : slice.microphoneVolume) { newVal in
                session.setSliceMicrophoneVolume(id: sliceId, volume: newVal)
            }
        }
        if hasSystemAudio {
            addVolumeSlider(title: "System audio volume", value: slice.muted ? 0.0 : slice.systemAudioVolume) { newVal in
                session.setSliceSystemAudioVolume(id: sliceId, volume: newVal)
            }
        }
        if hasMicrophone || hasSystemAudio {
            menu.addItem(.separator())
        }

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

        syncCustomItemViewWidths(in: menu, minimumWidth: 276)
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

        let menu = NSMenu(title: String(localized: "Zoom Context Menu"))
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
        paletteView.sizingOptions = []
        paletteView.autoresizingMask = [.width]
        paletteView.frame = NSRect(x: 0, y: 0, width: 280, height: 64)
        paletteItem.view = paletteView
        menu.addItem(paletteItem)

        menu.addItem(.separator())

        // 2. Zoom level SliderRow (`100%` - `400%`, 10% step increments — Native AppKit `NSSlider` with Purple Fill!)
        let sliderItem = NSMenuItem()
        let sliderView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "Zoom level",
                initialValue: zoom.scale,
                range: 1.0...4.0,
                step: 0.1,
                formatValue: { "\(Int(round($0 * 100)))%" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    let stepped = (newVal * 10.0).rounded() / 10.0
                    session.setZoomScale(id: zoomId, scale: stepped)
                }
            )
        )
        sliderView.sizingOptions = []
        sliderView.autoresizingMask = [.width]
        sliderView.frame = NSRect(x: 0, y: 0, width: 280, height: 54)
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

        syncCustomItemViewWidths(in: menu, minimumWidth: 280)
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

        let menu = NSMenu(title: String(localized: "Mask Context Menu"))
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
        paletteView.sizingOptions = []
        paletteView.autoresizingMask = [.width]
        paletteView.frame = NSRect(x: 0, y: 0, width: 264, height: 64)
        paletteItem.view = paletteView
        menu.addItem(paletteItem)

        menu.addItem(.separator())

        // 1b. Mask Intensity Slider (Blur intensity 4..160 OR Highlight intensity 0..95%)
        let intensityItem = NSMenuItem()
        let isHighlight = (mask.type == .spotlight)
        let intensityView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: isHighlight ? "Highlight intensity" : "Blur intensity",
                initialValue: mask.intensity,
                range: isHighlight ? (0.0...95.0) : (4.0...160.0),
                formatValue: { val in
                    isHighlight ? "\(Int(round(val)))%" : "\(Int(round(val)))"
                },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.mutate { doc in
                        for tIdx in doc.timeline.maskTracks.indices {
                            if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == maskId }) {
                                doc.timeline.maskTracks[tIdx].items[mIdx].intensity = newVal
                                return
                            }
                        }
                    }
                }
            )
        )
        intensityView.sizingOptions = []
        intensityView.autoresizingMask = [.width]
        intensityView.frame = NSRect(x: 0, y: 0, width: 264, height: 54)
        intensityItem.view = intensityView
        menu.addItem(intensityItem)

        // 1c. Mask Corner Radius Slider (`0..120`)
        let radiusItem = NSMenuItem()
        let radiusView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "Corner radius",
                initialValue: mask.cornerRadius,
                range: 0.0...120.0,
                formatValue: { "\(Int(round($0)))px" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.mutate { doc in
                        for tIdx in doc.timeline.maskTracks.indices {
                            if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == maskId }) {
                                doc.timeline.maskTracks[tIdx].items[mIdx].cornerRadius = newVal
                                return
                            }
                        }
                    }
                }
            )
        )
        radiusView.sizingOptions = []
        radiusView.autoresizingMask = [.width]
        radiusView.frame = NSRect(x: 0, y: 0, width: 264, height: 54)
        radiusItem.view = radiusView
        menu.addItem(radiusItem)

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

        syncCustomItemViewWidths(in: menu, minimumWidth: 264)
        activeMenu = menu
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    // MARK: - 3b. Present Keyboard Shortcut Block Native Context Menu

    public func presentCaptionContextMenu(
        session: ProjectSession,
        block: CaptionBlock,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        let menu = NSMenu(title: String(localized: "Caption Context Menu"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        menu.addItem(makeCommandItem(title: "Split at playhead", keyEquivalent: "c", modifiers: []) {
            session.splitCaption(id: block.id, atSourceMs: session.currentSourceTimeMs)
        })
        menu.addItem(makeCommandItem(title: "Add caption track", keyEquivalent: "", modifiers: []) {
            session.addCaptionTrack()
        })

        menu.addItem(.separator())

        menu.addItem(makeDestructiveCommandItem(title: "Remove caption", symbolName: "trash") {
            session.deleteCaption(id: block.id)
        })
        menu.addItem(makeDestructiveCommandItem(title: "Remove this track", symbolName: "trash") {
            session.deleteCaptionTrack(id: block.trackId)
        })

        activeMenu = menu
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    public func presentShortcutContextMenu(
        session: ProjectSession,
        cluster: ProjectSession.ShortcutPressCluster,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        let menu = NSMenu(title: String(localized: "Shortcut Context Menu"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let isHidden = session.isShortcutHidden(cluster)
        let showThisItem = makeCommandItem(title: "Show this shortcut", keyEquivalent: "", modifiers: []) {
            session.toggleShortcutHidden(cluster)
        }
        showThisItem.state = !isHidden ? .on : .off
        menu.addItem(showThisItem)

        let allClusters = session.detectedShortcutClusters
        let sameLabelClusters = allClusters.filter { $0.compactTimelineLabel == cluster.compactTimelineLabel }
        if sameLabelClusters.count >= 2 {
            let allSameVisible = sameLabelClusters.allSatisfy { !session.isShortcutHidden($0) }
            let showEveryItem = makeCommandItem(title: String(localized: "Show every \(cluster.compactTimelineLabel)"), keyEquivalent: "", modifiers: []) {
                session.setEveryShortcutWithSameLabelHidden(cluster, hidden: allSameVisible)
            }
            showEveryItem.state = allSameVisible ? .on : .off
            menu.addItem(showEveryItem)
        }

        let allHidden = !allClusters.isEmpty && allClusters.allSatisfy { session.isShortcutHidden($0) }
        let toggleAllItem = makeCommandItem(title: allHidden ? "Show all shortcuts" : "Hide all shortcuts", keyEquivalent: "", modifiers: []) {
            session.setAllShortcutsHidden(!allHidden)
        }
        menu.addItem(toggleAllItem)

        menu.addItem(.separator())

        menu.addItem(makeCommandItem(title: "Edit shortcut…", keyEquivalent: "", modifiers: []) {
            session.selectShortcut(cluster.id)
        })

        menu.addItem(makeCommandItem(title: "Duplicate shortcut", keyEquivalent: "d", modifiers: [.command]) {
            session.duplicateShortcut(cluster)
        })

        menu.addItem(makeCommandItem(title: "Add new shortcut track", keyEquivalent: "", modifiers: []) {
            session.addShortcutTrack()
        })

        menu.addItem(.separator())

        menu.addItem(makeDestructiveCommandItem(title: "Remove shortcut", symbolName: "trash") {
            session.deleteShortcut(cluster)
        })

        activeMenu = menu
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    // MARK: - 3c. Present Camera Layout Segment Context Menu

    public func presentCameraLayoutContextMenu(
        session: ProjectSession,
        layoutId: String,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        guard let seg = session.document.timeline.cameraLayouts.first(where: { $0.id == layoutId }) else { return }

        let menu = NSMenu(title: String(localized: "Camera Layout Context Menu"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        for type in CameraTimelineLayoutType.allCases {
            let item = makeCommandItem(title: type.label, keyEquivalent: "", modifiers: []) {
                session.mutate { doc in
                    if let idx = doc.timeline.cameraLayouts.firstIndex(where: { $0.id == layoutId }) {
                        doc.timeline.cameraLayouts[idx].layoutType = type
                    }
                }
            }
            item.state = (seg.layoutType == type) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        menu.addItem(makeCommandItem(title: "Split layout at current time", keyEquivalent: "c", modifiers: []) {
            session.splitCameraLayout(id: layoutId, atSourceMs: session.currentSourceTimeMs)
        })

        menu.addItem(makeCommandItem(title: "Duplicate", keyEquivalent: "d", modifiers: [.command]) {
            session.duplicateCameraLayout(id: layoutId)
        })

        menu.addItem(makeCommandItem(title: seg.disabled ? "Enable" : "Disable", keyEquivalent: "d", modifiers: []) {
            session.toggleCameraLayoutDisabled(id: layoutId)
        })

        menu.addItem(.separator())

        menu.addItem(makeDestructiveCommandItem(title: "Remove", symbolName: "delete.left") {
            session.deleteCameraLayout(id: layoutId)
        })

        menu.addItem(makeDestructiveCommandItem(title: "Remove all layouts", symbolName: "trash") {
            session.deleteAllCameraLayouts()
        })

        activeMenu = menu
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    // MARK: - 3d. Present Voiceover Segment Context Menu

    public func presentVoiceoverContextMenu(
        session: ProjectSession,
        voiceoverId: String,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        guard let vo = session.document.timeline.voiceovers.first(where: { $0.id == voiceoverId }) else { return }

        let menu = NSMenu(title: String(localized: "Voiceover Context Menu"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        let sliderItem = NSMenuItem()
        let sliderView = NSHostingView(
            rootView: MenuEmbeddedSliderRowView(
                title: "Voiceover volume",
                initialValue: vo.volume,
                range: 0.0...1.0,
                step: 0.01,
                formatValue: { "\(Int(round($0 * 100)))%" },
                onEditingChanged: { editing in
                    if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                },
                onValueChanged: { newVal in
                    session.mutate { doc in
                        if let idx = doc.timeline.voiceovers.firstIndex(where: { $0.id == voiceoverId }) {
                            doc.timeline.voiceovers[idx].volume = max(0.0, min(1.0, newVal))
                        }
                    }
                }
            )
        )
        sliderView.sizingOptions = []
        sliderView.autoresizingMask = [.width]
        sliderView.frame = NSRect(x: 0, y: 0, width: 264, height: 54)
        sliderItem.view = sliderView
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        menu.addItem(makeCommandItem(title: vo.disabled ? "Enable" : "Disable", keyEquivalent: "d", modifiers: []) {
            session.toggleVoiceoverDisabled(id: voiceoverId)
        })

        menu.addItem(makeCommandItem(title: "Record new voiceover…", keyEquivalent: "", modifiers: []) {
            session.startVoiceoverRecording()
        })

        menu.addItem(makeCommandItem(title: "Upload voiceover audio file…", keyEquivalent: "", modifiers: []) {
            session.promptImportVoiceoverAudioFile()
        })

        menu.addItem(.separator())

        menu.addItem(makeDestructiveCommandItem(title: "Remove voiceover", symbolName: "delete.left") {
            session.deleteVoiceover(id: voiceoverId)
        })

        menu.addItem(makeDestructiveCommandItem(title: "Remove all voiceovers", symbolName: "trash") {
            session.deleteAllVoiceovers()
        })

        syncCustomItemViewWidths(in: menu, minimumWidth: 264)
        activeMenu = menu
        popUpTimelineMenuAboveCursor(menu: menu, at: pointInView, in: parentView)
    }

    /// Ensures all custom `NSMenuItem.view` rows (`PaletteRow`, `SliderRow`) span 100% of the final `NSMenu` width
    /// with zero leftover space on the right!
    private func syncCustomItemViewWidths(in menu: NSMenu, minimumWidth: CGFloat) {
        let computedMenuWidth = max(minimumWidth, ceil(menu.size.width))
        menu.minimumWidth = computedMenuWidth
        for item in menu.items {
            if let customView = item.view {
                if let hosting = customView as? NSHostingView<AnyView> {
                    hosting.sizingOptions = []
                }
                customView.autoresizingMask = [.width]
                customView.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: computedMenuWidth,
                    height: customView.frame.height
                )
                customView.needsLayout = true
            }
        }
    }

    /// Pops up a timeline context menu so it ALWAYS extends **upward** above the clicked point (`top + right` by default),
    /// flips to `top + left` when clicking near the right edge of the timeline/window/screen, and stays 100% fully visible!
    private func popUpTimelineMenuAboveCursor(
        menu: NSMenu,
        at pointInView: NSPoint,
        in parentView: NSView
    ) {
        let menuSize = menu.size
        let menuW = max(168.0, menuSize.width)
        let menuH = max(36.0, menuSize.height)

        guard let win = parentView.window, let contentView = win.contentView else {
            menu.popUp(positioning: nil, at: pointInView, in: parentView)
            return
        }

        // Crucial: Use `NSApp.currentEvent?.locationInWindow` when available so SwiftUI `.offset(x:)` layer transforms
        // on timeline segments never displace the popup X coordinate!
        let clickInWin: NSPoint = {
            if let ev = NSApp.currentEvent, ev.window === win {
                return ev.locationInWindow
            }
            return parentView.convert(pointInView, to: nil)
        }()
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
        let item = NSMenuItem(title: title.localizedUI, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: keyEquivalent)
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
        let item = NSMenuItem(title: title.localizedUI, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
        item.target = handler
        let redColor = NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        item.attributedTitle = NSAttributedString(
            string: title.localizedUI,
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title.localizedUI)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isSelected ? kNativeScreenPurpleHighlight : .ink.opacity(0.88))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isSelected
                ? kNativeScreenPurpleAccent.opacity(0.28)
                : Color.ink.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? kNativeScreenPurpleHighlight.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(
            MenuImmediateClickOverlay(onClick: action)
        )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title.localizedUI)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isSelected ? kNativeScreenPurpleHighlight : .ink.opacity(0.88))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isSelected
                ? kNativeScreenPurpleAccent.opacity(0.28)
                : Color.ink.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? kNativeScreenPurpleHighlight.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(
            MenuImmediateClickOverlay(onClick: action)
        )
    }
}

/// Native AppKit `NSView` click responder that fires immediately inside `NSMenu`'s `NSEventTrackingRunLoopMode`!
private struct MenuImmediateClickOverlay: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ImmediateClickNSView {
        let v = ImmediateClickNSView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ nsView: ImmediateClickNSView, context: Context) {
        nsView.onClick = onClick
    }

    final class ImmediateClickNSView: NSView {
        var onClick: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }
}

/// Native AppKit `NSSlider` Row for `NSMenuItem.view` — works 100% natively during `NSMenu` event tracking
/// and uses `trackFillColor` so the slider track stays purple in both appearances.
private struct MenuEmbeddedSliderRowView: View {
    let title: String
    @State var currentValue: Double
    let range: ClosedRange<Double>
    let step: Double?
    let formatValue: (Double) -> String
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    init(
        title: String,
        initialValue: Double,
        range: ClosedRange<Double>,
        step: Double? = nil,
        formatValue: @escaping (Double) -> String,
        onEditingChanged: @escaping (Bool) -> Void,
        onValueChanged: @escaping (Double) -> Void
    ) {
        self.title = title
        self._currentValue = State(initialValue: initialValue)
        self.range = range
        self.step = step
        self.formatValue = formatValue
        self.onEditingChanged = onEditingChanged
        self.onValueChanged = onValueChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.localizedUI)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.95))
                Spacer()
                Text(formatValue(currentValue))
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(.ink.opacity(0.50))
            }

            NativeMenuAppKitSlider(
                value: $currentValue,
                range: range,
                step: step,
                onEditingChanged: onEditingChanged,
                onValueChanged: onValueChanged
            )
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct NativeMenuAppKitSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.sliderChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.trackFillColor = NSColor(red: 0.44, green: 0.34, blue: 0.98, alpha: 1.0)
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.parent = self
        nsView.minValue = range.lowerBound
        nsView.maxValue = range.upperBound
        if abs(nsView.doubleValue - value) > 0.0005 {
            nsView.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var parent: NativeMenuAppKitSlider
        private var isTracking = false

        init(_ parent: NativeMenuAppKitSlider) {
            self.parent = parent
        }

        @objc func sliderChanged(_ sender: NSSlider) {
            let eventType = NSApp.currentEvent?.type
            if !isTracking && (eventType == .leftMouseDown || eventType == .leftMouseDragged) {
                isTracking = true
                parent.onEditingChanged(true)
            }

            var newVal = min(max(sender.doubleValue, parent.range.lowerBound), parent.range.upperBound)
            if let step = parent.step, step > 0 {
                newVal = ((newVal - parent.range.lowerBound) / step).rounded() * step + parent.range.lowerBound
                newVal = min(max(newVal, parent.range.lowerBound), parent.range.upperBound)
                sender.doubleValue = newVal
            }

            parent.value = newVal
            parent.onValueChanged(newVal)

            if eventType == .leftMouseUp {
                if isTracking {
                    isTracking = false
                    parent.onEditingChanged(false)
                }
            }
        }
    }
}

// MARK: - 4. Output Aspect Ratio, Reel Mode & Playback Speed Native `NSMenu` Presenters (100% Native `NSMenuItem`s!)

extension NativeSegmentContextMenuPresenter {
    public func presentAspectRatioMenu(session: ProjectSession, below buttonView: NSView?) {
        let menu = NSMenu(title: String(localized: "Output Aspect Ratio"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        // 1. Auto item
        let autoItem = makeCommandItem(title: "Auto", keyEquivalent: "", modifiers: []) {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                session.mutate { $0.canvas.aspectRatioMode = .auto }
                session.isReelModeActive = false
            }
        }
        autoItem.state = (session.document.canvas.aspectRatioMode == .auto) ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        // 2. Preset items (`Wide 16:9`, `Square 1:1`, `Classic 4:3`, `Vertical 9:16`, `Tall 3:4`, `Portrait 4:5`)
        let presets: [AspectRatioPreset] = [
            .widescreen16x9,
            .square1x1,
            .classic4x3,
            .vertical9x16,
            .tall3x4,
            .portrait4x5
        ]

        for preset in presets {
            let isSelected = (session.document.canvas.aspectRatioMode == .preset && session.document.canvas.aspectRatioPreset == preset)
            let item = makeCommandItem(title: preset.label, keyEquivalent: "", modifiers: []) {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = preset
                    }
                    if ![AspectRatioPreset.vertical9x16, .tall3x4, .portrait4x5].contains(preset) {
                        session.isReelModeActive = false
                    }
                }
            }
            item.state = isSelected ? .on : .off
            item.image = Self.makeAspectRatioIconNSImage(iconSize: preset.iconSize)
            menu.addItem(item)
        }

        activeMenu = menu
        popUpBelowSubToolbarButton(menu: menu, buttonView: buttonView)
    }

    public func presentReelModeMenu(session: ProjectSession, below buttonView: NSView? = nil) {
        let menu = NSMenu(title: String(localized: "Reel Mode"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        // 1. Disable / Enable
        let toggleTitle = session.isReelModeActive ? "Disable" : "Enable"
        let toggleItem = makeCommandItem(title: toggleTitle, keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.isReelModeActive.toggle()
            }
        }
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // 2. Instagram (With native checkmark `✓` on the left when selected)
        let igItem = makeCommandItem(title: "Instagram", keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.reelPlatformStyle = .instagramReels
                session.isReelModeActive = true
            }
        }
        igItem.state = (session.isReelModeActive && session.reelPlatformStyle == .instagramReels) ? .on : .off
        menu.addItem(igItem)

        // 3. TikTok (With native checkmark `✓` on the left when selected)
        let ttItem = makeCommandItem(title: "TikTok", keyEquivalent: "", modifiers: []) {
            withAnimation(.easeInOut(duration: 0.22)) {
                session.reelPlatformStyle = .tiktok
                session.isReelModeActive = true
            }
        }
        ttItem.state = (session.isReelModeActive && session.reelPlatformStyle == .tiktok) ? .on : .off
        menu.addItem(ttItem)

        activeMenu = menu
        popUpBelowSubToolbarButton(menu: menu, buttonView: buttonView)
    }

    public func presentPlaybackSpeedMenu(session: ProjectSession) {
        let menu = NSMenu(title: String(localized: "Playback Speed"))
        menu.autoenablesItems = false
        retainedTargets.removeAll()

        for rate in [0.25, 0.5, 1.0, 1.25, 1.5, 2.0] {
            let item = makeCommandItem(title: String(format: "%gx", rate), keyEquivalent: "", modifiers: []) {
                session.previewPlaybackRate = rate
            }
            item.state = abs(session.previewPlaybackRate - rate) < 0.03 ? .on : .off
            menu.addItem(item)
        }

        activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        if let win = NSApp.keyWindow, let contentView = win.contentView {
            let menuH = max(160.0, menu.size.height)
            let topLeftScreenPt = NSPoint(x: mouseLoc.x - 28, y: mouseLoc.y + menuH + 10)
            let ptInWin = win.convertPoint(fromScreen: topLeftScreenPt)
            let ptInView = contentView.convert(ptInWin, from: nil)
            menu.popUp(positioning: nil, at: ptInView, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouseLoc, in: nil)
        }
    }

    private func popUpBelowSubToolbarButton(menu: NSMenu, buttonView: NSView?) {
        if let v = buttonView {
            let origin = NSPoint(x: 0, y: v.isFlipped ? v.bounds.maxY + 4 : -4)
            menu.popUp(positioning: nil, at: origin, in: v)
        } else {
            let mouseLoc = NSEvent.mouseLocation
            if let win = NSApp.keyWindow, let contentView = win.contentView {
                let ptInWin = win.convertPoint(fromScreen: mouseLoc)
                let ptInView = contentView.convert(ptInWin, from: nil)
                menu.popUp(positioning: nil, at: NSPoint(x: ptInView.x - 24, y: ptInView.y - 12), in: contentView)
            } else {
                menu.popUp(positioning: nil, at: mouseLoc, in: nil)
            }
        }
    }

    private static func makeAspectRatioIconNSImage(iconSize: CGSize) -> NSImage {
        let canvasSize = NSSize(width: 18, height: 16)
        let img = NSImage(size: canvasSize, flipped: false) { _ in
            let rect = NSRect(
                x: (canvasSize.width - iconSize.width) * 0.5,
                y: (canvasSize.height - iconSize.height) * 0.5,
                width: iconSize.width,
                height: iconSize.height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.0, yRadius: 2.0)
            path.lineWidth = 1.4
            NSColor.black.setStroke()
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
            context.stroke(outerPath, with: .color(.ink.opacity(0.92)), lineWidth: 1.4)

            var inner1 = Path()
            inner1.move(to: CGPoint(x: outerRect.minX, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.maxY))
            context.stroke(inner1, with: .color(.ink.opacity(0.85)), lineWidth: 1.2)

            var inner2 = Path()
            inner2.move(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.minY + outerRect.height * 0.42))
            inner2.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.maxY))
            context.stroke(inner2, with: .color(.ink.opacity(0.85)), lineWidth: 1.2)
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
        let color = isActive ? Color(red: 0.58, green: 0.52, blue: 1.0) : Color.ink.opacity(0.88)
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
