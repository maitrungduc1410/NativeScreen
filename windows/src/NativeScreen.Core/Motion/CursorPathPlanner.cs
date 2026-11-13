namespace NativeScreen.Core;

/// <summary>
/// Plans the smoothed cursor so it reaches every interaction on time without giving up the spring's glide (spec/06 ADR-87,
/// a line-by-line port of the macOS `CursorPathPlanner`).
///
/// The cursor is a plain damped spring that chases the recorded path at t + lead(t). Lead is zero by default. Only where the
/// free spring would miss an interaction (click, drag, cursor-shape change) does the planner raise the lead and, if that is not
/// enough, speed the spring up (stiffness x s^2, damping x s). It picks the smallest speed level and then the smallest lead that
/// keeps the tip within AcceptedErrorRatio x tolerance points at each anchor. Lead changes are hidden in cursor rests where
/// possible, and target time never runs slower than 0.65x or faster than 1.4x real time.
///
/// Everything works in capture points, in playback milliseconds of one continuous run. The Swift curves are value types, so
/// every copy that is then extended is a <c>Clone()</c> here.
/// </summary>
internal static class CursorPathPlanner
{
    internal sealed class Settings
    {
        public double GroupGapMs { get; init; } = 100;
        public double MergeGapMs { get; init; } = 400;
        public double MaxLeadMs { get; init; } = 600;
        public double ApproachWindowMs { get; init; } = 1500;
        public double CompressionWindowMs { get; init; } = 400;
        public double MaxCompressionRate { get; init; } = 1.4;
        public double LeadDecayPerMs { get; init; } = 0.35;
        public double[] SpeedLevels { get; init; } = [1, 1.25, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32];
        public double SpeedBlendInMs { get; init; } = 250;
        public double SpeedBlendOutMs { get; init; } = 300;
        public double AcceptedErrorRatio { get; init; } = 0.75;

        /// <summary>Longest group made by merging across a still-decaying lead.</summary>
        public double MaxMergedSpanMs { get; init; } = 4000;

        public static Settings Standard { get; } = new();
    }

    /// <summary>Allowed tip error, in points, at each kind of anchor.</summary>
    internal static class Tolerance
    {
        public const double Click = 2;
        public const double Drag = 2;
        public const double Hover = 4;
        public const double CursorImage = 6;
    }

    internal readonly record struct PathPoint(double T, double X, double Y);

    internal readonly record struct SyncPoint(double T, double Tolerance);

    internal readonly record struct Knot(double T, double Lead);

    public static PlannedCursorPath Plan(IReadOnlyList<PathPoint> points, IReadOnlyList<SyncPoint> syncPoints, SpringConfig spring, double durationMs, Settings? settings = null)
    {
        settings ??= Settings.Standard;
        var path = new Path(points);
        var simulation = new Simulation(path, spring);
        var start = Math.Min(0, path.StartMs);
        var groups = GroupSyncPoints([.. syncPoints.OrderBy(point => point.T)], settings.GroupGapMs);
        var lead = new LeadCurve();
        var speed = new SpeedCurve();

        var committed = new List<(Group Group, Choice Choice, LeadCurve LeadBefore, SpeedCurve SpeedBefore)>();
        var index = 0;
        while (index < groups.Count)
        {
            var group = groups[index];
            (Group Group, Choice Choice, LeadCurve LeadBefore, SpeedCurve SpeedBefore)? previous = committed.Count > 0 ? committed[^1] : null;
            var context = new Context(
                previous?.Group.EndMs ?? start,
                previous?.Choice.EndLeadMs ?? 0,
                previous?.Choice.EndState ?? SpringState.Resting(path.Position(start)),
                lead.Clone(),
                speed.Clone());
            var chooser = new GroupChooser(path, simulation, settings, group, context);
            var choice = chooser.Choose();
            // A group that cannot be met on its own is solved together with the one just before it: when they are close, or
            // while the previous lead is still decaying, since that lead is what pushes the target ahead here.
            if (choice.ErrorRatio > 1 && previous is { } before
                && (group.StartMs - before.Group.EndMs <= settings.MergeGapMs
                    || (group.EndMs - before.Group.StartMs <= settings.MaxMergedSpanMs
                        && before.Choice.LeadStillActive(group.StartMs, before.Group.EndMs, path, settings))))
            {
                committed.RemoveAt(committed.Count - 1);
                lead = before.LeadBefore;
                speed = before.SpeedBefore;
                groups[index] = new Group(before.Group.StartMs, group.EndMs, [.. before.Group.Points, .. group.Points]);
                continue;
            }

            var leadBefore = lead.Clone();
            var speedBefore = speed.Clone();
            choice.Commit(lead, speed);
            committed.Add((group, choice, leadBefore, speedBefore));
            index++;
        }

        (Group Group, Choice Choice, LeadCurve LeadBefore, SpeedCurve SpeedBefore)? last = committed.Count > 0 ? committed[^1] : null;
        foreach (var knot in DecayKnots(path, last?.Group.EndMs ?? start, last?.Choice.EndLeadMs ?? 0, settings))
        {
            lead.Add(knot.T, knot.Lead);
        }

        return PlannedCursorPath.Simulate(simulation, lead, speed, durationMs);
    }

    /// <summary>Index of the last element whose predicate holds in a range sorted by the predicate, or -1.</summary>
    private static int LastIndex(int count, Func<int, bool> isAtOrBefore)
    {
        var lo = 0;
        var hi = count;
        while (lo < hi)
        {
            var mid = (lo + hi) >> 1;
            if (isAtOrBefore(mid))
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        return lo - 1;
    }

    /// <summary>Linear interpolation between recorded samples (pause holds are already expanded by the caller).</summary>
    internal sealed class Path
    {
        private readonly double[] ts;
        private readonly double[] xs;
        private readonly double[] ys;
        private int hint;

        /// <summary>Time ranges in which the recorded cursor moves, sorted and disjoint.</summary>
        public List<(double Start, double End)> Moving { get; }

        public Path(IReadOnlyList<PathPoint> points)
        {
            ts = new double[points.Count];
            xs = new double[points.Count];
            ys = new double[points.Count];
            for (var i = 0; i < points.Count; i++)
            {
                ts[i] = points[i].T;
                xs[i] = points[i].X;
                ys[i] = points[i].Y;
            }

            var ranges = new List<(double Start, double End)>();
            for (var i = 1; i < Math.Max(1, points.Count); i++)
            {
                var a = points[i - 1];
                var b = points[i];
                if (a.X == b.X && a.Y == b.Y)
                {
                    continue;
                }

                if (ranges.Count > 0 && ranges[^1].End >= a.T)
                {
                    ranges[^1] = (ranges[^1].Start, Math.Max(ranges[^1].End, b.T));
                }
                else
                {
                    ranges.Add((a.T, Math.Max(b.T, a.T + 0.000001)));
                }
            }

            Moving = ranges;
        }

        public double StartMs => ts.Length > 0 ? ts[0] : 0;

        public (double X, double Y) Position(double t)
        {
            if (ts.Length == 0)
            {
                return (0, 0);
            }

            var i = Index(t);
            if (i < 0)
            {
                return (xs[0], ys[0]);
            }

            var j = i + 1;
            if (j >= ts.Length || ts[j] == ts[i])
            {
                return (xs[i], ys[i]);
            }

            var f = (t - ts[i]) / (ts[j] - ts[i]);
            return (xs[i] + (xs[j] - xs[i]) * f, ys[i] + (ys[j] - ys[i]) * f);
        }

        /// <summary>Last sample at or before <paramref name="t"/>, or -1. Sequential lookups are O(1).</summary>
        private int Index(double t)
        {
            var n = ts.Length;
            for (var i = hint; i <= Math.Min(hint + 1, n - 1); i++)
            {
                if (ts[i] <= t && (i + 1 >= n || ts[i + 1] > t))
                {
                    hint = i;
                    return i;
                }
            }

            var found = LastIndex(n, k => ts[k] <= t);
            hint = Math.Max(0, found);
            return found;
        }

        private int MovingIndex(double t) => LastIndex(Moving.Count, k => Moving[k].Start <= t);

        public bool IsStill(double a, double b)
        {
            if (b < a)
            {
                return IsStill(b, a);
            }

            var i = MovingIndex(b);
            return i < 0 || Moving[i].End <= a;
        }

        /// <summary>The rest that ends where the last movement starting at or before <paramref name="t"/> begins.</summary>
        public (double Start, double End)? LastRest(double t)
        {
            var i = MovingIndex(t);
            if (i < 0)
            {
                return null;
            }

            return (i > 0 ? Moving[i - 1].End : double.NegativeInfinity, Moving[i].Start);
        }
    }

    /// <summary>Piecewise-linear lead in ms, zero before the first knot.</summary>
    internal sealed class LeadCurve
    {
        private readonly List<Knot> knots;
        private int hint;

        public LeadCurve() => knots = [];

        private LeadCurve(List<Knot> knots) => this.knots = knots;

        public LeadCurve Clone() => new([.. knots]);

        public void Add(double t, double lead) =>
            // Knots ascend by construction; clamping only guards against rounding.
            knots.Add(new Knot(Math.Max(t, knots.Count > 0 ? knots[^1].T : t), lead));

        public double Planned(double t)
        {
            var n = knots.Count;
            if (n == 0)
            {
                return 0;
            }

            var i = -1;
            if (hint < n)
            {
                for (var k = hint; k <= Math.Min(hint + 1, n - 1); k++)
                {
                    if (knots[k].T <= t && (k + 1 >= n || knots[k + 1].T > t))
                    {
                        i = k;
                        break;
                    }
                }
            }

            if (i < 0)
            {
                i = LastIndex(n, k => knots[k].T <= t);
            }

            hint = Math.Max(0, i);
            if (i < 0)
            {
                return 0;
            }

            var a = knots[i];
            if (i + 1 >= n || knots[i + 1].T == a.T)
            {
                return a.Lead;
            }

            var b = knots[i + 1];
            return a.Lead + (b.Lead - a.Lead) * (t - a.T) / (b.T - a.T);
        }

        public double At(double t) => Math.Max(0, Planned(t));
    }

    internal readonly record struct SpeedBump(double RampInStartMs, double FullStartMs, double FullEndMs, double RampOutEndMs, double Speed)
    {
        public double LogSpeed => Math.Log(Speed);

        public double LogSpeedAt(double t)
        {
            if (t < FullStartMs)
            {
                var ramp = FullStartMs - RampInStartMs;
                return ramp <= 0 ? LogSpeed : LogSpeed * (t - RampInStartMs) / ramp;
            }

            if (t <= FullEndMs)
            {
                return LogSpeed;
            }

            var rampOut = RampOutEndMs - FullEndMs;
            return rampOut <= 0 ? 0 : LogSpeed * (RampOutEndMs - t) / rampOut;
        }
    }

    /// <summary>Spring speed multiplier: the strongest active bump, blended in log space.</summary>
    internal sealed class SpeedCurve
    {
        private readonly List<SpeedBump> bumps;
        private double longestBumpMs;

        public SpeedCurve() => bumps = [];

        private SpeedCurve(List<SpeedBump> bumps, double longest)
        {
            this.bumps = bumps;
            longestBumpMs = longest;
        }

        public SpeedCurve Clone() => new([.. bumps], longestBumpMs);

        public void Add(SpeedBump bump)
        {
            if (bump.Speed <= 1)
            {
                return;
            }

            bumps.Add(bump);
            // Stable, like Swift's sort for these keys: equal starts keep their order.
            var sorted = bumps.OrderBy(item => item.RampInStartMs).ToList();
            bumps.Clear();
            bumps.AddRange(sorted);
            longestBumpMs = Math.Max(longestBumpMs, bump.RampOutEndMs - bump.RampInStartMs);
        }

        public double At(double t)
        {
            if (bumps.Count == 0)
            {
                return 1;
            }

            var best = 0.0;
            var i = LastIndex(bumps.Count, k => bumps[k].RampInStartMs <= t);
            while (i >= 0)
            {
                var bump = bumps[i];
                if (bump.RampInStartMs < t - longestBumpMs)
                {
                    break;
                }

                if (bump.RampOutEndMs > t)
                {
                    best = Math.Max(best, bump.LogSpeedAt(t));
                }

                i--;
            }

            return Math.Exp(best);
        }
    }

    internal readonly record struct SpringState(double X, double Y, double Vx, double Vy)
    {
        public static SpringState Resting((double X, double Y) p) => new(p.X, p.Y, 0, 0);
    }

    internal sealed class Simulation
    {
        /// <summary>Points: below this speed and distance an axis snaps onto its target.</summary>
        public const double Precision = 0.01;

        public Path Path { get; }
        public double Stiffness { get; }
        public double Damping { get; }
        public double Mass { get; }

        public Simulation(Path path, SpringConfig spring)
        {
            Path = path;
            Stiffness = Math.Max(1, spring.Stiffness);
            Damping = Math.Max(0, spring.Damping);
            Mass = Math.Max(0.05, spring.Mass);
        }

        /// <summary>The spring's steady-state lag behind a constant-velocity target.</summary>
        public double LagMs => Damping / Stiffness * 1000;

        public (double X, double Y) Target(LeadCurve lead, double t) => Path.Position(t + lead.At(t));

        /// <summary>
        /// Integrates in 1 ms steps (fractional at the ends). Spring speed is re-read every 4 ms. <paramref name="sample"/>
        /// receives each whole millisecond.
        /// </summary>
        public SpringState Run(LeadCurve lead, SpeedCurve speed, double from, double to, SpringState state, Action<double, double, double>? sample = null)
        {
            var x = state.X;
            var y = state.Y;
            var vx = state.Vx;
            var vy = state.Vy;
            var t = from;
            var quantum = double.NaN;
            double k = 0, c = 0, omega = 0, critical = 0;
            while (t < to)
            {
                var next = Math.Min(to, Math.Floor(t) + 1);
                var target = Target(lead, next);
                if (!(x == target.X && y == target.Y && vx == 0 && vy == 0))
                {
                    var q = Math.Floor(next / 4) * 4;
                    if (q != quantum)
                    {
                        quantum = q;
                        var m = speed.At(q);
                        k = Stiffness * m * m;
                        c = Damping * m;
                        omega = Math.Sqrt(k / Mass);
                        critical = Math.Max(c, 2 * Math.Sqrt(Mass * k));
                    }

                    var dt = (next - t) / 1000;
                    var dx = target.X - x;
                    var dy = target.Y - y;
                    // Overshoot clamp: approaching faster than the spring can stop switches to critical damping.
                    var cx = vx * dx > 0 && Math.Abs(vx) > Math.Abs(dx) * omega ? critical : c;
                    var cy = vy * dy > 0 && Math.Abs(vy) > Math.Abs(dy) * omega ? critical : c;
                    vx += (dx * k - vx * cx) / Mass * dt;
                    vy += (dy * k - vy * cy) / Mass * dt;
                    x += vx * dt;
                    y += vy * dt;
                    if (Math.Abs(vx) < Precision && Math.Abs(x - target.X) < Precision)
                    {
                        x = target.X;
                        vx = 0;
                    }

                    if (Math.Abs(vy) < Precision && Math.Abs(y - target.Y) < Precision)
                    {
                        y = target.Y;
                        vy = 0;
                    }
                }

                t = next;
                if (sample is not null && t == Math.Floor(t))
                {
                    sample(t, x, y);
                }
            }

            return new SpringState(x, y, vx, vy);
        }
    }

    internal sealed record Group(double StartMs, double EndMs, List<SyncPoint> Points);

    internal static List<Group> GroupSyncPoints(IReadOnlyList<SyncPoint> sorted, double gapMs)
    {
        var groups = new List<Group>();
        foreach (var point in sorted)
        {
            if (groups.Count > 0 && point.T - groups[^1].EndMs <= gapMs)
            {
                groups[^1].Points.Add(point);
                groups[^1] = groups[^1] with { EndMs = point.T };
            }
            else
            {
                groups.Add(new Group(point.T, point.T, [point]));
            }
        }

        return groups;
    }

    /// <summary>After an anchor, lead drops to zero: at once while the cursor rests, otherwise at LeadDecayPerMs.</summary>
    internal static List<Knot> DecayKnots(Path path, double anchorMs, double anchorLeadMs, Settings settings)
    {
        if (anchorLeadMs <= 0)
        {
            return [new Knot(anchorMs, 0)];
        }

        if (path.IsStill(anchorMs, anchorMs + anchorLeadMs))
        {
            return [new Knot(anchorMs, anchorLeadMs), new Knot(anchorMs + 0.001, 0)];
        }

        return [new Knot(anchorMs, anchorLeadMs), new Knot(anchorMs + anchorLeadMs / settings.LeadDecayPerMs, 0)];
    }

    internal sealed record Context(double AnchorMs, double AnchorLeadMs, SpringState AnchorState, LeadCurve Lead, SpeedCurve Speed);

    internal sealed record Choice(double LeadMs, double Speed, double ErrorRatio, SpringState EndState, List<Knot> LeadKnots, SpeedBump? SpeedBump)
    {
        public double EndLeadMs => LeadKnots.Count > 0 ? LeadKnots[^1].Lead : 0;

        /// <summary>Whether this choice's lead has not decayed to zero by <paramref name="t"/> (see DecayKnots).</summary>
        public bool LeadStillActive(double t, double anchorMs, Path path, Settings settings)
        {
            var lead = EndLeadMs;
            if (lead <= 0 || path.IsStill(anchorMs, anchorMs + lead))
            {
                return false;
            }

            return t < anchorMs + lead / settings.LeadDecayPerMs;
        }

        public void Commit(LeadCurve lead, SpeedCurve speed)
        {
            foreach (var knot in LeadKnots)
            {
                lead.Add(knot.T, knot.Lead);
            }

            if (SpeedBump is { } bump)
            {
                speed.Add(bump);
            }
        }
    }

    internal sealed class GroupChooser
    {
        private readonly Path path;
        private readonly Simulation simulation;
        private readonly Settings settings;
        private readonly Group group;
        private readonly Context context;
        private readonly double windowStartMs;
        private SpringState[]? committedStates;

        public GroupChooser(Path path, Simulation simulation, Settings settings, Group group, Context context)
        {
            this.path = path;
            this.simulation = simulation;
            this.settings = settings;
            this.group = group;
            this.context = context;
            windowStartMs = Math.Floor(Math.Max(context.AnchorMs, group.StartMs - settings.ApproachWindowMs - settings.MaxLeadMs));
        }

        /// <summary>Smallest speed level that meets the tolerance (binary search), else the best one tried.</summary>
        public Choice Choose()
        {
            var levels = settings.SpeedLevels;
            var memo = new Dictionary<int, Choice>();
            Choice ChoiceAt(int level)
            {
                if (memo.TryGetValue(level, out var known))
                {
                    return known;
                }

                var made = ChooseLead(levels[level]);
                memo[level] = made;
                return made;
            }

            var first = ChoiceAt(0);
            if (first.ErrorRatio <= settings.AcceptedErrorRatio)
            {
                return first;
            }

            var lo = 0;
            var hi = levels.Length - 1;
            if (ChoiceAt(hi).ErrorRatio > settings.AcceptedErrorRatio)
            {
                var best = first;
                foreach (var entry in memo.OrderBy(entry => entry.Key))
                {
                    if (entry.Value.ErrorRatio < best.ErrorRatio)
                    {
                        best = entry.Value;
                    }
                }

                return best;
            }

            while (hi - lo > 1)
            {
                var mid = (lo + hi) >> 1;
                if (ChoiceAt(mid).ErrorRatio <= settings.AcceptedErrorRatio)
                {
                    hi = mid;
                }
                else
                {
                    lo = mid;
                }
            }

            return ChoiceAt(hi);
        }

        /// <summary>Smallest lead that meets the tolerance at this speed, else the lead with the smallest error.</summary>
        private Choice ChooseLead(double speed)
        {
            var maxLead = settings.MaxLeadMs;
            var candidates = new SortedSet<double> { 0 };
            var lead = simulation.LagMs / speed / 8;
            while (lead > 0 && lead < maxLead)
            {
                candidates.Add(lead);
                lead *= 2;
            }

            candidates.Add(maxLead);
            var sorted = candidates.ToArray();
            var best = -1;
            Choice? bestChoice = null;
            for (var i = 0; i < sorted.Length; i++)
            {
                var bestError = bestChoice?.ErrorRatio ?? double.PositiveInfinity;
                var result = TryKnobs(sorted[i], speed, Math.Max(settings.AcceptedErrorRatio, bestError));
                if (result is null)
                {
                    continue;
                }

                if (result.ErrorRatio <= settings.AcceptedErrorRatio)
                {
                    return i == 0 ? result : RefineLead(sorted[i - 1], sorted[i], result, speed);
                }

                if (result.ErrorRatio < bestError)
                {
                    best = i;
                    bestChoice = result;
                }
            }

            if (bestChoice is null)
            {
                // A zero lead has no raise to place, so it always yields a choice.
                return TryKnobs(0, speed) ?? throw new InvalidOperationException("A zero lead always has knots.");
            }

            return MinimizeLead(sorted[Math.Max(0, best - 1)], sorted[Math.Min(sorted.Length - 1, best + 1)], bestChoice, speed);
        }

        /// <summary>Bisects between a failing and a passing lead for the smallest passing one.</summary>
        private Choice RefineLead(double failing, double passing, Choice found, double speed)
        {
            var lo = failing;
            var hi = passing;
            var best = found;
            for (var i = 0; i < 6 && hi - lo > 0.5; i++)
            {
                var mid = (lo + hi) / 2;
                if (TryKnobs(mid, speed) is { } r && r.ErrorRatio <= settings.AcceptedErrorRatio)
                {
                    best = r;
                    hi = mid;
                }
                else
                {
                    lo = mid;
                }
            }

            return best;
        }

        /// <summary>Golden-section search for the lead with the smallest error.</summary>
        private Choice MinimizeLead(double a, double b, Choice found, double speed)
        {
            var golden = (Math.Sqrt(5.0) - 1) / 2;
            var lo = a;
            var hi = b;
            var best = found;
            for (var i = 0; i < 12 && hi - lo > 0.25; i++)
            {
                var c1 = hi - (hi - lo) * golden;
                var c2 = lo + (hi - lo) * golden;
                var r1 = TryKnobs(c1, speed);
                var r2 = TryKnobs(c2, speed);
                var e1 = r1?.ErrorRatio ?? double.PositiveInfinity;
                var e2 = r2?.ErrorRatio ?? double.PositiveInfinity;
                if (r1 is not null && e1 < best.ErrorRatio)
                {
                    best = r1;
                }

                if (r2 is not null && e2 < best.ErrorRatio)
                {
                    best = r2;
                }

                if (best.ErrorRatio <= settings.AcceptedErrorRatio)
                {
                    return best;
                }

                if (e1 < e2)
                {
                    hi = c2;
                }
                else
                {
                    lo = c1;
                }
            }

            return best;
        }

        /// <summary>Simulates one lead/speed choice through the group and measures the worst anchor error ratio.</summary>
        private Choice? TryKnobs(double leadMs, double speed, double giveUpAbove = double.PositiveInfinity)
        {
            if (LeadKnots(leadMs) is not { } plan)
            {
                return null;
            }

            var lead = context.Lead.Clone();
            foreach (var knot in plan.Knots)
            {
                lead.Add(knot.T, knot.Lead);
            }

            var speedCurve = context.Speed.Clone();
            SpeedBump? bump = speed > 1
                ? new SpeedBump(Math.Max(context.AnchorMs, group.StartMs - settings.SpeedBlendInMs), group.StartMs, group.EndMs, group.EndMs + settings.SpeedBlendOutMs, speed)
                : null;
            if (bump is { } added)
            {
                speedCurve.Add(added);
            }

            var changesFrom = Math.Min(plan.ChangesFromMs, Math.Min(bump?.RampInStartMs ?? double.PositiveInfinity, group.StartMs));
            var t = Math.Max(windowStartMs, Math.Floor(changesFrom));
            var state = CommittedState(t);
            var worst = 0.0;
            foreach (var point in group.Points)
            {
                state = simulation.Run(lead, speedCurve, t, point.T, state);
                t = point.T;
                var target = path.Position(point.T);
                var dx = state.X - target.X;
                var dy = state.Y - target.Y;
                worst = Math.Max(worst, Math.Sqrt(dx * dx + dy * dy) / point.Tolerance);
                if (worst > giveUpAbove)
                {
                    break;
                }
            }

            return new Choice(leadMs, speed, worst, state, plan.Knots, bump);
        }

        /// <summary>The committed trajectory (previous choices plus decay) from the window start to the group, per ms.</summary>
        private SpringState CommittedState(double t)
        {
            if (committedStates is null)
            {
                var lead = context.Lead.Clone();
                foreach (var knot in DecayKnots(path, context.AnchorMs, context.AnchorLeadMs, settings))
                {
                    lead.Add(knot.T, knot.Lead);
                }

                var s = simulation.Run(lead, context.Speed, context.AnchorMs, windowStartMs, context.AnchorState);
                var count = Math.Max(1, (int)(Math.Ceiling(group.StartMs) - windowStartMs) + 1);
                var states = new SpringState[count];
                states[0] = s;
                for (var i = 1; i < count; i++)
                {
                    var from = windowStartMs + (i - 1);
                    s = simulation.Run(lead, context.Speed, from, from + 1, s);
                    states[i] = s;
                }

                committedStates = states;
            }

            var index = (int)Math.Min(committedStates.Length - 1, Math.Max(0, t - windowStartMs));
            return committedStates[index];
        }

        /// <summary>Lead knots for a target lead: hold or decay the previous lead, then raise to <paramref name="leadMs"/> before the group.</summary>
        private (List<Knot> Knots, double ChangesFromMs)? LeadKnots(double leadMs)
        {
            var baseCurve = new LeadCurve();
            var decay = DecayKnots(path, context.AnchorMs, context.AnchorLeadMs, settings);
            foreach (var knot in decay)
            {
                baseCurve.Add(knot.T, knot.Lead);
            }

            if (leadMs <= 0)
            {
                var kept = decay.Where(knot => knot.T < group.EndMs).ToList();
                kept.Add(new Knot(group.EndMs, baseCurve.Planned(group.EndMs)));
                return (kept, group.StartMs);
            }

            if (FindLeadRaise(leadMs, baseCurve) is not { } raise)
            {
                return null;
            }

            var knots = decay.Where(knot => knot.T < raise.At).ToList();
            knots.Add(new Knot(raise.At, baseCurve.Planned(raise.At)));
            knots.Add(new Knot(raise.At + 0.001, raise.JumpTo));
            knots.Add(new Knot(group.StartMs, leadMs));
            knots.Add(new Knot(group.EndMs, leadMs));
            return (knots, raise.At);
        }

        /// <summary>
        /// Where the lead can start rising: preferably a jump inside a rest (invisible, the target does not move), otherwise a
        /// compression over the last CompressionWindowMs. Target time must keep a rate within limits.
        /// </summary>
        private (double At, double JumpTo)? FindLeadRaise(double leadMs, LeadCurve baseCurve)
        {
            var groupStart = group.StartMs;
            var from = Math.Max(context.AnchorMs, groupStart - settings.ApproachWindowMs);
            bool RateOk(double at, double jump)
            {
                var rate = (groupStart + leadMs - (at + jump)) / (groupStart - at);
                return rate >= 1 - settings.LeadDecayPerMs && rate <= settings.MaxCompressionRate;
            }

            var rest = path.LastRest(groupStart + leadMs);
            while (rest is { } r && r.End > from)
            {
                var at = Math.Min(groupStart - 1, Math.Max(from, r.End - leadMs));
                var current = baseCurve.Planned(at);
                var jump = Math.Min(leadMs, r.End - at);
                if (at + Math.Min(jump, current) >= r.Start && at + Math.Max(jump, current) <= r.End && RateOk(at, jump))
                {
                    return (at, jump);
                }

                rest = path.LastRest(r.Start);
            }

            var compressionStart = Math.Max(context.AnchorMs, groupStart - settings.CompressionWindowMs);
            if (compressionStart >= groupStart)
            {
                return null;
            }

            var currentLead = baseCurve.Planned(compressionStart);
            return RateOk(compressionStart, currentLead) ? (compressionStart, currentLead) : null;
        }
    }
}
