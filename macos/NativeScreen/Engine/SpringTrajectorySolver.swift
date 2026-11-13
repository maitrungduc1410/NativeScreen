import Foundation
import CoreGraphics

/// Pre-solves and caches 120Hz spring physics trajectories for both the cursor and the virtual camera
/// as follows:
/// 1. **Stationary Dead-Zone Focus Groups (`MovesGroup` / `follow-click-groups`)**:
///    Instead of chasing every tiny cursor movement while zoomed in (which makes the camera jitter and causes motion sickness),
///    cursor events inside each zoom block are grouped into bounding-box clusters (`maxDistance = 0.5 / zoomScale`).
///    As long as the cursor moves within that half-viewport dead-zone, the camera target remains **100% stationary** at the
///    time-weighted centroid of the group!
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
        public var activeClickProgress: Double? // 0.0 -> 1.0 during the click circle
        public var clickWaves: [ClickWave] = []
    }

    /// A click whose ripple is still spreading, from where the cursor was when the button went down.
    public struct ClickWave: Sendable {
        public var ageMs: Double
        public var position01: Point01
    }

    public static let clickWaveDurationMs = 900.0
    public static let maxActiveClickWaves = 3

    public struct CameraFrameState: Sendable {
        public var center01: Point01
        public var scale: Double
        public var velocity01PerSec: Point01
        public var scaleVelocityPerSec: Double
        public var isLoupeMode: Bool
        public var loupePresence01: Double
        public var loupeScale: Double
        public var loupeConfig: LoupeConfig
        public var loupeCenter01: Point01 = .center
    }

    /// A `MovesGroup`:
    /// Groups consecutive cursor samples whose bounding box `(maxX - minX, maxY - minY)` fits within `maxDistance01`
    /// (`0.5 / zoomScale`, i.e. 50% of the zoomed viewport), and computes their time-weighted centroid.
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
    /// The planned smoothed cursor (ADR-87), sampled per ms in points. `nil` when smoothing is off.
    public let plannedCursor: PlannedCursorPath?
    private let pointSize: MotionPointSize

    public init(
        durationMs: Double,
        cursorEvents: [CursorSampleEvent],
        clickEvents: [ClickEvent],
        document: ProjectDocument,
        pointSize: MotionPointSize = .reference,
        reusingCursorStates: [CursorFrameState]? = nil,
        reusingPlannedCursor: PlannedCursorPath? = nil,
        startsAtCut: Bool = false,
        loopTarget01: Point01? = nil,
        telemetryUsesPlaybackTime: Bool = false
    ) {
        let totalDuration = max(100.0, durationMs)
        self.durationMs = totalDuration
        let totalSteps = max(2, Int(ceil(totalDuration / stepMs)) + 1)
        let dt = stepMs / 1000.0
        self.pointSize = pointSize
        let smooth = document.cursor.smoothMovementEnabled
        let cursorEvents = smooth
            ? CursorTelemetry.insertingClicks(clickEvents, into: cursorEvents, holdPauses: !telemetryUsesPlaybackTime,
                                            pointSize: pointSize)
            : cursorEvents
        let crop = document.canvas.cropRect01

        // Upgrade any underdamped spring (`zeta < 0.72` or legacy `damping < 35`) automatically to the overdamped presets!
        let cursorSpring = Self.sanitizedCursorSpring(document.cursor.spring)
        let camSpring = Self.sanitizedCameraSpring(document.motion.cameraSpring)
        let precomputedCamSpring = PrecomputedSpring(camSpring)

        // 1. Pre-solve Cursor Trajectory at 120 Hz (or reuse cached `cursorStates` in O(1) when only Zooms/Camera changed!)
        let builtCursor: [CursorFrameState]
        var planned: PlannedCursorPath? = nil
        if let existing = reusingCursorStates, existing.count == totalSteps, !smooth || reusingPlannedCursor != nil {
            builtCursor = existing
            planned = smooth ? reusingPlannedCursor : nil
        } else {
            var solvedCursor: [CursorFrameState] = []
            solvedCursor.reserveCapacity(totalSteps)

            let firstPos = cursorEvents.first.map { Point01(x: $0.x, y: $0.y) } ?? .center
            let downClickTimesMs: [Double] = clickEvents.compactMap { $0.type == "down" ? max(0.0, $0.t) : nil }.sorted()
            let downClickPositions = clickEvents.filter { $0.type == "down" }.sorted { $0.t < $1.t }
            var rippleWindowStart = 0

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

            let shakeThresholdPt = max(0.0, document.cursor.removeShakeThresholdPx)
            let stopMoveCutoffMs = (document.cursor.loopBackToStartMs == nil && document.cursor.stopMovementInLastPartMs > 0)
                ? max(0.0, totalDuration - document.cursor.stopMovementInLastPartMs)
                : nil
            let loopMs = document.cursor.loopBackToStartMs.flatMap { $0 > 0 ? $0 : nil }
            let loopStartMs = loopMs.map { max(0, totalDuration - $0) }
            let loopTarget = loopTarget01 ?? firstPos

            func sampleRecordedCursor(at queryMs: Double) -> (x: Double, y: Double, kind: String) {
                guard !cursorEvents.isEmpty else { return (firstPos.x, firstPos.y, "arrow") }
                let e = CursorTelemetry.sample(cursorEvents, at: queryMs, holdPauses: !telemetryUsesPlaybackTime)
                return (e.x, e.y, e.c)
            }

            /// Where the recorded cursor is, including the ending options (stop moving, loop back to the start).
            func endingAdjusted(_ p: (x: Double, y: Double), at tMs: Double) -> (x: Double, y: Double) {
                guard let loopStartMs, let loopMs, tMs > loopStartMs else { return p }
                let f = max(0.0, min(1.0, (tMs - loopStartMs) / loopMs))
                return (p.x + (loopTarget.x - p.x) * f, p.y + (loopTarget.y - p.y) * f)
            }

            if smooth {
                planned = Self.planCursor(
                    events: cursorEvents, clicks: clickEvents, document: document, spring: cursorSpring,
                    durationMs: totalDuration, pointSize: pointSize, expandPauses: !telemetryUsesPlaybackTime,
                    shakeThresholdPt: shakeThresholdPt, stopMoveCutoffMs: stopMoveCutoffMs, loopStartMs: loopStartMs,
                    stepMs: stepMs, endingAdjusted: endingAdjusted)
            }

            let baseRad = -document.cursor.baseRotationDegrees * .pi / 180.0
            let rippleDurationMs = 450.0
            var clickWaves: [ClickWave] = []
            var nextWaveClick = 0

            for step in 0..<totalSteps {
                let tMs = Double(step) * stepMs
                let baseLookupMs = stopMoveCutoffMs.map { min(tMs, $0) } ?? tMs
                let sampledNow = sampleRecordedCursor(at: baseLookupMs)
                let target = endingAdjusted((sampledNow.x, sampledNow.y), at: tMs)
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

                if pointSize.distance(Point01(x: target.x, y: target.y), Point01(x: filteredTargetX, y: filteredTargetY)) > shakeThresholdPt {
                    filteredTargetX = target.x
                    filteredTargetY = target.y
                    lastMoveTimeMs = tMs
                }

                if let planned {
                    let p = planned.position(at: tMs)
                    let before = planned.position(at: tMs - 1), after = planned.position(at: tMs + 1)
                    curX = p.x / pointSize.width
                    curY = p.y / pointSize.height
                    velX = (after.x - before.x) / pointSize.width / 0.002
                    velY = (after.y - before.y) / pointSize.height / 0.002
                } else {
                    velX = step == 0 ? 0 : (filteredTargetX - curX) / dt
                    velY = step == 0 ? 0 : (filteredTargetY - curY) / dt
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
                        let rawTilt = -velX * pointSize.width / 1600.0 * 0.14 * document.cursor.velocityRotationIntensity
                        dynamicRad = max(-maxTilt, min(maxTilt, rawTilt))
                    case .follow:
                        let physicalX = velX * pointSize.width / 1600.0
                        let physicalY = velY * pointSize.height / 1600.0
                        let speed = hypot(physicalX, physicalY)
                        if speed > 0.04 {
                            let targetAngle = atan2(-physicalY, physicalX) - (.pi * 0.75)
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
                while rippleWindowStart < downClickTimesMs.count && downClickTimesMs[rippleWindowStart] < tMs - rippleDurationMs {
                    rippleWindowStart += 1
                }
                for adjClickT in downClickTimesMs[rippleWindowStart...] {
                    if adjClickT > tMs {
                        break
                    }
                    let elapsed = tMs - adjClickT
                    if elapsed >= 0.0 && elapsed <= rippleDurationMs {
                        activeRipple = elapsed / rippleDurationMs
                    }
                }

                for waveIndex in clickWaves.indices {
                    clickWaves[waveIndex].ageMs += stepMs
                }
                clickWaves.removeAll { $0.ageMs > Self.clickWaveDurationMs }
                while nextWaveClick < downClickTimesMs.count && downClickTimesMs[nextWaveClick] <= tMs {
                    clickWaves.append(ClickWave(
                        ageMs: tMs - downClickTimesMs[nextWaveClick],
                        position01: Point01(x: downClickPositions[nextWaveClick].x, y: downClickPositions[nextWaveClick].y)
                    ))
                    nextWaveClick += 1
                }
                if clickWaves.count > Self.maxActiveClickWaves {
                    clickWaves.removeFirst(clickWaves.count - Self.maxActiveClickWaves)
                }

                solvedCursor.append(
                    CursorFrameState(
                        position01: Point01(x: curX, y: curY),
                        velocity01PerSec: Point01(x: velX, y: velY),
                        rotationRadians: rotation,
                        opacity: document.cursor.hidden ? 0.0 : currentOpacity,
                        cursorType: cursorKind,
                        activeClickProgress: activeRipple,
                        clickWaves: clickWaves
                    )
                )
            }
            builtCursor = solvedCursor
        }
        self.cursorStates = builtCursor
        self.plannedCursor = planned

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
                maxDistanceX: maxDist01 * crop.width,
                maxDistanceY: maxDist01 * crop.height
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
            while zoomCursorIdx < zoomCount && activeZooms[zoomCursorIdx].sourceEndMs <= tMs {
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
                let groups = resolvedZoomFocusGroups[zIdx]
                var focus = zoom.mode == .manual ? zoom.manualCenter01 : cursorAtStep
                for group in groups {
                    if group.startTimeMs > tMs { break }
                    focus = group.center01
                }
                focus = MotionGeometry.cropped(focus, by: crop)
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
                        targetLoupeFocusX = min(1.0, max(0.0, focus.x + wobbleX))
                        targetLoupeFocusY = min(1.0, max(0.0, focus.y + wobbleY))
                    case .manual:
                        targetLoupeFocusX = focus.x
                        targetLoupeFocusY = focus.y
                    }
                    targetScale = 1.0
                    targetFocusX = 0.5
                    targetFocusY = 0.5
                } else {
                    targetScale = max(1.0, zoom.scale)
                    targetFocusX = focus.x
                    targetFocusY = focus.y
                }
            }
            // Warm only invisible glass, including while the preceding screen zoom is active.
            if hasAnyLoupeZoom && !isLoupeActiveNow && loupePresenceVal <= 0.005 {
                let upcomingIndex = activeZoomIdx.map { $0 + 1 } ?? zoomCursorIdx
                if upcomingIndex < zoomCount {
                    let upcoming = activeZooms[upcomingIndex]
                    if upcoming.presentation == .loupe && upcoming.sourceStartMs > tMs && upcoming.sourceStartMs - tMs <= 450.0 {
                        loupeCfg = upcoming.loupe
                        lastActiveLoupeCfg = upcoming.loupe
                        let focus = MotionGeometry.cropped(upcoming.mode == .manual ? upcoming.manualCenter01
                            : resolvedZoomFocusGroups[upcomingIndex].first?.center01 ?? cursorAtStep, by: crop)
                        targetLoupeFocusX = focus.x
                        targetLoupeFocusY = focus.y
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
            if (isInstantZoomNow && !isLoupeActiveNow) || (step == 0 && startsAtCut) {
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
                if (isInstantZoomNow && isLoupeActiveNow) || (step == 0 && startsAtCut) {
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
            do {
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
                    loupeConfig: loupeCfg,
                    loupeCenter01: Point01(x: min(1, max(0, loupeCenterX)), y: min(1, max(0, loupeCenterY)))
                )
            )
        }

        self.cameraStates = builtCamera
    }

    // MARK: - Spring Sanitization & the Exact Overshoot-Clamped Spring Integrator

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

    /// Steps a 1D Newtonian spring by `dt` seconds using 1ms substeps and the dynamic critical damping clamp:
    /// Whenever velocity is approaching the target faster than the natural settling rate `|target - x| * sqrt(k / m)`,
    /// damping is boosted to at least critical damping `2 * sqrt(k * m)` so the spring NEVER overshoots or oscillates!
    @inline(__always)
    private static func stepClampedSpring(
        current: Double,
        velocity: Double,
        target: Double,
        spring: PrecomputedSpring,
        dt: Double,
        precision: Double = 0.002
    ) -> (value: Double, velocity: Double) {
        // spring precision
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

        // Integrate in 8 substeps per 8.33ms frame (~1ms per substep)
        // Re-evaluates the dynamic critical damping boost at EVERY 1ms substep!
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

        // Include clicks inside the zoom range (clicks are always anchor points of a group)
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

        // Fractional frame linear interpolation
        let c0 = cursorStates[i0]
        let c1 = cursorStates[i1]
        var interpCursor = CursorFrameState(
            position01: Point01(
                x: c0.position01.x + (c1.position01.x - c0.position01.x) * frac,
                y: c0.position01.y + (c1.position01.y - c0.position01.y) * frac
            ),
            velocity01PerSec: c0.velocity01PerSec,
            rotationRadians: c0.rotationRadians + (c1.rotationRadians - c0.rotationRadians) * frac,
            opacity: c0.opacity + (c1.opacity - c0.opacity) * frac,
            cursorType: c0.cursorType,
            activeClickProgress: c0.activeClickProgress,
            clickWaves: c0.clickWaves
        )
        // The planned path is per ms, finer than the 120 Hz states, so clicks between steps stay exact.
        if let plannedCursor {
            let p = plannedCursor.position(at: sourceMs)
            interpCursor.position01 = Point01(x: p.x / pointSize.width, y: p.y / pointSize.height)
        }

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
            loupeConfig: cam0.loupeConfig,
            loupeCenter01: Point01(x: cam0.loupeCenter01.x + (cam1.loupeCenter01.x - cam0.loupeCenter01.x) * frac,
                                  y: cam0.loupeCenter01.y + (cam1.loupeCenter01.y - cam0.loupeCenter01.y) * frac)
        )

        return (interpCursor, interpCamera)
    }
}

// MARK: - Auto-Zoom Click Cluster & Typing Hold Generator

public enum AutoZoomClusterGenerator {
    /// Automatically groups mouse clicks into smooth cinematic ZoomBlocks using the window constants
    /// (lead-in 300ms, hold 2500ms, `fillGap = 2500ms`, default zoom `2.0x`).
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
        // Tail margin:
        // Every auto-generated zoom ends at least 800ms before `durationMs` so the camera spring (`stiffness: 170, damping: 50, mass: 3.0`,
        // settle time ~750ms) has 100% finished settling to rest before the end of the recording!
        let maxAutoZoomEndMs = max(600.0, durationMs - 800.0)

        var blocks: [ZoomBlock] = []

        var clusterStart = max(0.0, downClicks[0].t - leadInMs)
        var clusterEnd = min(maxAutoZoomEndMs, downClicks[0].t + holdAfterClickMs)
        var centerAccumX = downClicks[0].x
        var centerAccumY = downClicks[0].y
        var clickCount = 1

        for i in 1..<downClicks.count {
            let click = downClicks[i]
            let prevClick = downClicks[i - 1]
            let timeDelta = click.t - prevClick.t

            if timeDelta <= clusterGapMs {
                clusterEnd = min(maxAutoZoomEndMs, max(clusterEnd, click.t + holdAfterClickMs))
                centerAccumX += click.x
                centerAccumY += click.y
                clickCount += 1
            } else {
                clusterEnd = extendForTyping(
                    startMs: clusterStart,
                    endMs: clusterEnd,
                    keys: keys,
                    holdMs: holdAfterTypingMs,
                    maxDurationMs: maxAutoZoomEndMs
                )
                if clusterEnd - clusterStart < minZoomDurationMs {
                    clusterEnd = min(maxAutoZoomEndMs, clusterStart + minZoomDurationMs)
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
                clusterEnd = min(maxAutoZoomEndMs, click.t + holdAfterClickMs)
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
            maxDurationMs: maxAutoZoomEndMs
        )
        if clusterEnd - clusterStart < minZoomDurationMs {
            clusterEnd = min(maxAutoZoomEndMs, clusterStart + minZoomDurationMs)
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

        return normalizeNonOverlappingZooms(mergeCloseZooms(blocks), durationMs: durationMs)
    }

    /// Two zooms less than this far apart become one. Zooming out takes about 750 ms to settle, so a shorter gap only
    /// zooms out and straight back in, which reads as a jolt.
    public static let mergeGapMs = 2500.0

    /// Joins neighbouring zooms whose gap is under `mergeGapMs`. The joined zoom spans both, and its center is the
    /// duration-weighted mean of their centers.
    static func mergeCloseZooms(_ blocks: [ZoomBlock]) -> [ZoomBlock] {
        var result: [ZoomBlock] = []
        for block in blocks.sorted(by: { $0.sourceStartMs < $1.sourceStartMs }) {
            guard var last = result.last, block.sourceStartMs - last.sourceEndMs < mergeGapMs else {
                result.append(block)
                continue
            }
            let lastMs = last.sourceEndMs - last.sourceStartMs
            let blockMs = block.sourceEndMs - block.sourceStartMs
            let total = max(1.0, lastMs + blockMs)
            let a = last.manualCenter01, b = block.manualCenter01
            last.manualCenter01 = Point01(
                x: (a.x * lastMs + b.x * blockMs) / total,
                y: (a.y * lastMs + b.y * blockMs) / total
            )
            last.sourceEndMs = max(last.sourceEndMs, block.sourceEndMs)
            result[result.count - 1] = last
        }
        return result
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
