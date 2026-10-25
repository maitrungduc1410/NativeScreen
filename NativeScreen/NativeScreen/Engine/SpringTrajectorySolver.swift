import Foundation
import CoreGraphics

/// Pre-solves and caches 120Hz spring physics trajectories for both the cursor and the virtual camera
/// so that random-access timeline scrubbing and 60/120fps rendering are O(1).
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
        public var loupeConfig: LoupeConfig
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

        // 1. Pre-solve Cursor Trajectory at 120 Hz
        var builtCursor: [CursorFrameState] = []
        builtCursor.reserveCapacity(totalSteps)

        let dt = stepMs / 1000.0
        let cursorSpring = document.cursor.spring
        let firstPos = cursorEvents.first.map { Point01(x: $0.x, y: $0.y) } ?? .center

        var curX = firstPos.x
        var curY = firstPos.y
        var velX = 0.0
        var velY = 0.0
        var filteredTargetX = firstPos.x
        var filteredTargetY = firstPos.y
        var lastMoveTimeMs = 0.0
        var currentOpacity = 1.0

        // Dead-zone threshold in normalized units (assuming ~1440p reference)
        let shakeThreshold01 = max(0.0, document.cursor.removeShakeThresholdPx) / 1600.0

        var eventIdx = 0
        let eventCount = cursorEvents.count

        for step in 0..<totalSteps {
            let tMs = Double(step) * stepMs

            while eventIdx + 1 < eventCount && cursorEvents[eventIdx + 1].t <= tMs {
                eventIdx += 1
            }

            var rawTargetX = firstPos.x
            var rawTargetY = firstPos.y
            var cursorKind = "arrow"

            if eventCount > 0 {
                let e0 = cursorEvents[eventIdx]
                cursorKind = e0.c
                if eventIdx + 1 < eventCount {
                    let e1 = cursorEvents[eventIdx + 1]
                    let span = max(0.001, e1.t - e0.t)
                    let frac = max(0.0, min(1.0, (tMs - e0.t) / span))
                    rawTargetX = e0.x + (e1.x - e0.x) * frac
                    rawTargetY = e0.y + (e1.y - e0.y) * frac
                } else {
                    rawTargetX = e0.x
                    rawTargetY = e0.y
                }
            }

            // Optional loop back to initial position at end of video
            if let loopMs = document.cursor.loopBackToStartMs, loopMs > 0, tMs > totalDuration - loopMs {
                let factor = max(0.0, min(1.0, (tMs - (totalDuration - loopMs)) / loopMs))
                rawTargetX = rawTargetX + (firstPos.x - rawTargetX) * factor
                rawTargetY = rawTargetY + (firstPos.y - rawTargetY) * factor
            }

            // Micro-shake filter
            let dist = hypot(rawTargetX - filteredTargetX, rawTargetY - filteredTargetY)
            if dist > shakeThreshold01 {
                filteredTargetX = rawTargetX
                filteredTargetY = rawTargetY
                lastMoveTimeMs = tMs
            }

            if document.cursor.smoothMovementEnabled {
                let ax = -(cursorSpring.stiffness / cursorSpring.mass) * (curX - filteredTargetX)
                    - (cursorSpring.damping / cursorSpring.mass) * velX
                let ay = -(cursorSpring.stiffness / cursorSpring.mass) * (curY - filteredTargetY)
                    - (cursorSpring.damping / cursorSpring.mass) * velY
                velX += ax * dt
                velY += ay * dt
                curX += velX * dt
                curY += velY * dt
            } else {
                velX = (filteredTargetX - curX) / dt
                velY = (filteredTargetY - curY) / dt
                curX = filteredTargetX
                curY = filteredTargetY
            }

            // Auto-hide when idle
            if let idleLimit = document.cursor.hideWhenIdleAfterMs, idleLimit > 0 {
                let idleDuration = tMs - lastMoveTimeMs
                let targetOpacity = idleDuration > idleLimit ? 0.0 : 1.0
                currentOpacity += (targetOpacity - currentOpacity) * min(1.0, dt * 10.0)
            } else {
                currentOpacity = 1.0
            }

            // Velocity banking tilt
            var rotation = 0.0
            if document.cursor.velocityRotationEnabled {
                let maxTilt = 0.42 // ~24 degrees max
                let rawTilt = -velX * 0.18 * document.cursor.velocityRotationIntensity
                rotation = max(-maxTilt, min(maxTilt, rawTilt))
            }

            // Active click ripple progress (420 ms ripple window)
            var activeRipple: Double? = nil
            let rippleDurationMs = 420.0
            for click in clickEvents where click.type == "down" {
                let elapsed = tMs - click.t
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

        // 2. Pre-solve Virtual Camera Zoom & Pan Trajectory at 120 Hz
        var builtCamera: [CameraFrameState] = []
        builtCamera.reserveCapacity(totalSteps)

        let camSpring = document.motion.cameraSpring
        var camX = 0.5
        var camY = 0.5
        var camScale = 1.0
        var camVelX = 0.0
        var camVelY = 0.0
        var camScaleVel = 0.0

        let activeZooms = document.timeline.isZoomTrackHidden
            ? []
            : document.timeline.zooms.filter { !$0.disabled }

        for step in 0..<totalSteps {
            let tMs = Double(step) * stepMs
            let cursorAtStep = builtCursor[step].position01

            // Find active zoom block (with 250ms anticipation lead-in)
            let activeZoom = activeZooms.first { z in
                tMs >= z.sourceStartMs && tMs <= z.sourceEndMs
            }

            var targetScale = 1.0
            var targetX = 0.5
            var targetY = 0.5
            var isLoupe = false
            var loupeCfg = LoupeConfig()

            if let zoom = activeZoom {
                isLoupe = (zoom.presentation == .loupe)
                loupeCfg = zoom.loupe
                targetScale = max(1.0, zoom.scale)
                switch zoom.mode {
                case .followCursor:
                    targetX = cursorAtStep.x
                    targetY = cursorAtStep.y
                case .manual:
                    targetX = zoom.manualCenter01.x
                    targetY = zoom.manualCenter01.y
                }

                if !isLoupe && document.motion.avoidEmptyBoundsWhenZooming && targetScale > 1.001 {
                    let halfSpan = 0.5 / targetScale
                    targetX = max(halfSpan, min(1.0 - halfSpan, targetX))
                    targetY = max(halfSpan, min(1.0 - halfSpan, targetY))
                }
            }

            let ax = -(camSpring.stiffness / camSpring.mass) * (camX - targetX)
                - (camSpring.damping / camSpring.mass) * camVelX
            let ay = -(camSpring.stiffness / camSpring.mass) * (camY - targetY)
                - (camSpring.damping / camSpring.mass) * camVelY
            let az = -(camSpring.stiffness / camSpring.mass) * (camScale - targetScale)
                - (camSpring.damping / camSpring.mass) * camScaleVel

            camVelX += ax * dt
            camVelY += ay * dt
            camScaleVel += az * dt

            camX += camVelX * dt
            camY += camVelY * dt
            camScale = max(1.0, camScale + camScaleVel * dt)

            if document.motion.avoidEmptyBoundsWhenZooming && camScale > 1.001 {
                let halfSpan = 0.5 / camScale
                camX = max(halfSpan, min(1.0 - halfSpan, camX))
                camY = max(halfSpan, min(1.0 - halfSpan, camY))
            }

            builtCamera.append(
                CameraFrameState(
                    center01: Point01(x: camX, y: camY),
                    scale: camScale,
                    velocity01PerSec: Point01(x: camVelX, y: camVelY),
                    scaleVelocityPerSec: camScaleVel,
                    isLoupeMode: isLoupe,
                    loupeConfig: loupeCfg
                )
            )
        }

        self.cameraStates = builtCamera
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
                    loupeConfig: LoupeConfig()
                )
            )
        }

        let exactIndex = max(0.0, min(Double(cursorStates.count - 1), sourceMs / stepMs))
        let idx = Int(exactIndex)
        return (cursorStates[idx], cameraStates[idx])
    }
}

// MARK: - Auto-Zoom Click Cluster & Typing Hold Generator

public enum AutoZoomClusterGenerator {
    /// Automatically groups mouse clicks and typing activity into smooth cinematic ZoomBlocks.
    public static func generateZooms(
        clicks: [ClickEvent],
        keys: [KeyStrokeEvent],
        durationMs: Double,
        defaultScale: Double = 1.8
    ) -> [ZoomBlock] {
        let downClicks = clicks.filter { $0.type == "down" }.sorted { $0.t < $1.t }
        guard !downClicks.isEmpty else { return [] }

        let clusterGapMs = 3500.0
        let leadInMs = 350.0
        let holdAfterClickMs = 1800.0
        let holdAfterTypingMs = 1400.0
        let minZoomDurationMs = 2200.0

        var blocks: [ZoomBlock] = []

        var clusterStart = max(0.0, downClicks[0].t - leadInMs)
        var clusterEnd = min(durationMs, downClicks[0].t + holdAfterClickMs)
        var centerAccumX = downClicks[0].x
        var centerAccumY = downClicks[0].y
        var clickCount = 1

        for i in 1..<downClicks.count {
            let click = downClicks[i]
            // Extend clusterEnd if typing occurred right after the previous click
            let typingInWindow = keys.filter { $0.t >= clusterStart && $0.t <= clusterEnd + 2500.0 }
            if let lastKey = typingInWindow.last {
                clusterEnd = max(clusterEnd, min(durationMs, lastKey.t + holdAfterTypingMs))
            }

            if click.t - clusterEnd <= clusterGapMs {
                clusterEnd = max(clusterEnd, min(durationMs, click.t + holdAfterClickMs))
                centerAccumX += click.x
                centerAccumY += click.y
                clickCount += 1
            } else {
                if clusterEnd - clusterStart < minZoomDurationMs {
                    clusterEnd = min(durationMs, clusterStart + minZoomDurationMs)
                }
                blocks.append(
                    ZoomBlock(
                        sourceStartMs: clusterStart,
                        sourceEndMs: clusterEnd,
                        scale: defaultScale,
                        mode: .followCursor,
                        presentation: .screen,
                        manualCenter01: Point01(
                            x: centerAccumX / Double(clickCount),
                            y: centerAccumY / Double(clickCount)
                        )
                    )
                )
                clusterStart = max(0.0, click.t - leadInMs)
                clusterEnd = min(durationMs, click.t + holdAfterClickMs)
                centerAccumX = click.x
                centerAccumY = click.y
                clickCount = 1
            }
        }

        // Final cluster typing extension
        let typingInFinal = keys.filter { $0.t >= clusterStart && $0.t <= clusterEnd + 2500.0 }
        if let lastKey = typingInFinal.last {
            clusterEnd = max(clusterEnd, min(durationMs, lastKey.t + holdAfterTypingMs))
        }
        if clusterEnd - clusterStart < minZoomDurationMs {
            clusterEnd = min(durationMs, clusterStart + minZoomDurationMs)
        }
        blocks.append(
            ZoomBlock(
                sourceStartMs: clusterStart,
                sourceEndMs: clusterEnd,
                scale: defaultScale,
                mode: .followCursor,
                presentation: .screen,
                manualCenter01: Point01(
                    x: centerAccumX / Double(clickCount),
                    y: centerAccumY / Double(clickCount)
                )
            )
        )

        return normalizeNonOverlappingZooms(blocks, durationMs: durationMs)
    }

    /// Ensures zoom blocks on the Zoom track are strictly sorted and non-overlapping (touching edge-to-edge with 0ms gap).
    public static func normalizeNonOverlappingZooms(_ blocks: [ZoomBlock], durationMs: Double) -> [ZoomBlock] {
        let sorted = blocks.sorted { $0.sourceStartMs < $1.sourceStartMs }
        var result: [ZoomBlock] = []

        for var block in sorted {
            block.sourceStartMs = max(0.0, min(durationMs - 200.0, block.sourceStartMs))
            block.sourceEndMs = max(block.sourceStartMs + 200.0, min(durationMs, block.sourceEndMs))

            if let last = result.last {
                if block.sourceStartMs < last.sourceEndMs {
                    block.sourceStartMs = last.sourceEndMs
                    if block.sourceEndMs - block.sourceStartMs < 250.0 {
                        continue
                    }
                }
            }
            result.append(block)
        }
        return result
    }
}
