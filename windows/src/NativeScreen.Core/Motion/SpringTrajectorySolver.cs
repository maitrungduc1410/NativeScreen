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

    public SpringTrajectorySolver(
        double durationMs,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        ProjectDocument document)
    {
        HasRecordedCursor = cursorEvents.Count > 0;
        var totalDuration = Math.Max(100, durationMs);
        var totalSteps = Math.Max(2, (int)Math.Ceiling(totalDuration / stepMs) + 1);
        var dt = stepMs / 1000.0;
        var cursorSpring = SanitizeCursor(document.Cursor.Spring);
        var camSpring = SanitizeCamera(document.Motion.CameraSpring);
        var camPrecomputed = new PrecomputedSpring(camSpring);

        var cursor = SolveCursor(document, cursorEvents, clickEvents, cursorSpring, totalDuration, totalSteps, dt);
        CursorStates = cursor;
        CameraStates = SolveCamera(document, cursorEvents, clickEvents, cursor, camSpring, camPrecomputed, totalDuration, totalSteps, dt);
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
            LoupeConfig = a0.LoupeConfig
        };
        return (cursor, camera);
    }

    private List<CursorFrameState> SolveCursor(
        ProjectDocument document,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        SpringConfig cursorSpring,
        double totalDuration,
        int totalSteps,
        double dt)
    {
        var solved = new List<CursorFrameState>(totalSteps);
        var firstEventTime = cursorEvents.Count == 0 ? 0 : cursorEvents[0].T;
        var legacyOffset = firstEventTime > 60 && firstEventTime < 900 ? firstEventTime : 0;
        var first = cursorEvents.Count == 0 ? Point01.Center : new Point01(cursorEvents[0].X, cursorEvents[0].Y);
        var drags = BuildDragIntervals(clickEvents, legacyOffset, totalDuration).OrderBy(drag => drag.Start).ToList();
        var clicks = clickEvents.Select(click => Math.Max(0, click.T - legacyOffset)).OrderBy(t => t).ToList();
        var downs = clickEvents.Where(click => click.Type == "down").Select(click => Math.Max(0, click.T - legacyOffset)).OrderBy(t => t).ToList();
        var dragWindow = 0;
        var clickWindow = 0;
        var rippleWindow = 0;
        var baseLag = document.Cursor.SmoothMovementEnabled
            ? Math.Min(240, Math.Max(0, cursorSpring.Damping / Math.Max(10, cursorSpring.Stiffness) * 1000))
            : 0;
        var lead = baseLag * (document.Cursor.KeepInSyncWithHovers ? 1 : 0.72);
        var baseSpring = new PrecomputedSpring(cursorSpring);
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
        var shake = Math.Max(0, document.Cursor.RemoveShakeThresholdPx) / 1600.0;
        double? stopCutoff = document.Cursor.LoopBackToStartMs is null && document.Cursor.StopMovementInLastPartMs > 0
            ? Math.Max(0, totalDuration - document.Cursor.StopMovementInLastPartMs)
            : null;
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

            var shifted = queryMs + legacyOffset;
            if (shifted <= cursorEvents[0].T)
            {
                return (cursorEvents[0].X, cursorEvents[0].Y, cursorEvents[0].C);
            }

            if (shifted >= cursorEvents[^1].T)
            {
                var last = cursorEvents[^1];
                return (last.X, last.Y, last.C);
            }

            var lo = 0;
            var hi = cursorEvents.Count - 1;
            while (hi - lo > 1)
            {
                var mid = (lo + hi) >> 1;
                if (cursorEvents[mid].T <= shifted)
                {
                    lo = mid;
                }
                else
                {
                    hi = mid;
                }
            }

            var e0 = cursorEvents[lo];
            var e1 = cursorEvents[lo + 1];
            var span = Math.Max(0.001, e1.T - e0.T);
            if (span > 48)
            {
                var moveStart = e1.T - 16;
                if (shifted <= moveStart)
                {
                    return (e0.X, e0.Y, e0.C);
                }

                var moveFrac = Math.Clamp((shifted - moveStart) / Math.Max(1, e1.T - moveStart), 0, 1);
                return (e0.X + (e1.X - e0.X) * moveFrac, e0.Y + (e1.Y - e0.Y) * moveFrac, e0.C);
            }

            var frac = Math.Clamp((shifted - e0.T) / span, 0, 1);
            return (e0.X + (e1.X - e0.X) * frac, e0.Y + (e1.Y - e0.Y) * frac, e0.C);
        }

        for (var step = 0; step < totalSteps; step++)
        {
            var tMs = step * stepMs;
            var baseLookup = stopCutoff is double cutoff ? Math.Min(tMs, cutoff) : tMs;
            var sync = 1.0;
            while (dragWindow < drags.Count && drags[dragWindow].End + 260 < tMs)
            {
                dragWindow++;
            }

            for (var i = dragWindow; i < drags.Count; i++)
            {
                var drag = drags[i];
                if (drag.Start - 220 > tMs)
                {
                    break;
                }

                if (tMs >= drag.Start - 220 && tMs <= drag.End + 260)
                {
                    if (tMs < drag.Start)
                    {
                        var ramp = (tMs - (drag.Start - 220)) / 220;
                        sync = Math.Max(sync, 1 + 3.2 * Math.Clamp(ramp, 0, 1));
                    }
                    else if (tMs <= drag.End)
                    {
                        sync = Math.Max(sync, 4.2);
                    }
                    else
                    {
                        var rampOut = 1 - (tMs - drag.End) / 260;
                        sync = Math.Max(sync, 1 + 3.2 * Math.Clamp(rampOut, 0, 1));
                    }
                }
            }

            while (clickWindow < clicks.Count && clicks[clickWindow] < tMs - 180)
            {
                clickWindow++;
            }

            for (var i = clickWindow; i < clicks.Count; i++)
            {
                var clickT = clicks[i];
                if (clickT > tMs + 180)
                {
                    break;
                }

                var delta = Math.Abs(tMs - clickT);
                if (delta <= 180)
                {
                    sync = Math.Max(sync, 1 + 2.4 * (1 - delta / 180));
                }
            }

            var currentLead = lead / sync;
            var lookahead = Math.Min(totalDuration, stopCutoff is double stop ? Math.Min(tMs + currentLead, stop) : tMs + currentLead);
            var sampledTarget = Sample(lookahead);
            var sampledNow = Sample(baseLookup);
            var rawX = sampledTarget.X;
            var rawY = sampledTarget.Y;
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

            if (document.Cursor.LoopBackToStartMs is double loopMs && loopMs > 0 && tMs > totalDuration - loopMs)
            {
                var factor = Math.Clamp((tMs - (totalDuration - loopMs)) / loopMs, 0, 1);
                rawX += (first.X - rawX) * factor;
                rawY += (first.Y - rawY) * factor;
            }

            var dist = Math.Sqrt((rawX - filteredX) * (rawX - filteredX) + (rawY - filteredY) * (rawY - filteredY));
            var shakeNow = sync > 1.5 ? 0 : shake;
            if (dist > shakeNow)
            {
                filteredX = rawX;
                filteredY = rawY;
                lastMove = tMs;
            }

            if (document.Cursor.SmoothMovementEnabled)
            {
                var spring = Math.Abs(sync - 1) < 0.001
                    ? baseSpring
                    : new PrecomputedSpring(new SpringConfig(
                        cursorSpring.Stiffness * sync * sync,
                        cursorSpring.Damping * sync,
                        cursorSpring.Mass));
                (curX, velX) = Step(curX, velX, filteredX, spring, dt);
                (curY, velY) = Step(curY, velY, filteredY, spring, dt);
            }
            else
            {
                velX = (filteredX - curX) / dt;
                velY = (filteredY - curY) / dt;
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
                    dynamic = Math.Clamp(-velX * 0.14 * document.Cursor.VelocityRotationIntensity, -0.35, 0.35);
                }
                else
                {
                    var speed = Math.Sqrt(velX * velX + velY * velY);
                    if (speed > 0.04)
                    {
                        var targetAngle = Math.Atan2(-velY, velX) - Math.PI * 0.75;
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
                clickWaves.Add(new ClickWave(tMs - downs[nextWaveClick], new Point01(curX, curY)));
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

        return solved;
    }

    private List<CameraFrameState> SolveCamera(
        ProjectDocument document,
        IReadOnlyList<CursorSampleEvent> cursorEvents,
        IReadOnlyList<ClickEvent> clickEvents,
        List<CursorFrameState> cursor,
        SpringConfig camSpring,
        PrecomputedSpring camPrecomputed,
        double totalDuration,
        int totalSteps,
        double dt)
    {
        _ = totalDuration;
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
            return BuildGroups(zoom, cursorEvents, clickEvents, maxDist, maxDist);
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
            while (zoomIndex < active.Count && active[zoomIndex].SourceEndMs < tMs)
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
                        targetLoupeX = Math.Clamp(cursorAt.X + wobbleX, 0, 1);
                        targetLoupeY = Math.Clamp(cursorAt.Y + wobbleY, 0, 1);
                    }
                    else
                    {
                        targetLoupeX = zoom.ManualCenter01.X;
                        targetLoupeY = zoom.ManualCenter01.Y;
                    }
                }
                else
                {
                    targetScale = Math.Max(1, zoom.Scale);
                    if (zoom.Mode == ZoomMode.FollowCursor)
                    {
                        var focusGroups = groups[zIdx];
                        if (focusGroups.Count > 0)
                        {
                            var focusCenter = focusGroups[0].Center01;
                            foreach (var group in focusGroups)
                            {
                                if (group.StartTimeMs <= tMs)
                                {
                                    focusCenter = group.Center01;
                                }
                                else
                                {
                                    break;
                                }
                            }

                            focusX = focusCenter.X;
                            focusY = focusCenter.Y;
                        }
                        else
                        {
                            focusX = cursorAt.X;
                            focusY = cursorAt.Y;
                        }
                    }
                    else
                    {
                        focusX = zoom.ManualCenter01.X;
                        focusY = zoom.ManualCenter01.Y;
                    }
                }
            }
            else if (hasLoupe && zoomIndex < active.Count)
            {
                var upcoming = active[zoomIndex];
                if (upcoming.Presentation == ZoomPresentation.Loupe && upcoming.SourceStartMs > tMs && upcoming.SourceStartMs - tMs <= 450)
                {
                    loupeCfg = upcoming.Loupe;
                    lastLoupe = upcoming.Loupe;
                    targetLoupeX = upcoming.Mode == ZoomMode.Manual ? upcoming.ManualCenter01.X : cursorAt.X;
                    targetLoupeY = upcoming.Mode == ZoomMode.Manual ? upcoming.ManualCenter01.Y : cursorAt.Y;
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

            if (instant && !loupeNow)
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
                if (instant && loupeNow)
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
            if (visible)
            {
                center = new Point01(Math.Clamp(loupeX, 0, 1), Math.Clamp(loupeY, 0, 1));
            }
            else
            {
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
                LoupeConfig = loupeCfg
            });
        }

        return built;
    }

    private static List<(double Start, double End)> BuildDragIntervals(
        IReadOnlyList<ClickEvent> clicks,
        double offset,
        double duration)
    {
        var intervals = new List<(double Start, double End)>();
        double? down = null;
        foreach (var ev in clicks.OrderBy(click => click.T))
        {
            var t = Math.Max(0, ev.T - offset);
            if (ev.Type == "down")
            {
                down ??= t;
            }
            else if (ev.Type == "up" && down is double start)
            {
                if (t > start + 25)
                {
                    intervals.Add((start, t));
                }

                down = null;
            }
        }

        if (down is double unclosed && duration > unclosed + 25)
        {
            intervals.Add((unclosed, duration));
        }

        return intervals;
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
