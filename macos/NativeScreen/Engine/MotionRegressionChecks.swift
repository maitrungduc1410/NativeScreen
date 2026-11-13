import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Opt-in CLI checks with synthetic inputs, including real GPU rasterization. Never runs in the editor.
@MainActor
enum MotionRegressionChecks {
    static func run(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var passed: [String] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
            guard condition() else { throw failure(name) }
            passed.append(name)
        }
        let size = MotionPointSize.reference
        // Accepted tip error at clicks and drags: 0.75 x 2 points (ADR-87).
        let anchorBudget = CursorPathPlanner.Tolerance.click * CursorPathPlanner.Settings.standard.acceptedErrorRatio + 1e-6
        func solver(_ doc: ProjectDocument, _ cursor: [CursorSampleEvent], _ clicks: [ClickEvent] = [],
                    pointSize: MotionPointSize? = nil) -> PlaybackTrajectorySolver {
            PlaybackTrajectorySolver(durationMs: 12000, cursorEvents: cursor, clickEvents: clicks,
                                     document: doc, pointSize: pointSize ?? size)
        }
        func document() -> ProjectDocument {
            var doc = ProjectDocument(name: "Motion checks")
            doc.timeline.slices = [ClipSlice(sourceStartMs: 0, sourceEndMs: 12000)]
            doc.cursor.stopMovementInLastPartMs = 0
            doc.camera.enabled = false
            return doc
        }
        let stationary = [CursorSampleEvent(t: 0, x: 0.7, y: 0.4), CursorSampleEvent(t: 12000, x: 0.7, y: 0.4)]
        var cropDoc = document()
        cropDoc.canvas.cropRect01 = Rect01(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
        cropDoc.timeline.zooms = [ZoomBlock(sourceStartMs: 500, sourceEndMs: 4000, scale: 2,
                                           mode: .manual, manualCenter01: Point01(x: 0.5, y: 0.4), instantAnimation: true)]
        let cropped = solver(cropDoc, stationary).evaluate(atTimelineMs: 1000)
        try check("crop keeps original cursor coordinates", abs(cropped.cursor.position01.x - 0.7) < 1e-9)
        try check("crop remaps drawn cursor to 0.9", abs(MotionGeometry.cropped(cropped.cursor.position01, by: cropDoc.canvas.cropRect01).x - 0.9) < 1e-9)
        try check("crop remaps manual focus", abs(cropped.camera.center01.y - 1.0 / 3.0) < 1e-9)
        try check("crop preserves outside coordinates", MotionGeometry.cropped(Point01(x: 0.1, y: 0.1), by: cropDoc.canvas.cropRect01).x < 0)
        cropDoc.timeline.zooms[0].presentation = .loupe
        cropDoc.timeline.zooms[0].manualCenter01.x = 0.7
        let cropLoupe = solver(cropDoc, stationary).evaluate(atTimelineMs: 1000).camera
        try check("crop remaps independent loupe focus", abs(cropLoupe.loupeCenter01.x - 0.9) < 1e-9)
        cropDoc.timeline.isZoomTrackHidden = true
        let hiddenZoom = solver(cropDoc, stationary).evaluate(atTimelineMs: 1000).camera
        try check("hidden zoom track disables screen and lens", hiddenZoom.scale == 1 && hiddenZoom.loupePresence01 == 0)

        let cursor = (0...720).map { i in
            CursorSampleEvent(t: Double(i) * 1000 / 120, x: 0.1 + Double(i) / 900, y: 0.3 + Double(i) / 1800)
        }
        let clicks = [ClickEvent(t: 1003.5, type: "down", x: 0.2338, y: 0.3669),
                      ClickEvent(t: 2309.1, type: "up", x: 0.4079, y: 0.45395)]
        var interactionDoc = document()
        interactionDoc.cursor.removeShakeThresholdPx = 8
        let interaction = solver(interactionDoc, cursor, clicks)
        for click in clicks {
            let tip = interaction.evaluate(atTimelineMs: click.t).cursor.position01
            try check("tip reaches \(click.type) within planner tolerance at fractional timestamp", size.distance(tip, Point01(x: click.x, y: click.y)) <= anchorBudget)
        }
        var worstDragError = 0.0
        for t in stride(from: 1020.3, through: 2290.0, by: 7.13) {
            let raw = CursorTelemetry.sample(cursor, at: t)
            let tip = interaction.evaluate(atTimelineMs: t).cursor.position01
            worstDragError = max(worstDragError, size.distance(tip, Point01(x: raw.x, y: raw.y)))
        }
        try check("drag error within planner tolerance", worstDragError <= anchorBudget)
        let wave = interaction.evaluate(atTimelineMs: 1100).cursor.clickWaves.last
        try check("click wave stays on down anchor", wave?.position01 == Point01(x: clicks[0].x, y: clicks[0].y))
        interactionDoc.cursor.smoothMovementEnabled = false
        interactionDoc.cursor.removeShakeThresholdPx = 0
        let direct = solver(interactionDoc, cursor).evaluate(atTimelineMs: 1500).cursor.position01
        try check("disabled smoothing keeps raw position", abs(direct.x - 0.3) < 1e-9)
        var slowDoc = interactionDoc
        slowDoc.timeline.slices[0].speed = 0.25
        let sixtyHz = (0...60).map { i in CursorSampleEvent(t: Double(i) * 1000 / 60, x: 0.2 + Double(i) / 300, y: 0.5) }
        let slowTip = solver(slowDoc, sixtyHz).evaluate(atTimelineMs: 501).cursor.position01.x
        try check("slow 60 Hz footage does not become stationary holds", abs(slowTip - (0.2 + 125.25 / 5000)) < 1e-9)
        var narrowDoc = document()
        narrowDoc.cursor.smoothMovementEnabled = false
        narrowDoc.cursor.removeShakeThresholdPx = 4
        let smallMove = [CursorSampleEvent(t: 0, x: 0.5, y: 0.5), CursorSampleEvent(t: 100, x: 0.503, y: 0.5)]
        let small = solver(narrowDoc, smallMove, pointSize: MotionPointSize(width: 800, height: 600))
        let large = solver(narrowDoc, smallMove, pointSize: MotionPointSize(width: 3200, height: 1800))
        try check("shake threshold measures capture points", small.evaluate(atTimelineMs: 500).cursor.position01.x == 0.5
                  && large.evaluate(atTimelineMs: 500).cursor.position01.x == 0.503)
        narrowDoc.cursor.removeShakeThresholdPx = 0
        narrowDoc.cursor.rotationMode = .follow
        narrowDoc.cursor.velocityRotationEnabled = true
        let diagonal = (0...240).map { i in CursorSampleEvent(t: Double(i) * 1000 / 120, x: 0.2 + Double(i) / 1200, y: 0.2 + Double(i) / 1200) }
        let bearing = solver(narrowDoc, diagonal, pointSize: MotionPointSize(width: 1600, height: 800)).evaluate(atTimelineMs: 1200).cursor.rotationRadians
        let expectedBearing = -atan(0.5) - .pi * 0.75 - narrowDoc.cursor.baseRotationDegrees * .pi / 180
        try check("follow heading uses physical aspect ratio", abs(bearing - expectedBearing) < 0.001)

        var one = document()
        one.timeline.zooms = [ZoomBlock(sourceStartMs: 1000, sourceEndMs: 3000, scale: 2, mode: .manual)]
        var two = one
        two.timeline.slices[0].speed = 2
        let a = solver(one, stationary).evaluate(atTimelineMs: 1300).camera
        let b = solver(two, stationary).evaluate(atTimelineMs: 800).camera
        try check("zoom spring response uses playback milliseconds", abs(a.scale - b.scale) < 1e-9)
        let late = solver(one, stationary).evaluate(atTimelineMs: 2999).camera.scale
        let after = solver(one, stationary).evaluate(atTimelineMs: 3200).camera.scale
        try check("zoom exit starts after item end", late > 1.99 && after < late && after > 1)
        var cutDoc = document()
        cutDoc.timeline.slices = [ClipSlice(sourceStartMs: 0, sourceEndMs: 1003.5), ClipSlice(sourceStartMs: 6000, sourceEndMs: 9000)]
        cutDoc.timeline.zooms = [ZoomBlock(sourceStartMs: 5000, sourceEndMs: 8000, scale: 3, mode: .manual, manualCenter01: Point01(x: 0.7, y: 0.3))]
        let cutCursor = [CursorSampleEvent(t: 0, x: 0.1, y: 0.2), CursorSampleEvent(t: 5999, x: 0.8, y: 0.6), CursorSampleEvent(t: 12000, x: 0.8, y: 0.6)]
        let cut = solver(cutDoc, cutCursor)
        let cutState = cut.evaluate(atTimelineMs: 1003.5)
        try check("cut resets cursor without interpolation across boundary", cutState.cursor.position01.x == 0.8)
        try check("cut initializes active zoom without discarded history", cutState.camera.scale == 3)
        try check("cut boundary maps to incoming slice", NLETimeMapper(slices: cutDoc.timeline.slices).sourceTime(forTimelineMs: 1003.5).sourceMs == 6000)
        try check("motion blur cannot cross a cut", !cut.isSameRun(1003.5, 1000))
        cutDoc.timeline.slices = [ClipSlice(sourceStartMs: 0, sourceEndMs: 3000, speed: 1), ClipSlice(sourceStartMs: 3000, sourceEndMs: 6000, speed: 2)]
        let continuous = solver(cutDoc, cursor)
        try check("source-contiguous speed changes share motion history", continuous.isSameRun(3001, 2999))
        cutDoc.timeline.slices = [ClipSlice(sourceStartMs: 0, sourceEndMs: 1000), ClipSlice(sourceStartMs: 0, sourceEndMs: 1000, hideCursor: true)]
        let repeated = solver(cutDoc, cursor)
        try check("reused source ranges get separate trajectories", !repeated.isSameRun(1100, 100))
        let repeatedMap = NLETimeMapper(slices: cutDoc.timeline.slices)
        try check("final frame retains last source occurrence", repeatedMap.timelineTime(forSourceMs: 1000, withinSliceAtTimelineMs: 2000) == 2000)
        var heldDoc = document()
        heldDoc.timeline.slices = [ClipSlice(sourceStartMs: 1500, sourceEndMs: 3000)]
        let held = solver(heldDoc, cursor, clicks).evaluate(atTimelineMs: 30.5).cursor
        let heldRaw = CursorTelemetry.sample(cursor, at: 1530.5)
        try check("drag held through trim stays within planner tolerance", size.distance(held.position01, Point01(x: heldRaw.x, y: heldRaw.y)) <= anchorBudget)
        try check("trimmed drag does not synthesize a click ripple", held.clickWaves.isEmpty)

        // Recordings from before the first-frame epoch: telemetry runs late by the startup delay.
        try check("current recordings keep their clock", LegacyTelemetryEpoch.offsetMs(
            cursor: [CursorSampleEvent(t: 0, x: 0.5, y: 0.5), CursorSampleEvent(t: 12000, x: 0.5, y: 0.5)],
            clicks: [], keys: [], durationMs: 11990) == 0)
        let legacyCursor = [CursorSampleEvent(t: 1319, x: 0.2, y: 0.2), CursorSampleEvent(t: 1400, x: 0.3, y: 0.2),
                            CursorSampleEvent(t: 13079, x: 0.4, y: 0.4)]
        let legacyClicks = [ClickEvent(t: 1200, type: "down", x: 0.2, y: 0.2), ClickEvent(t: 6137, type: "down", x: 0.3, y: 0.2)]
        let legacyOffset = LegacyTelemetryEpoch.offsetMs(cursor: legacyCursor, clicks: legacyClicks, keys: [], durationMs: 11803)
        try check("legacy telemetry offset is how far events run past the video", abs(legacyOffset - 1276) < 1e-9)
        let legacy = LegacyTelemetryEpoch.corrected(cursor: legacyCursor, clicks: legacyClicks, keys: [], offsetMs: legacyOffset)
        try check("legacy correction drops events from before capture", legacy.clicks.count == 1 && abs(legacy.clicks[0].t - 4861) < 1e-9)
        try check("legacy correction keeps every cursor sample on the video clock", legacy.cursor.count == 3 && abs(legacy.cursor[0].t - 43) < 1e-9)
        let farClick = CursorTelemetry.insertingClicks([ClickEvent(t: 50, type: "down", x: 0.9, y: 0.9)],
            into: [CursorSampleEvent(t: 0, x: 0.1, y: 0.1), CursorSampleEvent(t: 100, x: 0.1, y: 0.1)], holdPauses: false, pointSize: size)
        try check("a click far from the recorded cursor does not move the path", farClick.allSatisfy { $0.x == 0.1 })
        let warpClick = CursorTelemetry.insertingClicks([ClickEvent(t: 50, type: "up", x: 0.1, y: 0.1)],
            into: [CursorSampleEvent(t: 45, x: 0.1, y: 0.1), CursorSampleEvent(t: 57, x: 0.6, y: 0.6)], holdPauses: false, pointSize: size)
        try check("a click just before a cursor warp keeps its position", warpClick.contains { $0.t == 50 && $0.x == 0.1 })

        // Right-to-left captions put the first word on the right, in every reveal style.
        func captionWords(_ text: String, _ style: CaptionStyle, at t: Double) -> [CaptionLineLayout.DrawnWord] {
            var captions = ProjectDocument(name: "Captions").captions
            let track = CaptionTrack(name: "Captions", style: style)
            captions.captionTracks = [track]
            captions.captionBlocks = [CaptionBlock(trackId: track.id, sourceStartMs: 0, sourceEndMs: 2000, customText: text)]
            return CaptionLineLayout.frames(in: captions, at: t, stageSize: CGSize(width: 1280, height: 720)).first?.words ?? []
        }
        let arabic = "مرحبا بكم في التطبيق"
        try check("caption direction comes from the first strong letter",
                  CaptionLineLayout.isRightToLeft(arabic) && CaptionLineLayout.isRightToLeft("2026 שלום")
                  && !CaptionLineLayout.isRightToLeft("Hello مرحبا") && !CaptionLineLayout.isRightToLeft("123"))
        for (name, style) in [("line", CaptionStyle()), ("full line", CaptionStyle(lineGrowth: .fullLine)),
                              ("slide in", CaptionStyle(wordAnimation: .slideIn)), ("fade in", CaptionStyle(wordAnimation: .fadeIn))] {
            let rtl = captionWords(arabic, style, at: 1990)
            let ltr = captionWords("Welcome to the app", style, at: 1990)
            try check("right-to-left caption (\(name)) reads from the right",
                      rtl.count == 4 && zip(rtl, rtl.dropFirst()).allSatisfy { $0.rect.minX > $1.rect.maxX })
            try check("left-to-right caption (\(name)) still reads from the left",
                      ltr.count == 4 && zip(ltr, ltr.dropFirst()).allSatisfy { $0.rect.maxX < $1.rect.minX })
        }
        let firstWordOnly = captionWords(arabic, CaptionStyle(), at: 100)
        let fullLine = captionWords(arabic, CaptionStyle(), at: 1990)
        try check("right-to-left caption grows from the right edge",
                  firstWordOnly.count == 1 && abs(firstWordOnly[0].rect.maxX - fullLine[0].rect.maxX) < 0.5)

        // A fast flick that ends on a click: the tip must arrive on time without a snap, and keep the spring's glide.
        func ease(_ u: Double) -> Double { u * u * (3 - 2 * u) }
        let flick = (0...480).map { i -> CursorSampleEvent in
            let t = Double(i) * 1000 / 120
            let u = max(0, min(1, (t - 500) / 150))
            return CursorSampleEvent(t: t, x: 0.2 + 0.5 * ease(u), y: 0.3 + 0.2 * ease(u))
        }
        var flickDoc = document()
        flickDoc.cursor.removeShakeThresholdPx = 0
        for (syncHovers, gap) in [(true, 0.0), (false, 0.0), (true, 80.0)] {
            flickDoc.cursor.keepInSyncWithHovers = syncHovers
            let clickMs = 650 + gap
            let flickSolver = solver(flickDoc, flick, [ClickEvent(t: clickMs, type: "down", x: 0.7, y: 0.5),
                                                       ClickEvent(t: clickMs + 80, type: "up", x: 0.7, y: 0.5)])
            let label = "hover sync \(syncHovers), click \(Int(gap)) ms after the flick"
            try check("\(label): tip reaches the click", size.distance(flickSolver.evaluate(atTimelineMs: clickMs).cursor.position01, Point01(x: 0.7, y: 0.5)) <= anchorBudget)
            var previous = flickSolver.evaluate(atTimelineMs: 0).cursor.position01
            var previousSpeed = 0.0, worstJump = 0.0, peakSpeed = 0.0, rawPeak = 0.0
            var previousRaw = CursorTelemetry.sample(flick, at: 0)
            for frame in 1...150 {
                let t = Double(frame) * 1000 / 60
                let p = flickSolver.evaluate(atTimelineMs: t).cursor.position01
                let raw = CursorTelemetry.sample(flick, at: t)
                let speed = size.distance(p, previous) / (1000 / 60)
                if frame > 1 { worstJump = max(worstJump, abs(speed - previousSpeed)) }
                peakSpeed = max(peakSpeed, speed)
                rawPeak = max(rawPeak, size.distance(Point01(x: raw.x, y: raw.y), Point01(x: previousRaw.x, y: previousRaw.y)) / (1000 / 60))
                previous = p; previousSpeed = speed; previousRaw = raw
            }
            try check("\(label): no frame-to-frame speed jump", worstJump < 0.25 * rawPeak)
            try check("\(label): keeps the spring glide", peakSpeed < 0.75 * rawPeak)
        }

        var loupeDoc = document()
        loupeDoc.timeline.zooms = [ZoomBlock(sourceStartMs: 0, sourceEndMs: 4000, scale: 2.4, mode: .followCursor, presentation: .loupe, instantAnimation: true)]
        let jitter = (0...240).map { i in CursorSampleEvent(t: Double(i) * 1000 / 120, x: 0.5 + sin(Double(i) * 0.15) * 0.02, y: 0.5) }
        let loupe = solver(loupeDoc, jitter)
        let centers = stride(from: 500.0, through: 1800, by: 20).map { loupe.evaluate(atTimelineMs: $0).camera.loupeCenter01.x }
        try check("loupe holds grouped focus with decorative drift only", (centers.max()! - centers.min()!) < 0.006)
        let independent = loupe.evaluate(atTimelineMs: 1000).camera
        try check("loupe and screen camera have independent centers", independent.center01 == .center && independent.loupeCenter01 != .center)
        loupeDoc.timeline.zooms = [ZoomBlock(sourceStartMs: 0, sourceEndMs: 2000, scale: 3, mode: .manual, manualCenter01: Point01(x: 0.7, y: 0.4)),
                                   ZoomBlock(sourceStartMs: 2000, sourceEndMs: 4000, scale: 2.4, mode: .manual, presentation: .loupe, manualCenter01: Point01(x: 0.2, y: 0.6))]
        let transition = solver(loupeDoc, stationary)
        let beforeTransition = transition.evaluate(atTimelineMs: 1999).camera
        let inTransition = transition.evaluate(atTimelineMs: 2001).camera
        try check("screen to loupe does not snap screen camera", inTransition.scale > 2.9 && abs(inTransition.center01.x - beforeTransition.center01.x) < 0.01)
        let prewarmError = abs(beforeTransition.loupeCenter01.x - 0.2)
        try check("invisible loupe prewarms during preceding screen zoom", beforeTransition.loupePresence01 <= 0.005 && prewarmError < 0.05)
        let merged = AutoZoomClusterGenerator.generateZooms(clicks: [ClickEvent(t: 1000, type: "down", x: 0.2, y: 0.3), ClickEvent(t: 6000, type: "down", x: 0.8, y: 0.7)], keys: [], durationMs: 12000)
        try check("nearby auto zoom intervals merge", merged.count == 1 && merged[0].sourceStartMs == 700 && merged[0].sourceEndMs == 8500)
        let separated = AutoZoomClusterGenerator.generateZooms(clicks: [ClickEvent(t: 1000, type: "down", x: 0.2, y: 0.3), ClickEvent(t: 6300, type: "down", x: 0.8, y: 0.7)], keys: [], durationMs: 12000)
        try check("merge interval threshold is strict", separated.count == 2)
        let typing = AutoZoomClusterGenerator.generateZooms(clicks: [ClickEvent(t: 1000, type: "down", x: 0.2, y: 0.3)],
            keys: [KeyStrokeEvent(t: 4000, kind: "typing"), KeyStrokeEvent(t: 6000, kind: "typing")], durationMs: 12000)
        try check("auto zoom retains chained typing hold", typing.count == 1 && typing[0].sourceEndMs == 7500)

        guard let compositor = MetalFrameCompositor(), EffectKernels.shared.lensPipeline != nil else { throw failure("GPU lens pipeline unavailable") }
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        var renderDoc = document()
        renderDoc.canvas.paddingRatio = 0
        renderDoc.frameStyle.borderRadius = 0
        renderDoc.frameStyle.inset.enabled = false
        renderDoc.frameStyle.shadow.enabled = false
        renderDoc.cursor.hidden = true
        renderDoc.background.type = .solid
        renderDoc.background.solidColor = "#000000"
        renderDoc.timeline.zooms = [ZoomBlock(sourceStartMs: 0, sourceEndMs: 4000, scale: 3, mode: .manual, presentation: .loupe, instantAnimation: true)]
        let session = try makeSession(renderDoc, cursor: stationary, size: PixelDimensions(width: 3840, height: 2160), root: root.appendingPathComponent("render.nativescreen"))
        let canvas = CGSize(width: 1280, height: 720)
        let stripes = try stripeImage()
        let exportFrame = compositor.composeFrame(sourceVideoFrame: stripes, sourceTimeMs: 1000, timelineTimeMs: 1000, session: session, outputSize: canvas)
        let exportImage = try raster(exportFrame, compositor: compositor, size: canvas)
        try writePNG(exportImage, to: root.appendingPathComponent("loupe-export.png"))
        let pixels = rgba(exportImage)
        let row = (610..<670).map { Int(pixels[(360 * 1280 + $0) * 4]) }
        let contrast = row.max()! - row.min()!
        try check("loupe retains source-pixel stripe contrast", contrast > 180)
        let previewFrame = compositor.composeFrame(sourceVideoFrame: stripes, sourceTimeMs: 1000, timelineTimeMs: 1000, session: session, outputSize: canvas, isRealtimePreview: true)
        let previewImage = try raster(previewFrame, compositor: compositor, size: canvas)
        try writePNG(previewImage, to: root.appendingPathComponent("loupe-preview.png"))
        try check("paused preview and export have identical lens pixels", rgba(previewImage) == pixels)
        session.mutate { doc in
            doc.timeline.maskTracks = [MaskTrack(name: "Privacy", items: [MaskItem(sourceStartMs: 0, sourceEndMs: 4000, type: .blur, style: .solid, intensity: 1,
                                                                                 keyframes: [MaskKeyframe(sourceMs: 0, rect01: .full)])])]
        }
        let masked = try raster(compositor.composeFrame(sourceVideoFrame: white, sourceTimeMs: 1000, timelineTimeMs: 1000, session: session, outputSize: canvas), compositor: compositor, size: canvas)
        try check("sharp loupe cannot bypass privacy masks", rgba(masked)[(360 * 1280 + 640) * 4] < 40)
        session.mutate { doc in doc.timeline.zooms.removeAll(); doc.timeline.maskTracks.removeAll(); doc.cursor.hidden = false; doc.cursor.smoothMovementEnabled = false
            doc.canvas.cropRect01 = Rect01(x: 0.25, y: 0.2, width: 0.5, height: 0.6)
            doc.cursor.customPointer = CustomCursorImage(imagePath: "assets/pointer.png", hotspot01: .center)
        }
        let red = try raster(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), compositor: compositor, size: CGSize(width: 64, height: 64))
        try writePNG(red, to: session.packageURL.appendingPathComponent("assets/pointer.png"))
        let cropFrame = try raster(compositor.composeFrame(sourceVideoFrame: white, sourceTimeMs: 1000, timelineTimeMs: 1000, session: session, outputSize: canvas), compositor: compositor, size: canvas)
        try writePNG(cropFrame, to: root.appendingPathComponent("crop-cursor.png"))
        let cropSize = CGSize(width: 1920, height: 1296)
        let stage = MetalFrameCompositor.resolvedStageLayout(session: session, sourceTimeMs: 1000, canvasRect: CGRect(origin: .zero, size: canvas), screenSourceSize: cropSize, zoomScale: 1)
        let target = MotionGeometry.cropped(Point01(x: 0.7, y: 0.4), by: session.document.canvas.cropRect01)
        let x = Int(stage.screenRect.minX + CGFloat(target.x) * stage.screenRect.width)
        let y = Int(canvas.height - (stage.screenRect.minY + CGFloat(1 - target.y) * stage.screenRect.height))
        let cropPixels = rgba(cropFrame)
        try check("GPU draws crop-relative cursor at expected point", cropPixels[(y * 1280 + x) * 4] > 200 && cropPixels[(y * 1280 + x) * 4 + 1] < 30)
        session.mutate { $0.timeline.zooms = [ZoomBlock(sourceStartMs: 0, sourceEndMs: 4000, scale: 2, mode: .manual, manualCenter01: Point01(x: 0.5, y: 0.4), instantAnimation: true)] }
        let cropCamera = session.trajectorySolver.evaluate(atTimelineMs: 1000).camera.center01.y
        session.mutate { $0.canvas.cropRect01 = .full }
        let fullCamera = session.trajectorySolver.evaluate(atTimelineMs: 1000).camera.center01.y
        try check("crop edit invalidates camera trajectory", abs(cropCamera - fullCamera) > 0.05)
        session.mutate { doc in
            doc.timeline.zooms.removeAll()
            doc.timeline.slices = [ClipSlice(sourceStartMs: 0, sourceEndMs: 2000),
                                   ClipSlice(sourceStartMs: 0, sourceEndMs: 2000, hideCursor: true)]
        }
        let visibleRepeated = try raster(compositor.composeFrame(sourceVideoFrame: white, sourceTimeMs: 500, timelineTimeMs: 500, session: session, outputSize: canvas), compositor: compositor, size: canvas)
        let hiddenRepeated = try raster(compositor.composeFrame(sourceVideoFrame: white, sourceTimeMs: 500, timelineTimeMs: 2500, session: session, outputSize: canvas), compositor: compositor, size: canvas)
        let repeatedPixel = (288 * 1280 + 896) * 4
        try check("GPU shows cursor in first source occurrence", rgba(visibleRepeated)[repeatedPixel + 1] < 30)
        try check("GPU hides cursor in reused source slice", rgba(hiddenRepeated)[repeatedPixel + 1] > 240)
        try check("slice edit invalidates playback trajectories", session.timeMapper.totalTimelineDurationMs == 4000
                  && !session.trajectorySolver.isSameRun(500, 2500))
        try check("rendering leaves raw telemetry unchanged", session.cursorEvents == stationary)
        // An Arabic caption, to look at: words read from the right.
        let captionTimelineMs = session.timeMapper.totalTimelineDurationMs - 20
        let captionSourceMs = session.timeMapper.sourceTime(forTimelineMs: captionTimelineMs).sourceMs
        session.mutate { doc in
            let track = CaptionTrack(name: "Captions")
            doc.captions.enabled = true
            doc.captions.captionTracks = [track]
            doc.captions.captionBlocks = [CaptionBlock(trackId: track.id, sourceStartMs: max(0, captionSourceMs - 600),
                                                       sourceEndMs: captionSourceMs + 10, customText: arabic)]
        }
        let captionImage = try raster(compositor.composeFrame(sourceVideoFrame: white, sourceTimeMs: captionSourceMs, timelineTimeMs: captionTimelineMs, session: session, outputSize: canvas, includeShortcutOverlay: true), compositor: compositor, size: canvas)
        if let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("caption-rtl.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, captionImage, nil)
            CGImageDestinationFinalize(destination)
        }
        let report: [String: Any] = ["passed": passed.count, "checks": passed, "worstDragErrorPt": worstDragError,
                                   "lensStripeContrast255": contrast, "prewarmCenterError01": prewarmError]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("report.json"))
        fputs("motion checks: \(passed.count) passed, drag error \(worstDragError) pt, lens contrast \(contrast)/255\n", stderr)
    }

    private static func makeSession(_ document: ProjectDocument, cursor: [CursorSampleEvent], size: PixelDimensions, root: URL) throws -> ProjectSession {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("recording/telemetry"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        try encoder.encode(document).write(to: root.appendingPathComponent("project.json"))
        let metadata = RecordingMetadata(createdAt: "2026-01-01T00:00:00Z", durationMs: 12000,
            captureTarget: CaptureTargetMetadata(mode: .display, displayId: 1,
                logicalBounds: LogicalBounds(x: 0, y: 0, width: Double(size.width), height: Double(size.height)), pixelSize: size),
            tracks: RecordingTracksMetadata())
        try encoder.encode(metadata).write(to: root.appendingPathComponent("recording/metadata.json"))
        var telemetry = Data()
        for event in cursor { telemetry.append(try encoder.encode(event)); telemetry.append(10) }
        try telemetry.write(to: root.appendingPathComponent("recording/telemetry/cursor.jsonl"))
        try Data().write(to: root.appendingPathComponent("recording/telemetry/clicks.jsonl"))
        try Data().write(to: root.appendingPathComponent("recording/telemetry/keys.jsonl"))
        return try ProjectSession.load(from: root)
    }

    private static func stripeImage() throws -> CIImage {
        let width = 3840, height = 2160
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 2) {
                let index = (y * width + x) * 4
                bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private static func raster(_ image: CIImage, compositor: MetalFrameCompositor, size: CGSize) throws -> CGImage {
        guard let result = compositor.ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size)) else { throw failure("GPU rasterization") }
        return result
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw failure("PNG destination") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw failure("PNG output") }
    }

    private static func failure(_ name: String) -> NSError { NSError(domain: "NativeScreen.MotionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
}
