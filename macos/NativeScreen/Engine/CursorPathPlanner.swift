import Foundation

/// Plans the smoothed cursor so it reaches every interaction on time without giving up the spring's glide (ADR-87).
///
/// The cursor is a plain damped spring that chases the recorded path at `t + lead(t)`. Lead is zero by default. Only
/// where the free spring would miss an interaction (click, drag, cursor-shape change) does the planner raise the lead
/// and, if that is not enough, speed the spring up (stiffness x s^2, damping x s). It picks the smallest speed level
/// and then the smallest lead that keeps the tip within `acceptedErrorRatio * tolerance` points at each anchor. Lead
/// changes are hidden in cursor rests where possible, and target time never runs slower than 0.65x or faster than
/// 1.4x real time, so the glide never visibly stalls or rushes.
///
/// Everything here works in capture points (logical pixels), in playback milliseconds of one continuous run.
enum CursorPathPlanner {
    struct Settings {
        var groupGapMs = 100.0
        var mergeGapMs = 400.0
        var maxLeadMs = 600.0
        var approachWindowMs = 1500.0
        var compressionWindowMs = 400.0
        var maxCompressionRate = 1.4
        var leadDecayPerMs = 0.35
        var speedLevels: [Double] = [1, 1.25, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32]
        var speedBlendInMs = 250.0
        var speedBlendOutMs = 300.0
        var acceptedErrorRatio = 0.75
        /// Longest group made by merging across a still-decaying lead.
        var maxMergedSpanMs = 4000.0
        static let standard = Settings()
    }

    /// Allowed tip error, in points, at each kind of anchor.
    enum Tolerance {
        static let click = 2.0
        static let drag = 2.0
        static let hover = 4.0
        static let cursorImage = 6.0
    }

    struct PathPoint: Sendable { var t: Double; var x: Double; var y: Double }
    struct SyncPoint: Sendable { var t: Double; var tolerance: Double }

    static func plan(points: [PathPoint], syncPoints: [SyncPoint], spring: SpringConfig, durationMs: Double,
                     settings: Settings = .standard) -> PlannedCursorPath {
        let path = Path(points)
        let simulation = Simulation(path: path, spring: spring)
        let start = min(0, path.startMs)
        var groups = groupSyncPoints(syncPoints.sorted { $0.t < $1.t }, gapMs: settings.groupGapMs)
        var lead = LeadCurve()
        var speed = SpeedCurve()

        struct Committed { let group: Group; let choice: Choice; let leadBefore: LeadCurve; let speedBefore: SpeedCurve }
        var committed: [Committed] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let previous = committed.last
            let context = Context(
                anchorMs: previous?.group.endMs ?? start,
                anchorLeadMs: previous?.choice.endLeadMs ?? 0,
                anchorState: previous?.choice.endState ?? SpringState(resting: path.position(at: start)),
                lead: lead, speed: speed)
            var chooser = GroupChooser(path: path, simulation: simulation, settings: settings, group: group, context: context)
            let choice = chooser.choose()
            // A group that cannot be met on its own is solved together with the one just before it: when they are
            // close, or while the previous lead is still decaying, since that lead
            // is what pushes the target ahead here.
            if choice.errorRatio > 1, let previous,
               group.startMs - previous.group.endMs <= settings.mergeGapMs
                || (group.endMs - previous.group.startMs <= settings.maxMergedSpanMs
                    && previous.choice.leadStillActive(at: group.startMs, after: previous.group.endMs, path: path, settings: settings)) {
                committed.removeLast()
                lead = previous.leadBefore
                speed = previous.speedBefore
                groups[index] = Group(startMs: previous.group.startMs, endMs: group.endMs,
                                      points: previous.group.points + group.points)
                continue
            }
            let leadBefore = lead, speedBefore = speed
            choice.commit(to: &lead, &speed)
            committed.append(Committed(group: group, choice: choice, leadBefore: leadBefore, speedBefore: speedBefore))
            index += 1
        }
        let last = committed.last
        for knot in decayKnots(path, anchorMs: last?.group.endMs ?? start, anchorLeadMs: last?.choice.endLeadMs ?? 0,
                               settings: settings) {
            lead.add(knot.t, knot.lead)
        }
        return PlannedCursorPath.simulate(simulation, lead: lead, speed: speed, durationMs: durationMs)
    }

    // MARK: - Path

    /// Linear interpolation between recorded samples (pause holds are already expanded by the caller).
    final class Path {
        let ts: [Double], xs: [Double], ys: [Double]
        /// Time ranges in which the recorded cursor moves, sorted and disjoint.
        let moving: [(start: Double, end: Double)]
        private var hint = 0

        init(_ points: [PathPoint]) {
            ts = points.map(\.t); xs = points.map(\.x); ys = points.map(\.y)
            var ranges: [(start: Double, end: Double)] = []
            for i in 1..<max(1, points.count) {
                let a = points[i - 1], b = points[i]
                if a.x == b.x && a.y == b.y { continue }
                if let lastEnd = ranges.last?.end, lastEnd >= a.t {
                    ranges[ranges.count - 1].end = max(lastEnd, b.t)
                } else {
                    ranges.append((a.t, max(b.t, a.t + 0.000001)))
                }
            }
            moving = ranges
        }

        var startMs: Double { ts.first ?? 0 }

        func position(at t: Double) -> (x: Double, y: Double) {
            guard !ts.isEmpty else { return (0, 0) }
            let i = index(at: t)
            if i < 0 { return (xs[0], ys[0]) }
            let j = i + 1
            if j >= ts.count || ts[j] == ts[i] { return (xs[i], ys[i]) }
            let f = (t - ts[i]) / (ts[j] - ts[i])
            return (xs[i] + (xs[j] - xs[i]) * f, ys[i] + (ys[j] - ys[i]) * f)
        }

        /// Last sample at or before `t`, or -1. Sequential lookups are O(1).
        private func index(at t: Double) -> Int {
            let n = ts.count
            for i in hint...min(hint + 1, n - 1) where ts[i] <= t && (i + 1 >= n || ts[i + 1] > t) {
                hint = i
                return i
            }
            let i = lastIndex(n) { ts[$0] <= t }
            hint = max(0, i)
            return i
        }

        private func movingIndex(at t: Double) -> Int { lastIndex(moving.count) { moving[$0].start <= t } }

        func isStill(between a: Double, and b: Double) -> Bool {
            if b < a { return isStill(between: b, and: a) }
            let i = movingIndex(at: b)
            return i < 0 || moving[i].end <= a
        }

        /// The rest that ends where the last movement starting at or before `t` begins.
        func lastRest(endingBy t: Double) -> (start: Double, end: Double)? {
            let i = movingIndex(at: t)
            guard i >= 0 else { return nil }
            return (i > 0 ? moving[i - 1].end : -.infinity, moving[i].start)
        }
    }

    // MARK: - Lead and speed

    /// Piecewise-linear lead in ms, zero before the first knot.
    struct LeadCurve {
        private(set) var knots: [(t: Double, lead: Double)] = []
        private var hint = 0

        mutating func add(_ t: Double, _ lead: Double) {
            // Knots ascend by construction; clamping only guards against rounding.
            knots.append((max(t, knots.last?.t ?? t), lead))
        }

        mutating func planned(at t: Double) -> Double {
            let n = knots.count
            guard n > 0 else { return 0 }
            var i = -1
            if hint < n {
                for k in hint...min(hint + 1, n - 1) where knots[k].t <= t && (k + 1 >= n || knots[k + 1].t > t) {
                    i = k
                    break
                }
            }
            if i < 0 { i = lastIndex(n) { knots[$0].t <= t } }
            hint = max(0, i)
            guard i >= 0 else { return 0 }
            let a = knots[i]
            guard i + 1 < n, knots[i + 1].t != a.t else { return a.lead }
            let b = knots[i + 1]
            return a.lead + (b.lead - a.lead) * (t - a.t) / (b.t - a.t)
        }

        mutating func at(_ t: Double) -> Double { max(0, planned(at: t)) }
    }

    struct SpeedBump {
        var rampInStartMs: Double
        var fullStartMs: Double
        var fullEndMs: Double
        var rampOutEndMs: Double
        var speed: Double
        var logSpeed: Double { log(speed) }

        func logSpeed(at t: Double) -> Double {
            if t < fullStartMs {
                let ramp = fullStartMs - rampInStartMs
                return ramp <= 0 ? logSpeed : logSpeed * (t - rampInStartMs) / ramp
            }
            if t <= fullEndMs { return logSpeed }
            let ramp = rampOutEndMs - fullEndMs
            return ramp <= 0 ? 0 : logSpeed * (rampOutEndMs - t) / ramp
        }
    }

    /// Spring speed multiplier: the strongest active bump, blended in log space.
    struct SpeedCurve {
        private(set) var bumps: [SpeedBump] = []
        private var longestBumpMs = 0.0

        mutating func add(_ bump: SpeedBump) {
            guard bump.speed > 1 else { return }
            bumps.append(bump)
            bumps.sort { $0.rampInStartMs < $1.rampInStartMs }
            longestBumpMs = max(longestBumpMs, bump.rampOutEndMs - bump.rampInStartMs)
        }

        func at(_ t: Double) -> Double {
            guard !bumps.isEmpty else { return 1 }
            var best = 0.0
            var i = lastIndex(bumps.count) { bumps[$0].rampInStartMs <= t }
            while i >= 0 {
                let bump = bumps[i]
                if bump.rampInStartMs < t - longestBumpMs { break }
                if bump.rampOutEndMs > t { best = max(best, bump.logSpeed(at: t)) }
                i -= 1
            }
            return exp(best)
        }
    }

    // MARK: - Simulation

    struct SpringState { var x: Double; var y: Double; var vx: Double; var vy: Double
        init(x: Double, y: Double, vx: Double, vy: Double) { self.x = x; self.y = y; self.vx = vx; self.vy = vy }
        init(resting p: (x: Double, y: Double)) { self.init(x: p.x, y: p.y, vx: 0, vy: 0) }
    }

    struct Simulation {
        let path: Path
        let stiffness: Double, damping: Double, mass: Double
        /// Points: below this speed and distance an axis snaps onto its target.
        static let precision = 0.01

        init(path: Path, spring: SpringConfig) {
            self.path = path
            stiffness = max(1, spring.stiffness)
            damping = max(0, spring.damping)
            mass = max(0.05, spring.mass)
        }

        /// The spring's steady-state lag behind a constant-velocity target.
        var lagMs: Double { damping / stiffness * 1000 }

        func target(_ lead: inout LeadCurve, at t: Double) -> (x: Double, y: Double) {
            path.position(at: t + lead.at(t))
        }

        /// Integrates in 1 ms steps (fractional at the ends). Spring speed is re-read every 4 ms. `sample` receives each
        /// whole millisecond.
        func run(_ leadCurve: LeadCurve, _ speed: SpeedCurve, from: Double, to: Double, state: SpringState,
                 sample: ((Double, Double, Double) -> Void)? = nil) -> SpringState {
            var lead = leadCurve
            var s = state
            var t = from
            var quantum = Double.nan
            var k = 0.0, c = 0.0, omega = 0.0, critical = 0.0
            while t < to {
                let next = min(to, floor(t) + 1)
                let target = self.target(&lead, at: next)
                if !(s.x == target.x && s.y == target.y && s.vx == 0 && s.vy == 0) {
                    let q = floor(next / 4) * 4
                    if q != quantum {
                        quantum = q
                        let m = speed.at(q)
                        k = stiffness * m * m
                        c = damping * m
                        omega = sqrt(k / mass)
                        critical = max(c, 2 * sqrt(mass * k))
                    }
                    let dt = (next - t) / 1000
                    let dx = target.x - s.x, dy = target.y - s.y
                    // Overshoot clamp: approaching faster than the spring can stop switches to critical damping.
                    let cx = s.vx * dx > 0 && abs(s.vx) > abs(dx) * omega ? critical : c
                    let cy = s.vy * dy > 0 && abs(s.vy) > abs(dy) * omega ? critical : c
                    s.vx += (dx * k - s.vx * cx) / mass * dt
                    s.vy += (dy * k - s.vy * cy) / mass * dt
                    s.x += s.vx * dt
                    s.y += s.vy * dt
                    if abs(s.vx) < Self.precision && abs(s.x - target.x) < Self.precision { s.x = target.x; s.vx = 0 }
                    if abs(s.vy) < Self.precision && abs(s.y - target.y) < Self.precision { s.y = target.y; s.vy = 0 }
                }
                t = next
                if let sample, t == floor(t) { sample(t, s.x, s.y) }
            }
            return s
        }
    }

    // MARK: - Groups and choices

    struct Group { var startMs: Double; var endMs: Double; var points: [SyncPoint] }

    static func groupSyncPoints(_ sorted: [SyncPoint], gapMs: Double) -> [Group] {
        var groups: [Group] = []
        for point in sorted {
            if let last = groups.last, point.t - last.endMs <= gapMs {
                groups[groups.count - 1].points.append(point)
                groups[groups.count - 1].endMs = point.t
            } else {
                groups.append(Group(startMs: point.t, endMs: point.t, points: [point]))
            }
        }
        return groups
    }

    /// After an anchor, lead drops to zero: at once while the cursor rests, otherwise at `leadDecayPerMs`.
    static func decayKnots(_ path: Path, anchorMs: Double, anchorLeadMs: Double,
                           settings: Settings) -> [(t: Double, lead: Double)] {
        if anchorLeadMs <= 0 { return [(anchorMs, 0)] }
        if path.isStill(between: anchorMs, and: anchorMs + anchorLeadMs) {
            return [(anchorMs, anchorLeadMs), (anchorMs + 0.001, 0)]
        }
        return [(anchorMs, anchorLeadMs), (anchorMs + anchorLeadMs / settings.leadDecayPerMs, 0)]
    }

    struct Context {
        var anchorMs: Double
        var anchorLeadMs: Double
        var anchorState: SpringState
        var lead: LeadCurve
        var speed: SpeedCurve
    }

    struct Choice {
        var leadMs: Double
        var speed: Double
        var errorRatio: Double
        var endState: SpringState
        var leadKnots: [(t: Double, lead: Double)]
        var speedBump: SpeedBump?

        var endLeadMs: Double { leadKnots.last?.lead ?? 0 }

        /// Whether this choice's lead has not decayed to zero by `t` (see `decayKnots`).
        func leadStillActive(at t: Double, after anchorMs: Double, path: Path, settings: Settings) -> Bool {
            let lead = endLeadMs
            guard lead > 0, !path.isStill(between: anchorMs, and: anchorMs + lead) else { return false }
            return t < anchorMs + lead / settings.leadDecayPerMs
        }

        func commit(to lead: inout LeadCurve, _ speed: inout SpeedCurve) {
            for knot in leadKnots { lead.add(knot.t, knot.lead) }
            if let speedBump { speed.add(speedBump) }
        }
    }

    struct GroupChooser {
        let path: Path
        let simulation: Simulation
        let settings: Settings
        let group: Group
        let context: Context
        let windowStartMs: Double
        private var committedStates: [SpringState]?

        init(path: Path, simulation: Simulation, settings: Settings, group: Group, context: Context) {
            self.path = path
            self.simulation = simulation
            self.settings = settings
            self.group = group
            self.context = context
            windowStartMs = floor(max(context.anchorMs, group.startMs - settings.approachWindowMs - settings.maxLeadMs))
        }

        /// Smallest speed level that meets the tolerance (binary search), else the best one tried.
        mutating func choose() -> Choice {
            let levels = settings.speedLevels
            var memo: [Int: Choice] = [:]
            func choice(_ level: Int) -> Choice {
                if let known = memo[level] { return known }
                let made = chooseLead(speed: levels[level])
                memo[level] = made
                return made
            }
            let first = choice(0)
            if first.errorRatio <= settings.acceptedErrorRatio { return first }
            var lo = 0, hi = levels.count - 1
            if choice(hi).errorRatio > settings.acceptedErrorRatio {
                return memo.values.min { $0.errorRatio < $1.errorRatio }!
            }
            while hi - lo > 1 {
                let mid = (lo + hi) >> 1
                if choice(mid).errorRatio <= settings.acceptedErrorRatio { hi = mid } else { lo = mid }
            }
            return choice(hi)
        }

        /// Smallest lead that meets the tolerance at this speed, else the lead with the smallest error.
        mutating func chooseLead(speed: Double) -> Choice {
            let maxLead = settings.maxLeadMs
            var candidates: Set<Double> = [0]
            var lead = simulation.lagMs / speed / 8
            while lead > 0 && lead < maxLead { candidates.insert(lead); lead *= 2 }
            candidates.insert(maxLead)
            let sorted = candidates.sorted()
            var results: [Choice?] = []
            var best = -1
            for (i, lead) in sorted.enumerated() {
                let bestError = best < 0 ? Double.infinity : results[best]!.errorRatio
                let result = tryKnobs(lead: lead, speed: speed, giveUpAbove: max(settings.acceptedErrorRatio, bestError))
                results.append(result)
                guard let result else { continue }
                if result.errorRatio <= settings.acceptedErrorRatio {
                    return i == 0 ? result : refineLead(sorted[i - 1], lead, result, speed: speed)
                }
                if result.errorRatio < bestError { best = i }
            }
            if best < 0 { return tryKnobs(lead: 0, speed: speed)! }
            return minimizeLead(sorted[max(0, best - 1)], sorted[min(sorted.count - 1, best + 1)], results[best]!, speed: speed)
        }

        /// Bisects between a failing and a passing lead for the smallest passing one.
        mutating func refineLead(_ failing: Double, _ passing: Double, _ found: Choice, speed: Double) -> Choice {
            var lo = failing, hi = passing, best = found
            for _ in 0..<6 where hi - lo > 0.5 {
                let mid = (lo + hi) / 2
                if let r = tryKnobs(lead: mid, speed: speed), r.errorRatio <= settings.acceptedErrorRatio {
                    best = r; hi = mid
                } else {
                    lo = mid
                }
            }
            return best
        }

        /// Golden-section search for the lead with the smallest error.
        mutating func minimizeLead(_ a: Double, _ b: Double, _ found: Choice, speed: Double) -> Choice {
            let golden = (sqrt(5.0) - 1) / 2
            var lo = a, hi = b, best = found
            for _ in 0..<12 where hi - lo > 0.25 {
                let c1 = hi - (hi - lo) * golden, c2 = lo + (hi - lo) * golden
                let r1 = tryKnobs(lead: c1, speed: speed), r2 = tryKnobs(lead: c2, speed: speed)
                let e1 = r1?.errorRatio ?? .infinity, e2 = r2?.errorRatio ?? .infinity
                if let r1, e1 < best.errorRatio { best = r1 }
                if let r2, e2 < best.errorRatio { best = r2 }
                if best.errorRatio <= settings.acceptedErrorRatio { return best }
                if e1 < e2 { hi = c2 } else { lo = c1 }
            }
            return best
        }

        /// Simulates one lead/speed choice through the group and measures the worst anchor error ratio.
        mutating func tryKnobs(lead leadMs: Double, speed: Double, giveUpAbove: Double = .infinity) -> Choice? {
            guard let plan = leadKnots(leadMs) else { return nil }
            var lead = context.lead
            for knot in plan.knots { lead.add(knot.t, knot.lead) }
            var speedCurve = context.speed
            let bump: SpeedBump? = speed > 1 ? SpeedBump(
                rampInStartMs: max(context.anchorMs, group.startMs - settings.speedBlendInMs),
                fullStartMs: group.startMs, fullEndMs: group.endMs,
                rampOutEndMs: group.endMs + settings.speedBlendOutMs, speed: speed) : nil
            if let bump { speedCurve.add(bump) }
            let changesFrom = min(plan.changesFromMs, bump?.rampInStartMs ?? .infinity, group.startMs)
            var t = max(windowStartMs, floor(changesFrom))
            var state = committedState(at: t)
            var worst = 0.0
            for point in group.points {
                state = simulation.run(lead, speedCurve, from: t, to: point.t, state: state)
                t = point.t
                let target = path.position(at: point.t)
                worst = max(worst, hypot(state.x - target.x, state.y - target.y) / point.tolerance)
                if worst > giveUpAbove { break }
            }
            return Choice(leadMs: leadMs, speed: speed, errorRatio: worst, endState: state,
                          leadKnots: plan.knots, speedBump: bump)
        }

        /// The committed trajectory (previous choices plus decay) from the window start to the group, per ms.
        mutating func committedState(at t: Double) -> SpringState {
            if committedStates == nil {
                var lead = context.lead
                for knot in decayKnots(path, anchorMs: context.anchorMs, anchorLeadMs: context.anchorLeadMs, settings: settings) {
                    lead.add(knot.t, knot.lead)
                }
                var s = simulation.run(lead, context.speed, from: context.anchorMs, to: windowStartMs, state: context.anchorState)
                let count = max(1, Int(ceil(group.startMs) - windowStartMs) + 1)
                var states = [SpringState]()
                states.reserveCapacity(count)
                states.append(s)
                for i in 1..<max(1, count) {
                    let from = windowStartMs + Double(i - 1)
                    s = simulation.run(lead, context.speed, from: from, to: from + 1, state: s)
                    states.append(s)
                }
                committedStates = states
            }
            let states = committedStates!
            let i = Int(min(Double(states.count - 1), max(0, t - windowStartMs)))
            return states[i]
        }

        /// Lead knots for a target lead: hold or decay the previous lead, then raise to `leadMs` before the group.
        func leadKnots(_ leadMs: Double) -> (knots: [(t: Double, lead: Double)], changesFromMs: Double)? {
            var base = LeadCurve()
            let decay = decayKnots(path, anchorMs: context.anchorMs, anchorLeadMs: context.anchorLeadMs, settings: settings)
            for knot in decay { base.add(knot.t, knot.lead) }
            if leadMs <= 0 {
                return (decay.filter { $0.t < group.endMs } + [(group.endMs, base.planned(at: group.endMs))], group.startMs)
            }
            guard let raise = findLeadRaise(leadMs, &base) else { return nil }
            return (decay.filter { $0.t < raise.at } + [
                (raise.at, base.planned(at: raise.at)),
                (raise.at + 0.001, raise.jumpTo),
                (group.startMs, leadMs),
                (group.endMs, leadMs)
            ], raise.at)
        }

        /// Where the lead can start rising: preferably a jump inside a rest (invisible, the target does not move),
        /// otherwise a compression over the last `compressionWindowMs`. Target time must keep a rate within limits.
        func findLeadRaise(_ leadMs: Double, _ base: inout LeadCurve) -> (at: Double, jumpTo: Double)? {
            let groupStart = group.startMs
            let from = max(context.anchorMs, groupStart - settings.approachWindowMs)
            func rateOK(_ at: Double, _ jump: Double) -> Bool {
                let rate = (groupStart + leadMs - (at + jump)) / (groupStart - at)
                return rate >= 1 - settings.leadDecayPerMs && rate <= settings.maxCompressionRate
            }
            var rest = path.lastRest(endingBy: groupStart + leadMs)
            while let r = rest, r.end > from {
                let at = min(groupStart - 1, max(from, r.end - leadMs))
                let current = base.planned(at: at)
                let jump = min(leadMs, r.end - at)
                if at + min(jump, current) >= r.start && at + max(jump, current) <= r.end && rateOK(at, jump) {
                    return (at, jump)
                }
                rest = path.lastRest(endingBy: r.start)
            }
            let compressionStart = max(context.anchorMs, groupStart - settings.compressionWindowMs)
            if compressionStart >= groupStart { return nil }
            let current = base.planned(at: compressionStart)
            return rateOK(compressionStart, current) ? (compressionStart, current) : nil
        }
    }
}

extension SpringTrajectorySolver {
    /// Builds the planner's path (points, shake-filtered, with the ending options) and its anchors, then plans it.
    static func planCursor(
        events: [CursorSampleEvent], clicks: [ClickEvent], document: ProjectDocument, spring: SpringConfig,
        durationMs: Double, pointSize: MotionPointSize, expandPauses: Bool, shakeThresholdPt: Double,
        stopMoveCutoffMs: Double?, loopStartMs: Double?, stepMs: Double,
        endingAdjusted: ((x: Double, y: Double), Double) -> (x: Double, y: Double)
    ) -> PlannedCursorPath {
        typealias Planner = CursorPathPlanner
        let held = CursorTelemetry.heldIntervals(clicks, endMs: durationMs)
        let anchors = clicks.filter { $0.type == "down" || $0.type == "up" }
        let anchorTimes = Set(anchors.map(\.t))

        // Recorded samples, with recording-time pauses held until shortly before the next sample.
        var source: [(t: Double, x: Double, y: Double)] = []
        source.reserveCapacity(events.count + 16)
        for (i, e) in events.enumerated() {
            if expandPauses, i > 0, e.t - events[i - 1].t > 48 {
                source.append((e.t - 16, events[i - 1].x, events[i - 1].y))
            }
            source.append((e.t, e.x, e.y))
        }

        // Shake filter: small moves are dropped, except while a button is held and at the clicks themselves.
        var filtered: [(t: Double, x: Double, y: Double)] = []
        filtered.reserveCapacity(source.count)
        var skippedMs: Double? = nil
        var heldIndex = 0
        for e in source {
            while heldIndex < held.count && held[heldIndex].end < e.t { heldIndex += 1 }
            let isHeld = heldIndex < held.count && e.t >= held[heldIndex].start
            if let last = filtered.last, shakeThresholdPt > 0, !isHeld, !anchorTimes.contains(e.t),
               pointSize.distance(Point01(x: e.x, y: e.y), Point01(x: last.x, y: last.y)) <= shakeThresholdPt {
                skippedMs = e.t
                continue
            }
            if let skipped = skippedMs, let last = filtered.last, skipped > last.t { filtered.append((skipped, last.x, last.y)) }
            skippedMs = nil
            filtered.append(e)
        }
        if filtered.isEmpty { filtered = [(0, 0.5, 0.5)] }

        func filteredPosition(at t: Double) -> (x: Double, y: Double) {
            var lo = 0, hi = filtered.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if filtered[mid].t <= t { lo = mid + 1 } else { hi = mid }
            }
            if lo == 0 { return (filtered[0].x, filtered[0].y) }
            let a = filtered[lo - 1]
            guard lo < filtered.count else { return (a.x, a.y) }
            let b = filtered[lo]
            let f = (t - a.t) / max(0.000001, b.t - a.t)
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }

        var points: [Planner.PathPoint] = []
        points.reserveCapacity(filtered.count + 64)
        let tailStart = loopStartMs ?? stopMoveCutoffMs
        for p in filtered where tailStart.map({ p.t < $0 }) ?? true {
            points.append(.init(t: p.t, x: p.x * pointSize.width, y: p.y * pointSize.height))
        }
        if let tailStart {
            // The ending is resampled at 120 Hz: a hold after "stop moving", or a blend toward the start for a loop.
            var t = tailStart
            while t <= durationMs + stepMs {
                let p = endingAdjusted(filteredPosition(at: stopMoveCutoffMs.map { min(t, $0) } ?? t), t)
                points.append(.init(t: t, x: p.x * pointSize.width, y: p.y * pointSize.height))
                t += stepMs
            }
        }

        // Anchors the cursor must reach on time. Nothing after the ending starts is synchronized.
        let syncEndMs = tailStart ?? durationMs
        var sync: [Planner.SyncPoint] = anchors.filter { $0.t <= syncEndMs }.map { .init(t: $0.t, tolerance: Planner.Tolerance.click) }
        heldIndex = 0
        for e in events where e.t <= syncEndMs && !anchorTimes.contains(e.t) {
            while heldIndex < held.count && held[heldIndex].end <= e.t { heldIndex += 1 }
            if heldIndex < held.count && e.t > held[heldIndex].start { sync.append(.init(t: e.t, tolerance: Planner.Tolerance.drag)) }
        }
        if !document.cursor.alwaysUsePointer {
            // No hover telemetry is recorded; cursor-shape changes mark where hovered UI reacts.
            let tolerance = document.cursor.keepInSyncWithHovers ? Planner.Tolerance.hover : Planner.Tolerance.cursorImage
            for i in events.indices.dropFirst() where events[i].c != events[i - 1].c && events[i].t <= syncEndMs {
                sync.append(.init(t: events[i].t, tolerance: tolerance))
            }
        }
        return Planner.plan(points: points, syncPoints: sync, spring: spring, durationMs: durationMs)
    }
}

/// The planned cursor, sampled every playback millisecond, in points.
public struct PlannedCursorPath: Sendable {
    let startMs: Double
    let xs: [Float]
    let ys: [Float]

    static func simulate(_ simulation: CursorPathPlanner.Simulation, lead: CursorPathPlanner.LeadCurve,
                         speed: CursorPathPlanner.SpeedCurve, durationMs: Double) -> PlannedCursorPath {
        let start = min(0, floor(simulation.path.startMs))
        var leadCopy = lead
        let initial = simulation.target(&leadCopy, at: start)
        let end = max(start, ceil(durationMs))
        var xs: [Float] = [Float(initial.x)], ys: [Float] = [Float(initial.y)]
        xs.reserveCapacity(Int(end - start) + 1)
        ys.reserveCapacity(Int(end - start) + 1)
        _ = simulation.run(lead, speed, from: start, to: end, state: .init(resting: initial)) { _, x, y in
            xs.append(Float(x)); ys.append(Float(y))
        }
        return PlannedCursorPath(startMs: start, xs: xs, ys: ys)
    }

    func position(at t: Double) -> (x: Double, y: Double) {
        let offset = t - startMs
        if offset <= 0 { return (Double(xs[0]), Double(ys[0])) }
        let last = xs.count - 1
        if offset >= Double(last) { return (Double(xs[last]), Double(ys[last])) }
        let i = Int(offset), f = offset - Double(i)
        return (Double(xs[i]) + Double(xs[i + 1] - xs[i]) * f, Double(ys[i]) + Double(ys[i + 1] - ys[i]) * f)
    }
}

/// Index of the last element whose predicate holds in a sorted-by-predicate range `0..<count`, or -1.
private func lastIndex(_ count: Int, _ isAtOrBefore: (Int) -> Bool) -> Int {
    var lo = 0, hi = count
    while lo < hi {
        let mid = (lo + hi) >> 1
        if isAtOrBefore(mid) { lo = mid + 1 } else { hi = mid }
    }
    return lo - 1
}
