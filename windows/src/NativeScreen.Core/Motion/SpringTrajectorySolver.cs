namespace NativeScreen.Core;

public sealed class SpringTrajectorySolver
{
    public sealed class CursorFrameState
    {
        public Point01 Position01 { get; set; } = Point01.Center;
        public Point01 Velocity01PerSec { get; set; } = Point01.Zero;
        public double RotationRadians { get; set; }
        public double Opacity { get; set; } = 1;
        public string CursorType { get; set; } = "arrow";
        public double? ActiveClickProgress { get; set; }
        public ClickWave[] ClickWaves { get; set; } = [];
    }

    public sealed class CameraFrameState
    {
        public Point01 Center01 { get; set; } = Point01.Center;
        public double Scale { get; set; } = 1;
        public Point01 Velocity01PerSec { get; set; } = Point01.Zero;
        public double ScaleVelocityPerSec { get; set; }
        public bool IsLoupeMode { get; set; }
        public double LoupePresence01 { get; set; }
        public double LoupeScale { get; set; } = 1;
        public LoupeConfig LoupeConfig { get; set; } = new();

        /// <summary>Where the lens is, in crop space. <see cref="Center01"/> always belongs to the screen camera (ADR-86).</summary>
        public Point01 LoupeCenter01 { get; set; } = Point01.Center;
    }

    private sealed class MovesGroup
    {
        public double MaxDistanceX { get; }
        public double MaxDistanceY { get; }
        public List<(double T, double X, double Y)> Samples { get; } = [];
        public double MinX { get; private set; } = double.PositiveInfinity;
        public double MaxX { get; private set; } = double.NegativeInfinity;
        public double MinY { get; private set; } = double.PositiveInfinity;
        public double MaxY { get; private set; } = double.NegativeInfinity;
        public double? FinishedTimeMs { get; set; }
        public double StartTimeMs => Samples.Count == 0 ? 0 : Samples[0].T;

        public MovesGroup(double maxDistanceX, double maxDistanceY)
        {
            MaxDistanceX = maxDistanceX;
            MaxDistanceY = maxDistanceY;
        }

        public bool CanAdd(double x, double y)
        {
            if (Samples.Count == 0)
            {
                return true;
            }

            var nextMinX = Math.Min(MinX, x);
            var nextMaxX = Math.Max(MaxX, x);
            var nextMinY = Math.Min(MinY, y);
            var nextMaxY = Math.Max(MaxY, y);
            return nextMaxX - nextMinX <= MaxDistanceX && nextMaxY - nextMinY <= MaxDistanceY;
        }

        public void Add(double t, double x, double y)
        {
            Samples.Add((t, x, y));
            MinX = Math.Min(MinX, x);
            MaxX = Math.Max(MaxX, x);
            MinY = Math.Min(MinY, y);
            MaxY = Math.Max(MaxY, y);
        }

        public Point01 TimeWeightedCenter()
        {
            if (Samples.Count == 0)
            {
                return Point01.Center;
            }

            var total = 0.0;
            var sumX = 0.0;
            var sumY = 0.0;
            for (var i = 0; i < Samples.Count; i++)
            {
                var sample = Samples[i];
                double next;
                if (i + 1 < Samples.Count)
                {
                    next = Samples[i + 1].T;
                }
                else if (FinishedTimeMs is double finished)
                {
                    next = finished;
                }
                else
                {
                    next = sample.T + 100;
                }

                var weight = Math.Max(0.001, (next - sample.T) / 1000.0);
                total += weight;
                sumX += sample.X * weight;
                sumY += sample.Y * weight;
            }

            if (total <= 0)
            {
                return new Point01(Samples[0].X, Samples[0].Y);
            }

            return new Point01(sumX / total, sumY / total);
        }
    }

    private readonly record struct FocusGroup(double StartTimeMs, Point01 Center01);

    private readonly struct PrecomputedSpring
    {
        public double Mass { get; }
        public double Stiffness { get; }
        public double BaseDamping { get; }
        public double NaturalFreq { get; }
        public double CriticalDamping { get; }

        public PrecomputedSpring(SpringConfig spring)
        {
            var mass = Math.Max(0.05, spring.Mass);
            var stiffness = Math.Max(1, spring.Stiffness);
            var damping = Math.Max(1, spring.Damping);
            Mass = mass;
            Stiffness = stiffness;
            BaseDamping = damping;
            NaturalFreq = Math.Sqrt(stiffness / mass);
            CriticalDamping = 2 * Math.Sqrt(mass * stiffness);
        }
    }

    public const double ClickWaveDurationMs = 900;
    public const int MaxActiveClickWaves = 3;

    private readonly double stepMs = 1000.0 / 120.0;

    /// <summary>A click whose ripple is still spreading, from where the cursor was when the button went down.</summary>
    public readonly record struct ClickWave(double AgeMs, Point01 Position01);
    public IReadOnlyList<CursorFrameState> CursorStates { get; }
    public IReadOnlyList<CameraFrameState> CameraStates { get; }

    /// <summary>False for camera-only recordings and projects made from a video: no cursor is drawn (spec/07 Pass 4).</summary>
    public bool HasRecordedCursor { get; }

    /// <summary>The planned smoothed cursor (ADR-87), sampled per ms in points. Null when smoothing is off.</summary>
    public PlannedCursorPath? PlannedCursor { get; }

    private readonly MotionPointSize pointSize;

    /// <param name="pointSize">The capture's size in points (<see cref="MotionPointSize.Of"/>); tolerances and shake use points.</param>
    /// <param name="reusing">A solver of the same run whose cursor can be kept when only zooms, camera or crop changed.</param>
    /// <param name="startsAtCut">The run begins at a cut: the camera starts at its target, with no discarded history.</param>
    /// <param name="loopTarget01">Where "loop back to the start" returns: the first retained cursor position of the movie.</param>
    /// <param name="telemetryUsesPlaybackTime">The events are already projected onto playback time with pauses expanded.</param>
    public SpringTrajectorySolver(
        double durationMs,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        ProjectDocument document,
        MotionPointSize? pointSize = null,
        SpringTrajectorySolver? reusing = null,
        bool startsAtCut = false,
        Point01? loopTarget01 = null,
        bool telemetryUsesPlaybackTime = false)
    {
        HasRecordedCursor = cursorEvents.Count > 0;
        this.pointSize = pointSize ?? MotionPointSize.Reference;
        var totalDuration = Math.Max(100, durationMs);
        var totalSteps = Math.Max(2, (int)Math.Ceiling(totalDuration / stepMs) + 1);
        var dt = stepMs / 1000.0;
        var smooth = document.Cursor.SmoothMovementEnabled;
        var events = smooth
            ? CursorTelemetry.InsertingClicks(clickEvents, cursorEvents, !telemetryUsesPlaybackTime, this.pointSize)
            : cursorEvents;
        var cursorSpring = SanitizeCursor(document.Cursor.Spring);
        var camSpring = SanitizeCamera(document.Motion.CameraSpring);
        var camPrecomputed = new PrecomputedSpring(camSpring);

        // Reuse the cursor (states and planned path) when only zooms, camera or crop changed.
        if (reusing is { } old && old.CursorStates.Count == totalSteps && (!smooth || old.PlannedCursor is not null))
        {
            CursorStates = old.CursorStates;
            PlannedCursor = smooth ? old.PlannedCursor : null;
        }
        else
        {
            var (states, planned) = SolveCursor(document, events, clickEvents, cursorSpring, totalDuration, totalSteps, dt, loopTarget01, telemetryUsesPlaybackTime);
            CursorStates = states;
            PlannedCursor = planned;
        }

        CameraStates = SolveCamera(document, events, clickEvents, CursorStates, camSpring, camPrecomputed, totalSteps, dt, startsAtCut);
    }

    public (CursorFrameState Cursor, CameraFrameState Camera) Evaluate(double sourceMs)
    {
        if (CursorStates.Count == 0 || CameraStates.Count == 0)
        {
            return (new CursorFrameState(), new CameraFrameState());
        }

        var exact = Math.Max(0, Math.Min(CursorStates.Count - 1, sourceMs / stepMs));
        var i0 = (int)Math.Floor(exact);
        var i1 = Math.Min(CursorStates.Count - 1, i0 + 1);
        var frac = exact - i0;
        if (frac <= 0.0001 || i0 == i1)
        {
            return (CursorStates[i0], CameraStates[i0]);
        }

        var c0 = CursorStates[i0];
        var c1 = CursorStates[i1];
        var cursor = new CursorFrameState
        {
            Position01 = new Point01(
                c0.Position01.X + (c1.Position01.X - c0.Position01.X) * frac,
                c0.Position01.Y + (c1.Position01.Y - c0.Position01.Y) * frac),
            Velocity01PerSec = c0.Velocity01PerSec,
            RotationRadians = c0.RotationRadians + (c1.RotationRadians - c0.RotationRadians) * frac,
            Opacity = c0.Opacity + (c1.Opacity - c0.Opacity) * frac,
            CursorType = c0.CursorType,
            ActiveClickProgress = c0.ActiveClickProgress,
            ClickWaves = c0.ClickWaves
        };
        // The planned path is per ms, finer than the 120 Hz states, so clicks between steps stay exact.
        if (PlannedCursor is { } planned)
        {
            var (px, py) = planned.Position(sourceMs);
            cursor.Position01 = new Point01(px / pointSize.Width, py / pointSize.Height);
        }

        var a0 = CameraStates[i0];
        var a1 = CameraStates[i1];
        var camera = new CameraFrameState
        {
            Center01 = new Point01(
                a0.Center01.X + (a1.Center01.X - a0.Center01.X) * frac,
                a0.Center01.Y + (a1.Center01.Y - a0.Center01.Y) * frac),
            Scale = a0.Scale + (a1.Scale - a0.Scale) * frac,
            Velocity01PerSec = a0.Velocity01PerSec,
            ScaleVelocityPerSec = a0.ScaleVelocityPerSec,
            IsLoupeMode = a0.IsLoupeMode || a1.IsLoupeMode,
            LoupePresence01 = a0.LoupePresence01 + (a1.LoupePresence01 - a0.LoupePresence01) * frac,
            LoupeScale = a0.LoupeScale + (a1.LoupeScale - a0.LoupeScale) * frac,
            LoupeConfig = a0.LoupeConfig,
            LoupeCenter01 = new Point01(
                a0.LoupeCenter01.X + (a1.LoupeCenter01.X - a0.LoupeCenter01.X) * frac,
                a0.LoupeCenter01.Y + (a1.LoupeCenter01.Y - a0.LoupeCenter01.Y) * frac)
        };
        return (cursor, camera);
    }

    private (List<CursorFrameState> States, PlannedCursorPath? Planned) SolveCursor(
        ProjectDocument document,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        SpringConfig cursorSpring,
        double totalDuration,
        int totalSteps,
        double dt,
        Point01? loopTarget01,
        bool telemetryUsesPlaybackTime)
    {
        var solved = new List<CursorFrameState>(totalSteps);
        var first = cursorEvents.Count == 0 ? Point01.Center : new Point01(cursorEvents[0].X, cursorEvents[0].Y);
        var downClicks = clickEvents.Where(click => click.Type == "down").OrderBy(click => click.T).ToList();
        var downs = downClicks.Select(click => Math.Max(0, click.T)).ToList();
        var rippleWindow = 0;
        var curX = first.X;
        var curY = first.Y;
        var velX = 0.0;
        var velY = 0.0;
        var filteredX = first.X;
        var filteredY = first.Y;
        var lastMove = 0.0;
        var opacity = 1.0;
        var bearing = 0.0;
        var stableKind = "arrow";
        var lastKindChange = -1000.0;
        var shakePt = Math.Max(0, document.Cursor.RemoveShakeThresholdPx);
        double? stopCutoff = document.Cursor.LoopBackToStartMs is null && document.Cursor.StopMovementInLastPartMs > 0
            ? Math.Max(0, totalDuration - document.Cursor.StopMovementInLastPartMs)
            : null;
        double? loopMs = document.Cursor.LoopBackToStartMs is double loop && loop > 0 ? loop : null;
        double? loopStart = loopMs is double length ? Math.Max(0, totalDuration - length) : null;
        var loopTarget = loopTarget01 ?? first;
        var baseRad = -document.Cursor.BaseRotationDegrees * Math.PI / 180.0;
        const double rippleDuration = 450;
        var clickWaves = new List<ClickWave>();
        var nextWaveClick = 0;

        (double X, double Y, string Kind) Sample(double queryMs)
        {
            if (cursorEvents.Count == 0)
            {
                return (first.X, first.Y, "arrow");
            }

            var e = CursorTelemetry.Sample(cursorEvents, queryMs, !telemetryUsesPlaybackTime);
            return (e.X, e.Y, e.C);
        }

        // Where the recorded cursor is, including the ending options (stop moving, loop back to the start).
        (double X, double Y) EndingAdjusted((double X, double Y) p, double tMs)
        {
            if (loopStart is not double start || loopMs is not double duration || tMs <= start)
            {
                return p;
            }

            var f = Math.Clamp((tMs - start) / duration, 0, 1);
            return (p.X + (loopTarget.X - p.X) * f, p.Y + (loopTarget.Y - p.Y) * f);
        }

        var planned = document.Cursor.SmoothMovementEnabled
            ? PlanCursor(cursorEvents, clickEvents, document, cursorSpring, totalDuration, pointSize, !telemetryUsesPlaybackTime, shakePt, stopCutoff, loopStart, stepMs, EndingAdjusted)
            : null;

        for (var step = 0; step < totalSteps; step++)
        {
            var tMs = step * stepMs;
            var baseLookup = stopCutoff is double cutoff ? Math.Min(tMs, cutoff) : tMs;
            var sampledNow = Sample(baseLookup);
            var target = EndingAdjusted((sampledNow.X, sampledNow.Y), tMs);
            var kind = sampledNow.Kind;
            if (document.Cursor.AlwaysUsePointer)
            {
                kind = "arrow";
            }
            else if (document.Cursor.OptimizeCursorChanges)
            {
                if (kind != stableKind)
                {
                    if (tMs - lastKindChange >= 90)
                    {
                        stableKind = kind;
                        lastKindChange = tMs;
                    }
                    else
                    {
                        kind = stableKind;
                    }
                }
            }

            if (pointSize.Distance(target.X, target.Y, filteredX, filteredY) > shakePt)
            {
                filteredX = target.X;
                filteredY = target.Y;
                lastMove = tMs;
            }

            if (planned is not null)
            {
                var p = planned.Position(tMs);
                var before = planned.Position(tMs - 1);
                var after = planned.Position(tMs + 1);
                curX = p.X / pointSize.Width;
                curY = p.Y / pointSize.Height;
                velX = (after.X - before.X) / pointSize.Width / 0.002;
                velY = (after.Y - before.Y) / pointSize.Height / 0.002;
            }
            else
            {
                velX = step == 0 ? 0 : (filteredX - curX) / dt;
                velY = step == 0 ? 0 : (filteredY - curY) / dt;
                curX = filteredX;
                curY = filteredY;
            }

            if (document.Cursor.HideWhenIdleAfterMs is double idle && idle > 0)
            {
                var targetOpacity = tMs - lastMove > idle ? 0 : 1;
                opacity += (targetOpacity - opacity) * Math.Min(1, dt * 10);
            }
            else
            {
                opacity = 1;
            }

            var dynamic = 0.0;
            if (document.Cursor.VelocityRotationEnabled)
            {
                if (document.Cursor.RotationMode == CursorRotationMode.Tilt)
                {
                    dynamic = Math.Clamp(-velX * pointSize.Width / 1600.0 * 0.14 * document.Cursor.VelocityRotationIntensity, -0.35, 0.35);
                }
                else
                {
                    // Heading uses the physical aspect ratio, so a wide capture turns like the cursor really moves.
                    var physicalX = velX * pointSize.Width / 1600.0;
                    var physicalY = velY * pointSize.Height / 1600.0;
                    var speed = Math.Sqrt(physicalX * physicalX + physicalY * physicalY);
                    if (speed > 0.04)
                    {
                        var targetAngle = Math.Atan2(-physicalY, physicalX) - Math.PI * 0.75;
                        var delta = targetAngle - bearing;
                        while (delta > Math.PI)
                        {
                            delta -= 2 * Math.PI;
                        }

                        while (delta < -Math.PI)
                        {
                            delta += 2 * Math.PI;
                        }

                        bearing += delta * Math.Min(1, dt * 14);
                    }

                    dynamic = bearing;
                }
            }

            double? ripple = null;
            while (rippleWindow < downs.Count && downs[rippleWindow] < tMs - rippleDuration)
            {
                rippleWindow++;
            }

            for (var i = rippleWindow; i < downs.Count; i++)
            {
                var clickT = downs[i];
                if (clickT > tMs)
                {
                    break;
                }

                var elapsed = tMs - clickT;
                if (elapsed >= 0 && elapsed <= rippleDuration)
                {
                    ripple = elapsed / rippleDuration;
                }
            }

            for (var wave = 0; wave < clickWaves.Count; wave++)
            {
                clickWaves[wave] = clickWaves[wave] with { AgeMs = clickWaves[wave].AgeMs + stepMs };
            }

            clickWaves.RemoveAll(wave => wave.AgeMs > ClickWaveDurationMs);
            while (nextWaveClick < downs.Count && downs[nextWaveClick] <= tMs)
            {
                // A wave stays where the button went down, in recording coordinates (ADR-86).
                clickWaves.Add(new ClickWave(tMs - downs[nextWaveClick], new Point01(downClicks[nextWaveClick].X, downClicks[nextWaveClick].Y)));
                nextWaveClick++;
            }

            if (clickWaves.Count > MaxActiveClickWaves)
            {
                clickWaves.RemoveRange(0, clickWaves.Count - MaxActiveClickWaves);
            }

            solved.Add(new CursorFrameState
            {
                Position01 = new Point01(curX, curY),
                Velocity01PerSec = new Point01(velX, velY),
                RotationRadians = baseRad + dynamic,
                Opacity = document.Cursor.Hidden ? 0 : opacity,
                CursorType = kind,
                ActiveClickProgress = ripple,
                ClickWaves = clickWaves.Count == 0 ? [] : clickWaves.ToArray()
            });
        }

        return (solved, planned);
    }

    /// <summary>Builds the planner's path (points, shake-filtered, with the ending options) and its anchors, then plans it.</summary>
    private static PlannedCursorPath PlanCursor(
        IReadOnlyList<CursorSampleEvent> events,
        IReadOnlyList<ClickEvent> clicks,
        ProjectDocument document,
        SpringConfig spring,
        double durationMs,
        MotionPointSize pointSize,
        bool expandPauses,
        double shakeThresholdPt,
        double? stopMoveCutoffMs,
        double? loopStartMs,
        double stepMs,
        Func<(double X, double Y), double, (double X, double Y)> endingAdjusted)
    {
        var held = CursorTelemetry.HeldIntervals(clicks, durationMs);
        var anchors = clicks.Where(click => click.Type is "down" or "up").ToList();
        var anchorTimes = anchors.Select(anchor => anchor.T).ToHashSet();

        // Recorded samples, with recording-time pauses held until shortly before the next sample.
        var source = new List<(double T, double X, double Y)>(events.Count + 16);
        for (var i = 0; i < events.Count; i++)
        {
            var e = events[i];
            if (expandPauses && i > 0 && e.T - events[i - 1].T > 48)
            {
                source.Add((e.T - 16, events[i - 1].X, events[i - 1].Y));
            }

            source.Add((e.T, e.X, e.Y));
        }

        // Shake filter: small moves are dropped, except while a button is held and at the clicks themselves.
        var filtered = new List<(double T, double X, double Y)>(source.Count);
        double? skippedMs = null;
        var heldIndex = 0;
        foreach (var e in source)
        {
            while (heldIndex < held.Count && held[heldIndex].End < e.T)
            {
                heldIndex++;
            }

            var isHeld = heldIndex < held.Count && e.T >= held[heldIndex].Start;
            if (filtered.Count > 0 && shakeThresholdPt > 0 && !isHeld && !anchorTimes.Contains(e.T)
                && pointSize.Distance(e.X, e.Y, filtered[^1].X, filtered[^1].Y) <= shakeThresholdPt)
            {
                skippedMs = e.T;
                continue;
            }

            if (skippedMs is double skipped && filtered.Count > 0 && skipped > filtered[^1].T)
            {
                filtered.Add((skipped, filtered[^1].X, filtered[^1].Y));
            }

            skippedMs = null;
            filtered.Add(e);
        }

        if (filtered.Count == 0)
        {
            filtered.Add((0, 0.5, 0.5));
        }

        (double X, double Y) FilteredPosition(double t)
        {
            var lo = 0;
            var hi = filtered.Count;
            while (lo < hi)
            {
                var mid = (lo + hi) >> 1;
                if (filtered[mid].T <= t)
                {
                    lo = mid + 1;
                }
                else
                {
                    hi = mid;
                }
            }

            if (lo == 0)
            {
                return (filtered[0].X, filtered[0].Y);
            }

            var a = filtered[lo - 1];
            if (lo >= filtered.Count)
            {
                return (a.X, a.Y);
            }

            var b = filtered[lo];
            var f = (t - a.T) / Math.Max(0.000001, b.T - a.T);
            return (a.X + (b.X - a.X) * f, a.Y + (b.Y - a.Y) * f);
        }

        var points = new List<CursorPathPlanner.PathPoint>(filtered.Count + 64);
        var tailStart = loopStartMs ?? stopMoveCutoffMs;
        foreach (var p in filtered)
        {
            if (tailStart is not double tail || p.T < tail)
            {
                points.Add(new CursorPathPlanner.PathPoint(p.T, p.X * pointSize.Width, p.Y * pointSize.Height));
            }
        }

        if (tailStart is double tailFrom)
        {
            // The ending is resampled at 120 Hz: a hold after "stop moving", or a blend toward the start for a loop.
            var t = tailFrom;
            while (t <= durationMs + stepMs)
            {
                var p = endingAdjusted(FilteredPosition(stopMoveCutoffMs is double stop ? Math.Min(t, stop) : t), t);
                points.Add(new CursorPathPlanner.PathPoint(t, p.X * pointSize.Width, p.Y * pointSize.Height));
                t += stepMs;
            }
        }

        // Anchors the cursor must reach on time. Nothing after the ending starts is synchronized.
        var syncEndMs = tailStart ?? durationMs;
        var sync = anchors.Where(anchor => anchor.T <= syncEndMs).Select(anchor => new CursorPathPlanner.SyncPoint(anchor.T, CursorPathPlanner.Tolerance.Click)).ToList();
        heldIndex = 0;
        foreach (var e in events)
        {
            if (e.T > syncEndMs || anchorTimes.Contains(e.T))
            {
                continue;
            }

            while (heldIndex < held.Count && held[heldIndex].End <= e.T)
            {
                heldIndex++;
            }

            if (heldIndex < held.Count && e.T > held[heldIndex].Start)
            {
                sync.Add(new CursorPathPlanner.SyncPoint(e.T, CursorPathPlanner.Tolerance.Drag));
            }
        }

        if (!document.Cursor.AlwaysUsePointer)
        {
            // No hover telemetry is recorded; cursor-shape changes mark where hovered UI reacts.
            var tolerance = document.Cursor.KeepInSyncWithHovers ? CursorPathPlanner.Tolerance.Hover : CursorPathPlanner.Tolerance.CursorImage;
            for (var i = 1; i < events.Count; i++)
            {
                if (events[i].C != events[i - 1].C && events[i].T <= syncEndMs)
                {
                    sync.Add(new CursorPathPlanner.SyncPoint(events[i].T, tolerance));
                }
            }
        }

        return CursorPathPlanner.Plan(points, sync, spring, durationMs);
    }

    private List<CameraFrameState> SolveCamera(
        ProjectDocument document,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        IReadOnlyList<CursorFrameState> cursor,
        SpringConfig camSpring,
        PrecomputedSpring camPrecomputed,
        int totalSteps,
        double dt,
        bool startsAtCut)
    {
        var crop = document.Canvas.CropRect01;
        var active = document.Timeline.IsZoomTrackHidden
            ? []
            : document.Timeline.Zooms.Where(zoom => !zoom.Disabled).OrderBy(zoom => zoom.SourceStartMs).ToList();
        var hasLoupe = active.Any(zoom => zoom.Presentation == ZoomPresentation.Loupe);
        var groups = active.Select(zoom =>
        {
            if (zoom.Mode != ZoomMode.FollowCursor)
            {
                return new List<FocusGroup>();
            }

            var scale = Math.Max(1, zoom.Scale);
            var maxDist = 0.5 / scale;
            // Groups live in recording coordinates; the half-viewport span is measured inside the crop (ADR-86).
            return BuildGroups(zoom, cursorEvents, clickEvents, maxDist * crop.Width, maxDist * crop.Height);
        }).ToList();

        var built = new List<CameraFrameState>(totalSteps);
        var rectX = 0.0;
        var rectY = 0.0;
        var rectW = 1.0;
        var velX = 0.0;
        var velY = 0.0;
        var velW = 0.0;
        var loupeX = 0.5;
        var loupeY = 0.5;
        var loupeScale = 1.0;
        var loupePresence = 0.0;
        var loupeVelX = 0.0;
        var loupeVelY = 0.0;
        var loupeVelScale = 0.0;
        var loupeVelPresence = 0.0;
        var lastLoupe = new LoupeConfig();
        var prev = Point01.Center;
        var loupeSpring = new PrecomputedSpring(new SpringConfig(
            camSpring.Stiffness * 1.5,
            camSpring.Damping * 1.22,
            camSpring.Mass));
        var zoomIndex = 0;

        for (var step = 0; step < totalSteps; step++)
        {
            var tMs = step * stepMs;
            var cursorAt = cursor[step].Position01;
            while (zoomIndex < active.Count && active[zoomIndex].SourceEndMs <= tMs)
            {
                zoomIndex++;
            }

            int? activeIndex = zoomIndex < active.Count && tMs >= active[zoomIndex].SourceStartMs ? zoomIndex : null;
            var targetScale = 1.0;
            var focusX = 0.5;
            var focusY = 0.5;
            var loupeNow = false;
            var targetPresence = 0.0;
            var targetLoupeScale = 1.0;
            var targetLoupeX = loupeX;
            var targetLoupeY = loupeY;
            var loupeCfg = lastLoupe;
            var instant = false;

            if (activeIndex is int zIdx)
            {
                var zoom = active[zIdx];
                // One focus for the screen camera and the Loupe: the active focus group (or the cursor before the first one),
                // or the manual center, moved into crop space before solving (ADR-86).
                var focus = zoom.Mode == ZoomMode.Manual ? zoom.ManualCenter01 : cursorAt;
                foreach (var group in groups[zIdx])
                {
                    if (group.StartTimeMs > tMs)
                    {
                        break;
                    }

                    focus = group.Center01;
                }

                focus = MotionGeometry.Cropped(focus, crop);
                instant = zoom.InstantAnimation;
                loupeNow = zoom.Presentation == ZoomPresentation.Loupe;
                if (loupeNow)
                {
                    loupeCfg = zoom.Loupe;
                    lastLoupe = zoom.Loupe;
                    targetPresence = 1;
                    targetLoupeScale = Math.Max(1, zoom.Scale);
                    var wobbleX = Math.Sin(tMs / 15000.0 * 2 * Math.PI) * 0.008;
                    var wobbleY = Math.Cos(tMs / 18000.0 * 2 * Math.PI) * 0.008;
                    if (zoom.Mode == ZoomMode.FollowCursor)
                    {
                        targetLoupeX = Math.Clamp(focus.X + wobbleX, 0, 1);
                        targetLoupeY = Math.Clamp(focus.Y + wobbleY, 0, 1);
                    }
                    else
                    {
                        targetLoupeX = focus.X;
                        targetLoupeY = focus.Y;
                    }
                }
                else
                {
                    targetScale = Math.Max(1, zoom.Scale);
                    focusX = focus.X;
                    focusY = focus.Y;
                }
            }

            // Warm only invisible glass, including while the preceding screen zoom is active.
            if (hasLoupe && !loupeNow && loupePresence <= 0.005)
            {
                var upcomingIndex = activeIndex is int current ? current + 1 : zoomIndex;
                if (upcomingIndex < active.Count)
                {
                    var upcoming = active[upcomingIndex];
                    if (upcoming.Presentation == ZoomPresentation.Loupe && upcoming.SourceStartMs > tMs && upcoming.SourceStartMs - tMs <= 450)
                    {
                        loupeCfg = upcoming.Loupe;
                        lastLoupe = upcoming.Loupe;
                        var upcomingGroups = groups[upcomingIndex];
                        var warm = MotionGeometry.Cropped(
                            upcoming.Mode == ZoomMode.Manual ? upcoming.ManualCenter01 : upcomingGroups.Count > 0 ? upcomingGroups[0].Center01 : cursorAt,
                            crop);
                        targetLoupeX = warm.X;
                        targetLoupeY = warm.Y;
                    }
                }
            }

            var targetW = targetScale;
            var targetX = 0.5 - focusX * targetScale;
            var targetY = 0.5 - focusY * targetScale;
            if (!loupeNow && document.Motion.AvoidEmptyBoundsWhenZooming && targetScale > 1.0001)
            {
                var minOrigin = 1 - targetScale;
                targetX = Math.Min(0, Math.Max(minOrigin, targetX));
                targetY = Math.Min(0, Math.Max(minOrigin, targetY));
            }

            // A run that begins at a cut starts on its targets: no history from discarded footage (ADR-86).
            if ((instant && !loupeNow) || (step == 0 && startsAtCut))
            {
                rectX = targetX;
                rectY = targetY;
                rectW = targetW;
                velX = velY = velW = 0;
            }
            else
            {
                (rectX, velX) = Step(rectX, velX, targetX, camPrecomputed, dt);
                (rectY, velY) = Step(rectY, velY, targetY, camPrecomputed, dt);
                (rectW, velW) = Step(rectW, velW, targetW, camPrecomputed, dt);
            }

            if (hasLoupe)
            {
                if ((instant && loupeNow) || (step == 0 && startsAtCut))
                {
                    loupeX = targetLoupeX;
                    loupeY = targetLoupeY;
                    loupeScale = targetLoupeScale;
                    loupePresence = targetPresence;
                    loupeVelX = loupeVelY = loupeVelScale = loupeVelPresence = 0;
                }
                else
                {
                    (loupeX, loupeVelX) = Step(loupeX, loupeVelX, targetLoupeX, loupeSpring, dt);
                    (loupeY, loupeVelY) = Step(loupeY, loupeVelY, targetLoupeY, loupeSpring, dt);
                    (loupeScale, loupeVelScale) = Step(loupeScale, loupeVelScale, targetLoupeScale, loupeSpring, dt);
                    (loupePresence, loupeVelPresence) = Step(loupePresence, loupeVelPresence, targetPresence, loupeSpring, dt);
                }
            }

            var visible = loupePresence > 0.005;
            var solvedScale = Math.Max(1, rectW);
            Point01 center;
            {
                // The screen camera keeps its own center while the lens is visible; the lens has LoupeCenter01.
                var cx = (0.5 - rectX) / solvedScale;
                var cy = (0.5 - rectY) / solvedScale;
                if (document.Motion.AvoidEmptyBoundsWhenZooming && solvedScale > 1.0001)
                {
                    var half = 0.5 / solvedScale;
                    cx = Math.Clamp(cx, half, 1 - half);
                    cy = Math.Clamp(cy, half, 1 - half);
                }

                center = new Point01(cx, cy);
            }

            var centerVelX = (center.X - prev.X) / dt;
            var centerVelY = (center.Y - prev.Y) / dt;
            prev = center;
            built.Add(new CameraFrameState
            {
                Center01 = center,
                Scale = solvedScale,
                Velocity01PerSec = new Point01(centerVelX, centerVelY),
                ScaleVelocityPerSec = velW,
                IsLoupeMode = visible,
                LoupePresence01 = Math.Clamp(loupePresence, 0, 1),
                LoupeScale = Math.Max(1, loupeScale),
                LoupeConfig = loupeCfg,
                LoupeCenter01 = new Point01(Math.Clamp(loupeX, 0, 1), Math.Clamp(loupeY, 0, 1))
            });
        }

        return built;
    }

    private static SpringConfig SanitizeCamera(SpringConfig raw)
    {
        var mass = Math.Max(0.1, raw.Mass);
        var stiffness = Math.Max(10, raw.Stiffness);
        var damping = Math.Max(1, raw.Damping);
        var zeta = damping / (2 * Math.Sqrt(stiffness * mass));
        return zeta < 0.80 || damping < 30 ? SpringConfig.DefaultCamera.Copy() : raw;
    }

    private static SpringConfig SanitizeCursor(SpringConfig raw)
    {
        var mass = Math.Max(0.1, raw.Mass);
        var stiffness = Math.Max(10, raw.Stiffness);
        var damping = Math.Max(1, raw.Damping);
        var zeta = damping / (2 * Math.Sqrt(stiffness * mass));
        return zeta < 0.75 || damping < 28 ? SpringConfig.DefaultCursor.Copy() : raw;
    }

    private static (double Value, double Velocity) Step(
        double current,
        double velocity,
        double target,
        PrecomputedSpring spring,
        double dt)
    {
        const double precision = 0.002;
        if (Math.Abs(target - current) < precision && Math.Abs(velocity) < precision)
        {
            return (target, 0);
        }

        var x = current;
        var v = velocity;
        var subDt = dt / 8.0;
        for (var i = 0; i < 8; i++)
        {
            var remaining = target - x;
            var damping = spring.BaseDamping;
            if (v * remaining > 0 && Math.Abs(v) > Math.Abs(remaining) * spring.NaturalFreq)
            {
                damping = Math.Max(spring.BaseDamping, spring.CriticalDamping);
            }

            var accel = (-spring.Stiffness * (x - target) - damping * v) / spring.Mass;
            var nextV = v + accel * subDt;
            var nextX = x + nextV * subDt;
            if ((x - target) * (nextX - target) < 0)
            {
                return (target, 0);
            }

            if (Math.Abs(nextV) < precision && Math.Abs(nextX - target) < precision)
            {
                return (target, 0);
            }

            x = nextX;
            v = nextV;
        }

        return (x, v);
    }

    private static List<FocusGroup> BuildGroups(
        ZoomBlock zoom,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        double maxX,
        double maxY)
    {
        if (cursorEvents.Count == 0)
        {
            return [];
        }

        var samples = new List<(double T, double X, double Y)>();
        const double minStep = 0.006;
        var lo = 0;
        var hi = cursorEvents.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) >> 1;
            if (cursorEvents[mid].T < zoom.SourceStartMs)
            {
                lo = mid + 1;
            }
            else
            {
                hi = mid;
            }
        }

        var startIndex = lo > 0 ? lo - 1 : 0;
        var start = cursorEvents[startIndex];
        samples.Add((zoom.SourceStartMs, start.X, start.Y));
        for (var i = lo; i < cursorEvents.Count; i++)
        {
            var ev = cursorEvents[i];
            if (ev.T > zoom.SourceEndMs)
            {
                break;
            }

            var last = samples[^1];
            if (Math.Sqrt((ev.X - last.X) * (ev.X - last.X) + (ev.Y - last.Y) * (ev.Y - last.Y)) >= minStep)
            {
                samples.Add((ev.T, ev.X, ev.Y));
            }
        }

        var addedClicks = false;
        foreach (var click in clickEvents)
        {
            if (click.Type == "down" && click.T >= zoom.SourceStartMs && click.T <= zoom.SourceEndMs)
            {
                samples.Add((click.T, click.X, click.Y));
                addedClicks = true;
            }
        }

        if (addedClicks)
        {
            samples.Sort((a, b) => a.T.CompareTo(b.T));
        }

        if (samples.Count == 0)
        {
            return [];
        }

        var resolved = new List<FocusGroup>();
        var group = new MovesGroup(maxX, maxY);
        foreach (var sample in samples)
        {
            if (group.CanAdd(sample.X, sample.Y))
            {
                group.Add(sample.T, sample.X, sample.Y);
            }
            else
            {
                group.FinishedTimeMs = sample.T;
                resolved.Add(new FocusGroup(group.StartTimeMs, group.TimeWeightedCenter()));
                group = new MovesGroup(maxX, maxY);
                group.Add(sample.T, sample.X, sample.Y);
            }
        }

        group.FinishedTimeMs = zoom.SourceEndMs;
        resolved.Add(new FocusGroup(group.StartTimeMs, group.TimeWeightedCenter()));
        return resolved;
    }
}
