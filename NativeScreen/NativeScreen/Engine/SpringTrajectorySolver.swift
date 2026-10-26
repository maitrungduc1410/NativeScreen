import Foundation
import CoreGraphics

/// Pre-solves and caches 120Hz spring physics trajectories for both the cursor and the virtual camera
/// using the algorithm:
/// 1. **Stationary Dead-Zone Focus Groups (`MovesGroup` / `follow-click-groups`)**:
///    Instead of chasing every tiny cursor movement while zoomed in (which makes the camera jitter and causes motion sickness),
///    cursor events inside each zoom block are grouped into bounding-box clusters (`maxDistance = 0.5 / zoomScale`).
///    As long as the cursor moves within that half-viewport dead-zone, the camera target remains **100% stationary** at the
///    time-weighted centroid (`qo`) of the group!
/// 2. **Screen-Rect Space Interpolation (`rects.screen`)**:
///    Instead of springing `center` and `scale` independently (which causes curved/swimming trajectories),
///    we compute the target zoomed screen rectangle `(x, y, width, height)` via `Rect.zoom` + `containInZoomArea`
///    and animate all 4 components with the **exact same overdamped spring** so `center` and `scale` stay 100% locked in phase!
/// 3. **Overdamped / Dynamic Overshoot-Clamped Spring**:
///    Uses the `Smooth` (`stiffness: 170, damping: 50, mass: 3.0`, $\zeta \approx 1.11$) or `Focused`
///    (`stiffness: 250, damping: 40, mass: 2.25`) presets plus dynamic critical damping boost (`2 * sqrt(k * m)`)
///    so the camera NEVER bounces or wobbles back and forth!
public struct SpringTrajectorySolver: Sendable {
    public struct CursorFrameState: Sendable {
        public var position01: Point01
        public var velocity01PerSec: Point01
        public var rotationRadians: Double
        public var opacity: Double
        public var cursorType: String
        public var activeClickProgress: Double? // 0.0 -> 1.0 during click ripple
    }

    public struct CameraFrameState: Sendable {
        public var center01: Point01
        public var scale: Double
        public var velocity01PerSec: Point01
        public var scaleVelocityPerSec: Double
        public var isLoupeMode: Bool
        public var loupePresence01: Double
        public var loupeScale: Double
        public var loupeConfig: LoupeConfig
    }

    /// the `MovesGroup`:
    /// Groups consecutive cursor samples whose bounding box `(maxX - minX, maxY - minY)` fits within `maxDistance01`
    /// (`0.5 / zoomScale`, i.e. 50% of the zoomed viewport), and computes their time-weighted centroid (`function qo`).
    private struct CursorMovesGroup {
        struct Sample {
            let tMs: Double
            let x: Double
            let y: Double
        }

        let maxDistanceX: Double
        let maxDistanceY: Double
        var samples: [Sample] = []
        var minX: Double = .infinity
        var maxX: Double = -.infinity
        var minY: Double = .infinity
        var maxY: Double = -.infinity
        var finishedTimeMs: Double?

        var startTimeMs: Double {
            samples.first?.tMs ?? 0.0
        }

        func canAdd(x: Double, y: Double) -> Bool {
            guard !samples.isEmpty else { return true }
            let nextMinX = min(minX, x)
            let nextMaxX = max(maxX, x)
            let nextMinY = min(minY, y)
            let nextMaxY = max(maxY, y)
            return (nextMaxX - nextMinX) <= maxDistanceX && (nextMaxY - nextMinY) <= maxDistanceY
        }

        mutating func add(tMs: Double, x: Double, y: Double) {
            samples.append(Sample(tMs: tMs, x: x, y: y))
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        /// Time-weighted centroid:
        /// Weights each cursor position by how long the cursor stayed there before moving to the next sample!
        var timeWeightedCenter01: Point01 {
            guard !samples.isEmpty else { return .center }
            var totalWeightSec = 0.0
            var sumX = 0.0
            var sumY = 0.0

            for i in 0..<samples.count {
                let s = samples[i]
                let nextTimeMs: Double
                if i + 1 < samples.count {
                    nextTimeMs = samples[i + 1].tMs
                } else if let fin = finishedTimeMs {
                    nextTimeMs = fin
                } else {
                    nextTimeMs = s.tMs + 100.0
                }
                let weightSec = max(0.001, (nextTimeMs - s.tMs) / 1000.0)
                totalWeightSec += weightSec
                sumX += s.x * weightSec
                sumY += s.y * weightSec
            }

            guard totalWeightSec > 0 else {
                return Point01(x: samples[0].x, y: samples[0].y)
            }
            return Point01(x: sumX / totalWeightSec, y: sumY / totalWeightSec)
        }
    }

    private let stepMs: Double = 1000.0 / 120.0 // 8.333 ms (120 Hz)
    private let durationMs: Double
    private let cursorStates: [CursorFrameState]
    private let cameraStates: [CameraFrameState]

    public init(
        durationMs: Double,
        cursorEvents: [CursorSampleEvent],
        clickEvents: [ClickEvent],
        document: ProjectDocument
    ) {
        let totalDuration = max(100.0, durationMs)
        self.durationMs = totalDuration
        let totalSteps = max(2, Int(ceil(totalDuration / stepMs)) + 1)

        // Upgrade any underdamped spring (`zeta < 0.72` or legacy `damping < 35`) automatically to the overdamped presets!
        let cursorSpring = Self.sanitizedCursorSpring(document.cursor.spring)
        let camSpring = Self.sanitizedCameraSpring(document.motion.cameraSpring)

        // 1. Pre-solve Cursor Trajectory at 120 Hz (With the Lookahead Lead Compensation `Uc` / `Fc` + Drag Sync + Overshoot Clamp `G`)
        //    In NativeScreen, a spring with `(stiffness: k, damping: c)` has a natural steady-state phase lag:
        //    `lagMs = (damping / stiffness) * 1000` (e.g. `70 / 470 * 1000 ≈ 149ms` for Smooth cursor).
        //    If the spring only chases `rawPosition(t)`, the rendered cursor is ALWAYS ~150ms late behind video highlights, clicks, and text selection drags!
        //    eliminates this lag via:
        //    a) `getTargetAt`: feeding the spring the future target position at `t + leadMs(t)` (`lagMs`),
        //    b) `speed` boost during active mouse-down/drag/click windows (`Kc = { click: 2, drag: 2 }`), scaling `k * speed^2` and `c * speed`
        //       so that during text selection (`mouseDown ... mouseUp`) and clicks, the cursor stays locked 1:1 to the real action on screen!
        var builtCursor: [CursorFrameState] = []
        builtCursor.reserveCapacity(totalSteps)

        let dt = stepMs / 1000.0
        let firstEventTimeMs = cursorEvents.first?.t ?? 0.0
        // Auto-correct legacy recordings where `TelemetryRecorder` started ~150-400ms before `SCStream`'s first video frame:
        let legacyStartupOffsetMs = (firstEventTimeMs > 60.0 && firstEventTimeMs < 900.0) ? firstEventTimeMs : 0.0

        let firstPos = cursorEvents.first.map { Point01(x: $0.x, y: $0.y) } ?? .center

        // Build mouse-down -> mouse-up drag intervals and click sync timestamps (adjusted by `legacyStartupOffsetMs`)
        let dragIntervals: [(startMs: Double, endMs: Double)] = Self.buildMouseDragIntervals(
            from: clickEvents,
            timeOffsetMs: legacyStartupOffsetMs,
            totalDurationMs: totalDuration
        )
        let clickTimestampsMs: [Double] = clickEvents.map { max(0.0, $0.t - legacyStartupOffsetMs) }

        // Steady-state spring phase lag
        let baseSpringLagMs: Double = document.cursor.smoothMovementEnabled
            ? min(240.0, max(0.0, (cursorSpring.damping / max(10.0, cursorSpring.stiffness)) * 1000.0))
            : 0.0
        let leadFactor: Double = document.cursor.keepInSyncWithHovers ? 1.0 : 0.72
        let effectiveLeadMs: Double = baseSpringLagMs * leadFactor

        var curX = firstPos.x
        var curY = firstPos.y
        var velX = 0.0
        var velY = 0.0
        var filteredTargetX = firstPos.x
        var filteredTargetY = firstPos.y
        var lastMoveTimeMs = 0.0
        var currentOpacity = 1.0
        var lastDirectionalBearingRad = 0.0
        var lastStableCursorKind = "arrow"
        var lastCursorKindChangeMs = -1000.0

        let shakeThreshold01 = max(0.0, document.cursor.removeShakeThresholdPx) / 1600.0
        let stopMoveCutoffMs = (document.cursor.loopBackToStartMs == nil && document.cursor.stopMovementInLastPartMs > 0)
            ? max(0.0, totalDuration - document.cursor.stopMovementInLastPartMs)
            : nil

        let eventCount = cursorEvents.count

        // Helper to sample recorded cursor position & kind at any `queryMs`
        func sampleRecordedCursor(at queryMs: Double) -> (x: Double, y: Double, kind: String) {
            guard eventCount > 0 else {
                return (firstPos.x, firstPos.y, "arrow")
            }
            let shiftedMs = queryMs + legacyStartupOffsetMs
            if shiftedMs <= cursorEvents[0].t {
                return (cursorEvents[0].x, cursorEvents[0].y, cursorEvents[0].c)
            }
            if shiftedMs >= cursorEvents[eventCount - 1].t {
                let last = cursorEvents[eventCount - 1]
                return (last.x, last.y, last.c)
            }
            // Binary search for `cursorEvents[lo].t <= shiftedMs < cursorEvents[lo + 1].t`
            var lo = 0
            var hi = eventCount - 1
            while hi - lo > 1 {
                let mid = (lo + hi) >> 1
                if cursorEvents[mid].t <= shiftedMs {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            let e0 = cursorEvents[lo]
            let e1 = cursorEvents[lo + 1]
            let span = max(0.001, e1.t - e0.t)
            // In (`Sc.writePositionAt`, `xc = 40ms`), if two recorded points are >40ms apart (cursor was stationary),
            // hold `e0` until `e1.t - 16ms` so the cursor doesn't drift early across long stationary pauses!
            if span > 48.0 {
                let moveWindowStart = e1.t - 16.0
                if shiftedMs <= moveWindowStart {
                    return (e0.x, e0.y, e0.c)
                }
                let moveFrac = max(0.0, min(1.0, (shiftedMs - moveWindowStart) / max(1.0, e1.t - moveWindowStart)))
                return (
                    e0.x + (e1.x - e0.x) * moveFrac,
                    e0.y + (e1.y - e0.y) * moveFrac,
                    e0.c
                )
            }
            let frac = max(0.0, min(1.0, (shiftedMs - e0.t) / span))
            return (
                e0.x + (e1.x - e0.x) * frac,
                e0.y + (e1.y - e0.y) * frac,
                e0.c
            )
        }

        for step in 0..<totalSteps {
            let tMs = Double(step) * stepMs
            let baseLookupMs = stopMoveCutoffMs.map { min(tMs, $0) } ?? tMs

            // Determine if we are inside or approaching a mouse-down drag (e.g., selecting text!) or click event:
            // (`Vc` / `gc` / `Uc.run`) boosts spring speed (`speed = 1.0 ... 6.4`) during clicks and drags
            // (`rampInStartMs = startMs - 250ms`, `rampOutEndMs = endMs + 300ms`), and scales `stiffness * speed^2`, `damping * speed`!
            var syncSpeedMultiplier = 1.0
            for drag in dragIntervals {
                if tMs >= drag.startMs - 220.0 && tMs <= drag.endMs + 260.0 {
                    if tMs < drag.startMs {
                        let ramp = (tMs - (drag.startMs - 220.0)) / 220.0
                        syncSpeedMultiplier = max(syncSpeedMultiplier, 1.0 + 3.2 * max(0.0, min(1.0, ramp)))
                    } else if tMs <= drag.endMs {
                        // During active drag / text highlight, keep spring super-tight (`speed = 4.2x`) so cursor finishes selecting at the exact millisecond the user releases the mouse!
                        syncSpeedMultiplier = max(syncSpeedMultiplier, 4.2)
                    } else {
                        let rampOut = 1.0 - (tMs - drag.endMs) / 260.0
                        syncSpeedMultiplier = max(syncSpeedMultiplier, 1.0 + 3.2 * max(0.0, min(1.0, rampOut)))
                    }
                }
            }
            for clickT in clickTimestampsMs {
                let delta = abs(tMs - clickT)
                if delta <= 180.0 {
                    let boost = 1.0 + 2.4 * (1.0 - delta / 180.0)
                    syncSpeedMultiplier = max(syncSpeedMultiplier, boost)
                }
            }

            // Lookahead lead time (`Uc.getTargetAt`: `t + leadAt(t)`):
            // Reduced proportionally when `syncSpeedMultiplier > 1` because a faster spring has proportionally smaller lag (`lagMs / speed`)!
            let currentLeadMs = effectiveLeadMs / syncSpeedMultiplier
            let lookaheadLookupMs = min(totalDuration, stopMoveCutoffMs.map { min(tMs + currentLeadMs, $0) } ?? (tMs + currentLeadMs))

            let sampledTarget = sampleRecordedCursor(at: lookaheadLookupMs)
            let sampledNow = sampleRecordedCursor(at: baseLookupMs)

            var rawTargetX = sampledTarget.x
            var rawTargetY = sampledTarget.y
            var cursorKind = sampledNow.kind

            if document.cursor.alwaysUsePointer {
                cursorKind = "arrow"
            } else if document.cursor.optimizeCursorChanges {
                if cursorKind != lastStableCursorKind {
                    if tMs - lastCursorKindChangeMs >= 90.0 {
                        lastStableCursorKind = cursorKind
                        lastCursorKindChangeMs = tMs
                    } else {
                        cursorKind = lastStableCursorKind
                    }
                }
            }

            if let loopMs = document.cursor.loopBackToStartMs, loopMs > 0, tMs > totalDuration - loopMs {
                let factor = max(0.0, min(1.0, (tMs - (totalDuration - loopMs)) / loopMs))
                rawTargetX = rawTargetX + (firstPos.x - rawTargetX) * factor
                rawTargetY = rawTargetY + (firstPos.y - rawTargetY) * factor
            }

            let dist = hypot(rawTargetX - filteredTargetX, rawTargetY - filteredTargetY)
            // During an active drag (selecting text), bypass shake filtering so every character selection step is tracked accurately
            let effectiveShakeThreshold = (syncSpeedMultiplier > 1.5) ? 0.0 : shakeThreshold01
            if dist > effectiveShakeThreshold {
                filteredTargetX = rawTargetX
                filteredTargetY = rawTargetY
                lastMoveTimeMs = tMs
            }

            if document.cursor.smoothMovementEnabled {
                // `Uc.run`: `k_eff = stiffness * speed^2`, `c_eff = damping * speed`
                let effectiveSpring = SpringConfig(
                    stiffness: cursorSpring.stiffness * syncSpeedMultiplier * syncSpeedMultiplier,
                    damping: cursorSpring.damping * syncSpeedMultiplier,
                    mass: cursorSpring.mass
                )
                (curX, velX) = Self.stepClampedSpring(
                    current: curX,
                    velocity: velX,
                    target: filteredTargetX,
                    spring: effectiveSpring,
                    dt: dt
                )
                (curY, velY) = Self.stepClampedSpring(
                    current: curY,
                    velocity: velY,
                    target: filteredTargetY,
                    spring: effectiveSpring,
                    dt: dt
                )
            } else {
                velX = (filteredTargetX - curX) / dt
                velY = (filteredTargetY - curY) / dt
                curX = filteredTargetX
                curY = filteredTargetY
            }

            if let idleLimit = document.cursor.hideWhenIdleAfterMs, idleLimit > 0 {
                let idleDuration = tMs - lastMoveTimeMs
                let targetOpacity = idleDuration > idleLimit ? 0.0 : 1.0
                currentOpacity += (targetOpacity - currentOpacity) * min(1.0, dt * 10.0)
            } else {
                currentOpacity = 1.0
            }

            let baseRad = -document.cursor.baseRotationDegrees * .pi / 180.0
            var dynamicRad = 0.0
            if document.cursor.velocityRotationEnabled {
                switch document.cursor.rotationMode {
                case .tilt:
                    let maxTilt = 0.35 // ~20 degrees max (`maxTiltDeg: 20` in NativeScreen)
                    let rawTilt = -velX * 0.14 * document.cursor.velocityRotationIntensity
                    dynamicRad = max(-maxTilt, min(maxTilt, rawTilt))
                case .follow:
                    let speed = hypot(velX, velY)
                    if speed > 0.04 {
                        let targetAngle = atan2(-velY, velX) - (.pi * 0.75)
                        var delta = targetAngle - lastDirectionalBearingRad
                        while delta > .pi { delta -= 2.0 * .pi }
                        while delta < -.pi { delta += 2.0 * .pi }
                        lastDirectionalBearingRad += delta * min(1.0, dt * 14.0)
                    }
                    dynamicRad = lastDirectionalBearingRad
                }
            }
            let rotation = baseRad + dynamicRad

            var activeRipple: Double? = nil
            let rippleDurationMs = 450.0
            for click in clickEvents where click.type == "down" {
                let adjClickT = max(0.0, click.t - legacyStartupOffsetMs)
                let elapsed = tMs - adjClickT
                if elapsed >= 0.0 && elapsed <= rippleDurationMs {
                    activeRipple = elapsed / rippleDurationMs
                }
            }

            builtCursor.append(
                CursorFrameState(
                    position01: Point01(x: curX, y: curY),
                    velocity01PerSec: Point01(x: velX, y: velY),
                    rotationRadians: rotation,
                    opacity: document.cursor.hidden ? 0.0 : currentOpacity,
                    cursorType: cursorKind,
                    activeClickProgress: activeRipple
                )
            )
        }
        self.cursorStates = builtCursor

        // 2. Pre-build `MovesGroup` Dead-Zone Focus Clusters for every Auto-Zoom Block
        let activeZooms = document.timeline.isZoomTrackHidden
            ? []
            : document.timeline.zooms.filter { !$0.disabled }.sorted { $0.sourceStartMs < $1.sourceStartMs }

        var zoomFocusGroups: [String: [CursorMovesGroup]] = [:]
        for zoom in activeZooms where zoom.mode == .followCursor {
            let zoomScale = max(1.0, zoom.scale)
            // the dead-zone size: `getVisibleSourcePart(zoom).multiply(0.5)` -> `0.5 / zoomScale`!
            let maxDist01 = 0.5 / zoomScale
            zoomFocusGroups[zoom.id] = Self.buildMovesGroupsForZoom(
                zoom: zoom,
                cursorEvents: cursorEvents,
                clickEvents: clickEvents,
                maxDistanceX: maxDist01,
                maxDistanceY: maxDist01
            )
        }

        // 3. Pre-solve Virtual Camera Trajectory in Screen-Rect Space
        // In normalized unzoomed screen coordinates where the unzoomed screen is `[0, 0, 1, 1]`:
        // - Unzoomed screen rect: `x = 0, y = 0, w = 1, h = 1`
        // - Zoomed screen rect at scale `S` focused at `(fx, fy)` and contained in `[0, 0, 1, 1]`:
        //   `w = S`, `h = S`
        //   `x = clamp(0.5 - fx * S, min: 1.0 - S, max: 0.0)`
        //   `y = clamp(0.5 - fy * S, min: 1.0 - S, max: 0.0)`
        // Because `x, y, w, h` are all animated with the exact same spring (`camSpring`),
        // the camera center and zoom scale move in 100% locked linear phase with ZERO curvilinear swimming!
        var builtCamera: [CameraFrameState] = []
        builtCamera.reserveCapacity(totalSteps)

        var rectX = 0.0
        var rectY = 0.0
        var rectW = 1.0
        var rectVelX = 0.0
        var rectVelY = 0.0
        var rectVelW = 0.0

        // For Loupe mode, track lens center, scale, and presence (`0.0 ... 1.0`) smoothly
        var loupeCenterX = 0.5
        var loupeCenterY = 0.5
        var loupeScaleVal = 1.0
        var loupePresenceVal = 0.0
        var loupeVelX = 0.0
        var loupeVelY = 0.0
        var loupeVelScale = 0.0
        var loupeVelPresence = 0.0
        var lastActiveLoupeCfg = LoupeConfig()
        var prevCenter01 = Point01.center

        for step in 0..<totalSteps {
            let tMs = Double(step) * stepMs
            let cursorAtStep = builtCursor[step].position01

            // Find active zoom block at `tMs`
            let activeZoom = activeZooms.first { z in
                tMs >= z.sourceStartMs && tMs <= z.sourceEndMs
            }

            var targetScale = 1.0
            var targetFocusX = 0.5
            var targetFocusY = 0.5
            var isLoupeActiveNow = false
            var targetLoupePresence = 0.0
            var targetLoupeScale = 1.0
            var targetLoupeFocusX = loupeCenterX
            var targetLoupeFocusY = loupeCenterY
            var loupeCfg = lastActiveLoupeCfg

            if let zoom = activeZoom {
                isLoupeActiveNow = (zoom.presentation == .loupe)
                if isLoupeActiveNow {
                    loupeCfg = zoom.loupe
                    lastActiveLoupeCfg = zoom.loupe
                    targetLoupePresence = 1.0
                    targetLoupeScale = max(1.0, zoom.scale)
                    // Subtle organic hover wobble
                    let wobbleX = sin((tMs / 15000.0) * 2.0 * .pi) * 0.008
                    let wobbleY = cos((tMs / 18000.0) * 2.0 * .pi) * 0.008
                    switch zoom.mode {
                    case .followCursor:
                        targetLoupeFocusX = min(1.0, max(0.0, cursorAtStep.x + wobbleX))
                        targetLoupeFocusY = min(1.0, max(0.0, cursorAtStep.y + wobbleY))
                    case .manual:
                        targetLoupeFocusX = zoom.manualCenter01.x
                        targetLoupeFocusY = zoom.manualCenter01.y
                    }
                    // While Loupe is active, the underlying screen stays unzoomed (`1.0x`)
                    targetScale = 1.0
                    targetFocusX = 0.5
                    targetFocusY = 0.5
                } else {
                    targetScale = max(1.0, zoom.scale)
                    switch zoom.mode {
                    case .followCursor:
                        if let groups = zoomFocusGroups[zoom.id], !groups.isEmpty {
                            let activeGroup = groups.last(where: { $0.startTimeMs <= tMs }) ?? groups[0]
                            let groupCenter = activeGroup.timeWeightedCenter01
                            targetFocusX = groupCenter.x
                            targetFocusY = groupCenter.y
                        } else {
                            targetFocusX = cursorAtStep.x
                            targetFocusY = cursorAtStep.y
                        }
                    case .manual:
                        targetFocusX = zoom.manualCenter01.x
                        targetFocusY = zoom.manualCenter01.y
                    }
                }
            } else {
                // Pre-warm `loupeCenterX/Y` towards an upcoming Loupe block so it spawns right on the cursor (`inactiveLoupeStandIn`)
                if let upcomingLoupe = activeZooms.first(where: { $0.presentation == .loupe && $0.sourceStartMs > tMs && $0.sourceStartMs - tMs <= 450.0 }) {
                    loupeCfg = upcomingLoupe.loupe
                    lastActiveLoupeCfg = upcomingLoupe.loupe
                    targetLoupeFocusX = (upcomingLoupe.mode == .manual) ? upcomingLoupe.manualCenter01.x : cursorAtStep.x
                    targetLoupeFocusY = (upcomingLoupe.mode == .manual) ? upcomingLoupe.manualCenter01.y : cursorAtStep.y
                }
            }

            // Compute target screen rect `(targetRectX, targetRectY, targetRectW)` using the `Rect.zoom` + `containInZoomArea`
            let targetRectW = targetScale
            var targetRectX = 0.5 - targetFocusX * targetScale
            var targetRectY = 0.5 - targetFocusY * targetScale

            if !isLoupeActiveNow && document.motion.avoidEmptyBoundsWhenZooming && targetScale > 1.0001 {
                // `containInZoomArea`: ensures `targetRectX` is in `[1.0 - targetScale, 0.0]` so the zoomed screen never shows empty margins!
                let minOrigin = 1.0 - targetScale
                targetRectX = min(0.0, max(minOrigin, targetRectX))
                targetRectY = min(0.0, max(minOrigin, targetRectY))
            }

            // Step the 3 screen-rect components `(rectX, rectY, rectW)` with the overshoot-clamped spring (or instantly if `zoom.instantAnimation == true`)!
            if activeZoom?.instantAnimation == true && !isLoupeActiveNow {
                rectX = targetRectX
                rectY = targetRectY
                rectW = targetRectW
                rectVelX = 0.0
                rectVelY = 0.0
                rectVelW = 0.0
            } else {
                (rectX, rectVelX) = Self.stepClampedSpring(
                    current: rectX,
                    velocity: rectVelX,
                    target: targetRectX,
                    spring: camSpring,
                    dt: dt
                )
                (rectY, rectVelY) = Self.stepClampedSpring(
                    current: rectY,
                    velocity: rectVelY,
                    target: targetRectY,
                    spring: camSpring,
                    dt: dt
                )
                (rectW, rectVelW) = Self.stepClampedSpring(
                    current: rectW,
                    velocity: rectVelW,
                    target: targetRectW,
                    spring: camSpring,
                    dt: dt
                )
            }

            // Step Loupe center, scale & presence with the 1.5x stiffer `loupeSpring`
            let loupeSpring = SpringConfig(
                stiffness: camSpring.stiffness * 1.5,
                damping: camSpring.damping * 1.22,
                mass: camSpring.mass
            )
            if activeZoom?.instantAnimation == true && isLoupeActiveNow {
                loupeCenterX = targetLoupeFocusX
                loupeCenterY = targetLoupeFocusY
                loupeScaleVal = targetLoupeScale
                loupePresenceVal = targetLoupePresence
                loupeVelX = 0.0
                loupeVelY = 0.0
                loupeVelScale = 0.0
                loupeVelPresence = 0.0
            } else {
                (loupeCenterX, loupeVelX) = Self.stepClampedSpring(
                    current: loupeCenterX,
                    velocity: loupeVelX,
                    target: targetLoupeFocusX,
                    spring: loupeSpring,
                    dt: dt
                )
                (loupeCenterY, loupeVelY) = Self.stepClampedSpring(
                    current: loupeCenterY,
                    velocity: loupeVelY,
                    target: targetLoupeFocusY,
                    spring: loupeSpring,
                    dt: dt
                )
                (loupeScaleVal, loupeVelScale) = Self.stepClampedSpring(
                    current: loupeScaleVal,
                    velocity: loupeVelScale,
                    target: targetLoupeScale,
                    spring: loupeSpring,
                    dt: dt
                )
                (loupePresenceVal, loupeVelPresence) = Self.stepClampedSpring(
                    current: loupePresenceVal,
                    velocity: loupeVelPresence,
                    target: targetLoupePresence,
                    spring: loupeSpring,
                    dt: dt
                )
            }

            let isLoupeVisible = (loupePresenceVal > 0.005)
            let solvedScale = max(1.0, rectW)
            let solvedCenter01: Point01
            if isLoupeVisible {
                solvedCenter01 = Point01(
                    x: min(1.0, max(0.0, loupeCenterX)),
                    y: min(1.0, max(0.0, loupeCenterY))
                )
            } else if solvedScale > 1.0001 {
                // Recover exact camera focus point `center01` from the interpolated screen rect `(rectX, rectY, rectW)`:
                // Since `rectX = 0.5 - center01.x * solvedScale`, `center01.x = (0.5 - rectX) / solvedScale`!
                var cx = (0.5 - rectX) / solvedScale
                var cy = (0.5 - rectY) / solvedScale
                if document.motion.avoidEmptyBoundsWhenZooming {
                    let halfSpan = 0.5 / solvedScale
                    cx = max(halfSpan, min(1.0 - halfSpan, cx))
                    cy = max(halfSpan, min(1.0 - halfSpan, cy))
                }
                solvedCenter01 = Point01(x: cx, y: cy)
            } else {
                solvedCenter01 = .center
            }

            let centerVelX = (solvedCenter01.x - prevCenter01.x) / dt
            let centerVelY = (solvedCenter01.y - prevCenter01.y) / dt
            prevCenter01 = solvedCenter01

            builtCamera.append(
                CameraFrameState(
                    center01: solvedCenter01,
                    scale: solvedScale,
                    velocity01PerSec: Point01(x: centerVelX, y: centerVelY),
                    scaleVelocityPerSec: rectVelW,
                    isLoupeMode: isLoupeVisible,
                    loupePresence01: min(1.0, max(0.0, loupePresenceVal)),
                    loupeScale: max(1.0, loupeScaleVal),
                    loupeConfig: loupeCfg
                )
            )
        }

        self.cameraStates = builtCamera
    }

    // MARK: - Spring Sanitization & the Exact Overshoot-Clamped Spring Integrator

    /// Builds `[mouseDown ... mouseUp]` intervals so that during active drags (such as text selection / slider dragging),
    /// the cursor spring is boosted to stay 100% locked with the screen highlight.
    private static func buildMouseDragIntervals(
        from clickEvents: [ClickEvent],
        timeOffsetMs: Double,
        totalDurationMs: Double
    ) -> [(startMs: Double, endMs: Double)] {
        var intervals: [(startMs: Double, endMs: Double)] = []
        var activeDownMs: Double? = nil

        for ev in clickEvents.sorted(by: { $0.t < $1.t }) {
            let t = max(0.0, ev.t - timeOffsetMs)
            if ev.type == "down" {
                if activeDownMs == nil {
                    activeDownMs = t
                }
            } else if ev.type == "up" {
                if let start = activeDownMs {
                    if t > start + 25.0 {
                        intervals.append((startMs: start, endMs: t))
                    }
                    activeDownMs = nil
                }
            }
        }
        if let unclosedStart = activeDownMs, totalDurationMs > unclosedStart + 25.0 {
            intervals.append((startMs: unclosedStart, endMs: totalDurationMs))
        }
        return intervals
    }

    /// Upgrades any legacy underdamped camera spring (`zeta < 0.80` or `damping < 30`) to the overdamped `Smooth` preset (`stiffness: 170, damping: 50, mass: 3.0`, $\zeta \approx 1.11$).
    private static func sanitizedCameraSpring(_ raw: SpringConfig) -> SpringConfig {
        let m = max(0.1, raw.mass)
        let k = max(10.0, raw.stiffness)
        let c = max(1.0, raw.damping)
        let criticalDamping = 2.0 * sqrt(k * m)
        let zeta = c / criticalDamping
        if zeta < 0.80 || c < 30.0 {
            return .defaultCamera
        }
        return raw
    }

    /// Upgrades any legacy underdamped cursor spring (`zeta < 0.75` or `damping < 28`) to the `Smooth` cursor preset (`stiffness: 470, damping: 70, mass: 3.0`, $\zeta \approx 0.93$).
    private static func sanitizedCursorSpring(_ raw: SpringConfig) -> SpringConfig {
        let m = max(0.1, raw.mass)
        let k = max(10.0, raw.stiffness)
        let c = max(1.0, raw.damping)
        let criticalDamping = 2.0 * sqrt(k * m)
        let zeta = c / criticalDamping
        if zeta < 0.75 || c < 28.0 {
            return .defaultCursor
        }
        return raw
    }

    /// Steps a 1D Newtonian spring by `dt` seconds using 1ms substeps and the dynamic critical damping clamp (`function G`):
    /// Whenever velocity is approaching the target faster than the natural settling rate `|target - x| * sqrt(k / m)`,
    /// damping is boosted to at least critical damping `2 * sqrt(k * m)` so the spring NEVER overshoots or oscillates!
    private static func stepClampedSpring(
        current: Double,
        velocity: Double,
        target: Double,
        spring: SpringConfig,
        dt: Double
    ) -> (value: Double, velocity: Double) {
        let mass = max(0.05, spring.mass)
        let stiffness = max(1.0, spring.stiffness)
        let baseDamping = max(1.0, spring.damping)
        let naturalFreq = sqrt(stiffness / mass)
        let criticalDamping = 2.0 * sqrt(mass * stiffness)

        var x = current
        var v = velocity

        // Integrate in 8 substeps per 8.33ms frame (~1ms per substep, 1ms loop in `function K` & `Uc.run`)
        // Re-evaluates the `function G` dynamic critical damping boost at EVERY 1ms substep!
        let substeps = 8
        let subDt = dt / Double(substeps)
        let precision = 0.0004

        for _ in 0..<substeps {
            let remaining = target - x
            var stepDamping = baseDamping
            if v * remaining > 0.0 && abs(v) > abs(remaining) * naturalFreq {
                stepDamping = max(baseDamping, criticalDamping)
            }

            let disp = x - target
            let accel = (-stiffness * disp - stepDamping * v) / mass
            let nextV = v + accel * subDt
            let nextX = x + nextV * subDt

            // Prevent crossing/overshooting the target on approach
            if (x - target) * (nextX - target) < 0.0 {
                x = target
                v = 0.0
                break
            }

            if abs(nextV) < precision && abs(nextX - target) < precision {
                x = target
                v = 0.0
                break
            }

            x = nextX
            v = nextV
        }

        return (x, v)
    }

    // MARK: - Build `MovesGroup` Dead-Zone Clusters

    private static func buildMovesGroupsForZoom(
        zoom: ZoomBlock,
        cursorEvents: [CursorSampleEvent],
        clickEvents: [ClickEvent],
        maxDistanceX: Double,
        maxDistanceY: Double
    ) -> [CursorMovesGroup] {
        // 1. Collect cursor events inside `[zoom.sourceStartMs, zoom.sourceEndMs]`,
        //    decimated by a minimum movement step (`Bo(events, 10px)` -> ~`0.006` normalized) so micro-jitter is ignored.
        var significantSamples: [(tMs: Double, x: Double, y: Double)] = []
        let minStepDist01 = 0.006

        // Include the cursor position right at `zoom.sourceStartMs`
        if let startSample = cursorEvents.last(where: { $0.t <= zoom.sourceStartMs }) ?? cursorEvents.first {
            significantSamples.append((tMs: zoom.sourceStartMs, x: startSample.x, y: startSample.y))
        }

        // Include clicks inside the zoom range (clicks are always anchor points in `Bo`)
        let clicksInZoom = clickEvents.filter {
            $0.type == "down" && $0.t >= zoom.sourceStartMs && $0.t <= zoom.sourceEndMs
        }

        for ev in cursorEvents where ev.t >= zoom.sourceStartMs && ev.t <= zoom.sourceEndMs {
            if let last = significantSamples.last {
                if hypot(ev.x - last.x, ev.y - last.y) >= minStepDist01 {
                    significantSamples.append((tMs: ev.t, x: ev.x, y: ev.y))
                }
            } else {
                significantSamples.append((tMs: ev.t, x: ev.x, y: ev.y))
            }
        }

        for click in clicksInZoom {
            significantSamples.append((tMs: click.t, x: click.x, y: click.y))
        }

        significantSamples.sort { $0.tMs < $1.tMs }

        guard !significantSamples.isEmpty else { return [] }

        // 2. Partition into `CursorMovesGroup`s:
        //    As long as `(maxX - minX) <= maxDistanceX` and `(maxY - minY) <= maxDistanceY`,
        //    samples stay in the SAME group and the camera DOES NOT PAN AT ALL!
        var groups: [CursorMovesGroup] = []
        var currentGroup = CursorMovesGroup(maxDistanceX: maxDistanceX, maxDistanceY: maxDistanceY)

        for sample in significantSamples {
            if currentGroup.canAdd(x: sample.x, y: sample.y) {
                currentGroup.add(tMs: sample.tMs, x: sample.x, y: sample.y)
            } else {
                currentGroup.finishedTimeMs = sample.tMs
                groups.append(currentGroup)
                currentGroup = CursorMovesGroup(maxDistanceX: maxDistanceX, maxDistanceY: maxDistanceY)
                currentGroup.add(tMs: sample.tMs, x: sample.x, y: sample.y)
            }
        }
        currentGroup.finishedTimeMs = zoom.sourceEndMs
        groups.append(currentGroup)

        return groups
    }

    public func evaluate(atSourceMs sourceMs: Double) -> (cursor: CursorFrameState, camera: CameraFrameState) {
        guard !cursorStates.isEmpty, !cameraStates.isEmpty else {
            return (
                CursorFrameState(
                    position01: .center,
                    velocity01PerSec: .zero,
                    rotationRadians: 0.0,
                    opacity: 1.0,
                    cursorType: "arrow",
                    activeClickProgress: nil
                ),
                CameraFrameState(
                    center01: .center,
                    scale: 1.0,
                    velocity01PerSec: .zero,
                    scaleVelocityPerSec: 0.0,
                    isLoupeMode: false,
                    loupePresence01: 0.0,
                    loupeScale: 1.0,
                    loupeConfig: LoupeConfig()
                )
            )
        }

        let exactIndex = max(0.0, min(Double(cursorStates.count - 1), sourceMs / stepMs))
        let i0 = Int(floor(exactIndex))
        let i1 = min(cursorStates.count - 1, i0 + 1)
        let frac = exactIndex - Double(i0)

        if frac <= 0.0001 || i0 == i1 {
            return (cursorStates[i0], cameraStates[i0])
        }

        // Fractional frame linear interpolation (`shouldInterpolateFractionalFrames = true` in the `Wd`)
        let c0 = cursorStates[i0]
        let c1 = cursorStates[i1]
        let interpCursor = CursorFrameState(
            position01: Point01(
                x: c0.position01.x + (c1.position01.x - c0.position01.x) * frac,
                y: c0.position01.y + (c1.position01.y - c0.position01.y) * frac
            ),
            velocity01PerSec: c0.velocity01PerSec,
            rotationRadians: c0.rotationRadians + (c1.rotationRadians - c0.rotationRadians) * frac,
            opacity: c0.opacity + (c1.opacity - c0.opacity) * frac,
            cursorType: c0.cursorType,
            activeClickProgress: c0.activeClickProgress
        )

        let cam0 = cameraStates[i0]
        let cam1 = cameraStates[i1]
        let interpCamera = CameraFrameState(
            center01: Point01(
                x: cam0.center01.x + (cam1.center01.x - cam0.center01.x) * frac,
                y: cam0.center01.y + (cam1.center01.y - cam0.center01.y) * frac
            ),
            scale: cam0.scale + (cam1.scale - cam0.scale) * frac,
            velocity01PerSec: cam0.velocity01PerSec,
            scaleVelocityPerSec: cam0.scaleVelocityPerSec,
            isLoupeMode: cam0.isLoupeMode || cam1.isLoupeMode,
            loupePresence01: cam0.loupePresence01 + (cam1.loupePresence01 - cam0.loupePresence01) * frac,
            loupeScale: cam0.loupeScale + (cam1.loupeScale - cam0.loupeScale) * frac,
            loupeConfig: cam0.loupeConfig
        )

        return (interpCursor, interpCamera)
    }
}

// MARK: - Auto-Zoom Click Cluster & Typing Hold Generator

public enum AutoZoomClusterGenerator {
    /// Automatically groups mouse clicks into smooth cinematic ZoomBlocks using the window constants
    /// (`Re = { before: 300ms, after: 2500ms }`, `fillGap = 2500ms`, default zoom `2.0x`).
    public static func generateZooms(
        clicks: [ClickEvent],
        keys: [KeyStrokeEvent],
        durationMs: Double,
        defaultScale: Double = 2.0
    ) -> [ZoomBlock] {
        let downClicks = clicks.filter { $0.type == "down" && $0.t < durationMs - 1000.0 }.sorted { $0.t < $1.t }
        guard !downClicks.isEmpty else { return [] }

        let leadInMs = 300.0
        let holdAfterClickMs = 2500.0
        let clusterGapMs = 2500.0     // `fillGap` merge threshold
        let holdAfterTypingMs = 1500.0
        let minZoomDurationMs = 2200.0

        var blocks: [ZoomBlock] = []

        var clusterStart = max(0.0, downClicks[0].t - leadInMs)
        var clusterEnd = min(durationMs - 500.0, downClicks[0].t + holdAfterClickMs)
        var centerAccumX = downClicks[0].x
        var centerAccumY = downClicks[0].y
        var clickCount = 1

        for i in 1..<downClicks.count {
            let click = downClicks[i]
            let prevClick = downClicks[i - 1]
            let timeDelta = click.t - prevClick.t

            if timeDelta <= clusterGapMs {
                clusterEnd = min(durationMs - 500.0, max(clusterEnd, click.t + holdAfterClickMs))
                centerAccumX += click.x
                centerAccumY += click.y
                clickCount += 1
            } else {
                clusterEnd = extendForTyping(
                    startMs: clusterStart,
                    endMs: clusterEnd,
                    keys: keys,
                    holdMs: holdAfterTypingMs,
                    maxDurationMs: durationMs
                )
                if clusterEnd - clusterStart < minZoomDurationMs {
                    clusterEnd = min(durationMs, clusterStart + minZoomDurationMs)
                }

                blocks.append(
                    ZoomBlock(
                        sourceStartMs: clusterStart,
                        sourceEndMs: clusterEnd,
                        scale: defaultScale,
                        mode: .followCursor,
                        manualCenter01: Point01(
                            x: centerAccumX / Double(clickCount),
                            y: centerAccumY / Double(clickCount)
                        )
                    )
                )

                clusterStart = max(clusterEnd + 250.0, click.t - leadInMs)
                clusterEnd = min(durationMs - 500.0, click.t + holdAfterClickMs)
                centerAccumX = click.x
                centerAccumY = click.y
                clickCount = 1
            }
        }

        clusterEnd = extendForTyping(
            startMs: clusterStart,
            endMs: clusterEnd,
            keys: keys,
            holdMs: holdAfterTypingMs,
            maxDurationMs: durationMs
        )
        if clusterEnd - clusterStart < minZoomDurationMs {
            clusterEnd = min(durationMs, clusterStart + minZoomDurationMs)
        }

        if clusterEnd > clusterStart + 400.0 {
            blocks.append(
                ZoomBlock(
                    sourceStartMs: clusterStart,
                    sourceEndMs: clusterEnd,
                    scale: defaultScale,
                    mode: .followCursor,
                    manualCenter01: Point01(
                        x: centerAccumX / Double(clickCount),
                        y: centerAccumY / Double(clickCount)
                    )
                )
            )
        }

        return normalizeNonOverlappingZooms(blocks, durationMs: durationMs)
    }

    /// Ensures zoom blocks are sorted and strictly non-overlapping within `[0, durationMs]`.
    public static func normalizeNonOverlappingZooms(_ zooms: [ZoomBlock], durationMs: Double) -> [ZoomBlock] {
        let sorted = zooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
        var result: [ZoomBlock] = []
        for var z in sorted {
            let minStart = result.last?.sourceEndMs ?? 0.0
            z.sourceStartMs = max(minStart, z.sourceStartMs)
            z.sourceEndMs = min(durationMs, z.sourceEndMs)
            if z.sourceEndMs - z.sourceStartMs >= 200.0 {
                result.append(z)
            }
        }
        return result
    }

    private static func extendForTyping(
        startMs: Double,
        endMs: Double,
        keys: [KeyStrokeEvent],
        holdMs: Double,
        maxDurationMs: Double
    ) -> Double {
        var currentEnd = endMs
        for key in keys where key.t >= startMs && key.t <= currentEnd + 800.0 {
            currentEnd = min(maxDurationMs, max(currentEnd, key.t + holdMs))
        }
        return currentEnd
    }
}
