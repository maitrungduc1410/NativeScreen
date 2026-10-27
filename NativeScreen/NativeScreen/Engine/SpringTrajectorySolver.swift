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
///
/// Architecture & Mathematical References:
/// - `spec/03-CINEMATIC-ENGINE-AND-MATH.md` (§1 120Hz Spring Physics Solver, Lookahead Phase-Lag Compensation, Drag Acceleration & Stationary `CursorMovesGroup` Clustering)
/// - `spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` (§6 Telemetry Clock Synchronization & Spring Phase-Lag Lookahead)
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
        func computeTimeWeightedCenter01() -> Point01 {
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

    /// Flat, pre-resolved focus group with its `timeWeightedCenter01` computed ONCE at group creation time
    /// so the 120Hz camera solver reads `center01` in O(1) without re-summing samples at every 8.33ms step.
    private struct ResolvedFocusGroup {
        let startTimeMs: Double
        let center01: Point01
    }

    /// Precomputed spring constants so `sqrt(k / m)` and `2 * sqrt(k * m)` are never recomputed inside the 120Hz inner loop.
    private struct PrecomputedSpring {
        let mass: Double
        let stiffness: Double
        let baseDamping: Double
        let naturalFreq: Double
        let criticalDamping: Double

        init(_ spring: SpringConfig) {
            let m = max(0.05, spring.mass)
            let k = max(1.0, spring.stiffness)
            let c = max(1.0, spring.damping)
            self.mass = m
            self.stiffness = k
            self.baseDamping = c
            self.naturalFreq = sqrt(k / m)
            self.criticalDamping = 2.0 * sqrt(m * k)
        }
    }

    private let stepMs: Double = 1000.0 / 120.0 // 8.333 ms (120 Hz)
    private let durationMs: Double
    public let cursorStates: [CursorFrameState]
    public let cameraStates: [CameraFrameState]

    public init(
        durationMs: Double,
        cursorEvents: [CursorSampleEvent],
        clickEvents: [ClickEvent],
        document: ProjectDocument,
        reusingCursorStates: [CursorFrameState]? = nil
    ) {
        let totalDuration = max(100.0, durationMs)
        self.durationMs = totalDuration
        let totalSteps = max(2, Int(ceil(totalDuration / stepMs)) + 1)
        let dt = stepMs / 1000.0

        // Upgrade any underdamped spring (`zeta < 0.72` or legacy `damping < 35`) automatically to the overdamped presets!
        let cursorSpring = Self.sanitizedCursorSpring(document.cursor.spring)
        let camSpring = Self.sanitizedCameraSpring(document.motion.cameraSpring)
        let precomputedCamSpring = PrecomputedSpring(camSpring)

        // 1. Pre-solve Cursor Trajectory at 120 Hz (or reuse cached `cursorStates` in O(1) when only Zooms/Camera changed!)
        let builtCursor: [CursorFrameState]
        if let existing = reusingCursorStates, existing.count == totalSteps {
            builtCursor = existing
        } else {
            var solvedCursor: [CursorFrameState] = []
            solvedCursor.reserveCapacity(totalSteps)

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
            let downClickTimesMs: [Double] = clickEvents.compactMap {
                $0.type == "down" ? max(0.0, $0.t - legacyStartupOffsetMs) : nil
            }

            // Steady-state spring phase lag
            let baseSpringLagMs: Double = document.cursor.smoothMovementEnabled
                ? min(240.0, max(0.0, (cursorSpring.damping / max(10.0, cursorSpring.stiffness)) * 1000.0))
                : 0.0
            let leadFactor: Double = document.cursor.keepInSyncWithHovers ? 1.0 : 0.72
            let effectiveLeadMs: Double = baseSpringLagMs * leadFactor
            let baseCursorPrecomputed = PrecomputedSpring(cursorSpring)

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

            let baseRad = -document.cursor.baseRotationDegrees * .pi / 180.0
            let rippleDurationMs = 450.0

            for step in 0..<totalSteps {
                let tMs = Double(step) * stepMs
                let baseLookupMs = stopMoveCutoffMs.map { min(tMs, $0) } ?? tMs

                var syncSpeedMultiplier = 1.0
                for drag in dragIntervals {
                    if tMs >= drag.startMs - 220.0 && tMs <= drag.endMs + 260.0 {
                        if tMs < drag.startMs {
                            let ramp = (tMs - (drag.startMs - 220.0)) / 220.0
                            syncSpeedMultiplier = max(syncSpeedMultiplier, 1.0 + 3.2 * max(0.0, min(1.0, ramp)))
                        } else if tMs <= drag.endMs {
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
                let effectiveShakeThreshold = (syncSpeedMultiplier > 1.5) ? 0.0 : shakeThreshold01
                if dist > effectiveShakeThreshold {
                    filteredTargetX = rawTargetX
                    filteredTargetY = rawTargetY
                    lastMoveTimeMs = tMs
                }

                if document.cursor.smoothMovementEnabled {
                    let effectivePrecomputed: PrecomputedSpring
                    if abs(syncSpeedMultiplier - 1.0) < 0.001 {
                        effectivePrecomputed = baseCursorPrecomputed
                    } else {
                        effectivePrecomputed = PrecomputedSpring(
                            SpringConfig(
                                stiffness: cursorSpring.stiffness * syncSpeedMultiplier * syncSpeedMultiplier,
                                damping: cursorSpring.damping * syncSpeedMultiplier,
                                mass: cursorSpring.mass
                            )
                        )
                    }
                    (curX, velX) = Self.stepClampedSpring(
                        current: curX,
                        velocity: velX,
                        target: filteredTargetX,
                        spring: effectivePrecomputed,
                        dt: dt
                    )
                    (curY, velY) = Self.stepClampedSpring(
                        current: curY,
                        velocity: velY,
                        target: filteredTargetY,
                        spring: effectivePrecomputed,
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

                var dynamicRad = 0.0
                if document.cursor.velocityRotationEnabled {
                    switch document.cursor.rotationMode {
                    case .tilt:
                        let maxTilt = 0.35
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
                for adjClickT in downClickTimesMs {
                    let elapsed = tMs - adjClickT
                    if elapsed >= 0.0 && elapsed <= rippleDurationMs {
                        activeRipple = elapsed / rippleDurationMs
                    }
                }

                solvedCursor.append(
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
            builtCursor = solvedCursor
        }
        self.cursorStates = builtCursor

        // 2. Pre-build `MovesGroup` Dead-Zone Focus Clusters for every Auto-Zoom Block
        //    Each group's `timeWeightedCenter01` is resolved ONCE up-front into `[ResolvedFocusGroup]` so the 120Hz camera loop
        //    never re-sums cursor samples on every 8.33ms step!
        let activeZooms = document.timeline.isZoomTrackHidden
            ? []
            : document.timeline.zooms.filter { !$0.disabled }.sorted { $0.sourceStartMs < $1.sourceStartMs }

        let hasAnyLoupeZoom = activeZooms.contains { $0.presentation == .loupe }
        let resolvedZoomFocusGroups: [[ResolvedFocusGroup]] = activeZooms.map { zoom in
            guard zoom.mode == .followCursor else { return [] }
            let zoomScale = max(1.0, zoom.scale)
            let maxDist01 = 0.5 / zoomScale
            return Self.buildMovesGroupsForZoom(
                zoom: zoom,
                cursorEvents: cursorEvents,
                clickEvents: clickEvents,
                maxDistanceX: maxDist01,
                maxDistanceY: maxDist01
            )
        }

        // 3. Pre-solve Virtual Camera Trajectory in Screen-Rect Space
        var builtCamera: [CameraFrameState] = []
        builtCamera.reserveCapacity(totalSteps)

        var rectX = 0.0
        var rectY = 0.0
        var rectW = 1.0
        var rectVelX = 0.0
        var rectVelY = 0.0
        var rectVelW = 0.0

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

        let precomputedLoupeSpring = PrecomputedSpring(
            SpringConfig(
                stiffness: camSpring.stiffness * 1.5,
                damping: camSpring.damping * 1.22,
                mass: camSpring.mass
            )
        )

        let zoomCount = activeZooms.count
        var zoomCursorIdx = 0
        let avoidEmptyBounds = document.motion.avoidEmptyBoundsWhenZooming

        for step in 0..<totalSteps {
            let tMs = Double(step) * stepMs
            let cursorAtStep = builtCursor[step].position01

            // Advance monotonic zoom index pointer (`activeZooms` are sorted and non-overlapping)
            while zoomCursorIdx < zoomCount && activeZooms[zoomCursorIdx].sourceEndMs < tMs {
                zoomCursorIdx += 1
            }
            let activeZoomIdx: Int? = (zoomCursorIdx < zoomCount && tMs >= activeZooms[zoomCursorIdx].sourceStartMs)
                ? zoomCursorIdx
                : nil

            var targetScale = 1.0
            var targetFocusX = 0.5
            var targetFocusY = 0.5
            var isLoupeActiveNow = false
            var targetLoupePresence = 0.0
            var targetLoupeScale = 1.0
            var targetLoupeFocusX = loupeCenterX
            var targetLoupeFocusY = loupeCenterY
            var loupeCfg = lastActiveLoupeCfg
            var isInstantZoomNow = false

            if let zIdx = activeZoomIdx {
                let zoom = activeZooms[zIdx]
                isInstantZoomNow = zoom.instantAnimation
                isLoupeActiveNow = (zoom.presentation == .loupe)
                if isLoupeActiveNow {
                    loupeCfg = zoom.loupe
                    lastActiveLoupeCfg = zoom.loupe
                    targetLoupePresence = 1.0
                    targetLoupeScale = max(1.0, zoom.scale)
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
                    targetScale = 1.0
                    targetFocusX = 0.5
                    targetFocusY = 0.5
                } else {
                    targetScale = max(1.0, zoom.scale)
                    switch zoom.mode {
                    case .followCursor:
                        let groups = resolvedZoomFocusGroups[zIdx]
                        if !groups.isEmpty {
                            var activeGroupCenter = groups[0].center01
                            for g in groups {
                                if g.startTimeMs <= tMs {
                                    activeGroupCenter = g.center01
                                } else {
                                    break
                                }
                            }
                            targetFocusX = activeGroupCenter.x
                            targetFocusY = activeGroupCenter.y
                        } else {
                            targetFocusX = cursorAtStep.x
                            targetFocusY = cursorAtStep.y
                        }
                    case .manual:
                        targetFocusX = zoom.manualCenter01.x
                        targetFocusY = zoom.manualCenter01.y
                    }
                }
            } else if hasAnyLoupeZoom {
                // Pre-warm `loupeCenterX/Y` towards an upcoming Loupe block so it spawns right on the cursor (`inactiveLoupeStandIn`)
                if zoomCursorIdx < zoomCount {
                    let upcoming = activeZooms[zoomCursorIdx]
                    if upcoming.presentation == .loupe && upcoming.sourceStartMs > tMs && upcoming.sourceStartMs - tMs <= 450.0 {
                        loupeCfg = upcoming.loupe
                        lastActiveLoupeCfg = upcoming.loupe
                        targetLoupeFocusX = (upcoming.mode == .manual) ? upcoming.manualCenter01.x : cursorAtStep.x
                        targetLoupeFocusY = (upcoming.mode == .manual) ? upcoming.manualCenter01.y : cursorAtStep.y
                    }
                }
            }

            // Compute target screen rect `(targetRectX, targetRectY, targetRectW)` using the `Rect.zoom` + `containInZoomArea`
            let targetRectW = targetScale
            var targetRectX = 0.5 - targetFocusX * targetScale
            var targetRectY = 0.5 - targetFocusY * targetScale

            if !isLoupeActiveNow && avoidEmptyBounds && targetScale > 1.0001 {
                let minOrigin = 1.0 - targetScale
                targetRectX = min(0.0, max(minOrigin, targetRectX))
                targetRectY = min(0.0, max(minOrigin, targetRectY))
            }

            // Step the 3 screen-rect components `(rectX, rectY, rectW)` with the overshoot-clamped spring
            if isInstantZoomNow && !isLoupeActiveNow {
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
                    spring: precomputedCamSpring,
                    dt: dt
                )
                (rectY, rectVelY) = Self.stepClampedSpring(
                    current: rectY,
                    velocity: rectVelY,
                    target: targetRectY,
                    spring: precomputedCamSpring,
                    dt: dt
                )
                (rectW, rectVelW) = Self.stepClampedSpring(
                    current: rectW,
                    velocity: rectVelW,
                    target: targetRectW,
                    spring: precomputedCamSpring,
                    dt: dt
                )
            }

            // Only integrate the 4 Loupe springs if at least one Loupe zoom exists in the project!
            if hasAnyLoupeZoom {
                if isInstantZoomNow && isLoupeActiveNow {
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
                        spring: precomputedLoupeSpring,
                        dt: dt
                    )
                    (loupeCenterY, loupeVelY) = Self.stepClampedSpring(
                        current: loupeCenterY,
                        velocity: loupeVelY,
                        target: targetLoupeFocusY,
                        spring: precomputedLoupeSpring,
                        dt: dt
                    )
                    (loupeScaleVal, loupeVelScale) = Self.stepClampedSpring(
                        current: loupeScaleVal,
                        velocity: loupeVelScale,
                        target: targetLoupeScale,
                        spring: precomputedLoupeSpring,
                        dt: dt
                    )
                    (loupePresenceVal, loupeVelPresence) = Self.stepClampedSpring(
                        current: loupePresenceVal,
                        velocity: loupeVelPresence,
                        target: targetLoupePresence,
                        spring: precomputedLoupeSpring,
                        dt: dt
                    )
                }
            }

            let isLoupeVisible = (loupePresenceVal > 0.005)
            let solvedScale = max(1.0, rectW)
            let solvedCenter01: Point01
            if isLoupeVisible {
                solvedCenter01 = Point01(
                    x: min(1.0, max(0.0, loupeCenterX)),
                    y: min(1.0, max(0.0, loupeCenterY))
                )
            } else {
                // Recover exact camera focus point `center01` from the interpolated screen rect `(rectX, rectY, rectW)`
                // even when `solvedScale == 1.0` so `rectX`/`rectY` settling after `rectW` reaches `1.0` is preserved smoothly
                // without an artificial snap in `center01`!
                var cx = (0.5 - rectX) / solvedScale
                var cy = (0.5 - rectY) / solvedScale
                if document.motion.avoidEmptyBoundsWhenZooming && solvedScale > 1.0001 {
                    let halfSpan = 0.5 / solvedScale
                    cx = max(halfSpan, min(1.0 - halfSpan, cx))
                    cy = max(halfSpan, min(1.0 - halfSpan, cy))
                }
                solvedCenter01 = Point01(x: cx, y: cy)
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
    @inline(__always)
    private static func stepClampedSpring(
        current: Double,
        velocity: Double,
        target: Double,
        spring: PrecomputedSpring,
        dt: Double
    ) -> (value: Double, velocity: Double) {
        let precision = 0.0004
        if abs(target - current) < precision && abs(velocity) < precision {
            return (target, 0.0)
        }

        let mass = spring.mass
        let stiffness = spring.stiffness
        let baseDamping = spring.baseDamping
        let naturalFreq = spring.naturalFreq
        let criticalDamping = spring.criticalDamping

        var x = current
        var v = velocity

        // Integrate in 8 substeps per 8.33ms frame (~1ms per substep, 1ms loop in `function K` & `Uc.run`)
        // Re-evaluates the `function G` dynamic critical damping boost at EVERY 1ms substep!
        let substeps = 8
        let subDt = dt / Double(substeps)

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
    ) -> [ResolvedFocusGroup] {
        guard !cursorEvents.isEmpty else { return [] }

        var significantSamples: [(tMs: Double, x: Double, y: Double)] = []
        let minStepDist01 = 0.006
        let startMs = zoom.sourceStartMs
        let endMs = zoom.sourceEndMs

        // Binary search for the first cursor event with `t >= startMs` in O(log N)
        var lo = 0
        var hi = cursorEvents.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cursorEvents[mid].t < startMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Include the cursor position right at `zoom.sourceStartMs`
        let startSampleIdx = lo > 0 ? (lo - 1) : 0
        let startSample = cursorEvents[startSampleIdx]
        significantSamples.append((tMs: startMs, x: startSample.x, y: startSample.y))

        // Scan only events inside `[startMs, endMs]`
        var idx = lo
        while idx < cursorEvents.count {
            let ev = cursorEvents[idx]
            if ev.t > endMs { break }
            if let last = significantSamples.last {
                if hypot(ev.x - last.x, ev.y - last.y) >= minStepDist01 {
                    significantSamples.append((tMs: ev.t, x: ev.x, y: ev.y))
                }
            } else {
                significantSamples.append((tMs: ev.t, x: ev.x, y: ev.y))
            }
            idx += 1
        }

        // Include clicks inside the zoom range (clicks are always anchor points in `Bo`)
        var addedClicks = false
        for click in clickEvents where click.type == "down" && click.t >= startMs && click.t <= endMs {
            significantSamples.append((tMs: click.t, x: click.x, y: click.y))
            addedClicks = true
        }

        if addedClicks {
            significantSamples.sort { $0.tMs < $1.tMs }
        }

        guard !significantSamples.isEmpty else { return [] }

        // 2. Partition into `CursorMovesGroup`s and resolve each group's centroid ONCE:
        var resolved: [ResolvedFocusGroup] = []
        var currentGroup = CursorMovesGroup(maxDistanceX: maxDistanceX, maxDistanceY: maxDistanceY)

        for sample in significantSamples {
            if currentGroup.canAdd(x: sample.x, y: sample.y) {
                currentGroup.add(tMs: sample.tMs, x: sample.x, y: sample.y)
            } else {
                currentGroup.finishedTimeMs = sample.tMs
                resolved.append(
                    ResolvedFocusGroup(
                        startTimeMs: currentGroup.startTimeMs,
                        center01: currentGroup.computeTimeWeightedCenter01()
                    )
                )
                currentGroup = CursorMovesGroup(maxDistanceX: maxDistanceX, maxDistanceY: maxDistanceY)
                currentGroup.add(tMs: sample.tMs, x: sample.x, y: sample.y)
            }
        }
        currentGroup.finishedTimeMs = endMs
        resolved.append(
            ResolvedFocusGroup(
                startTimeMs: currentGroup.startTimeMs,
                center01: currentGroup.computeTimeWeightedCenter01()
            )
        )

        return resolved
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
