using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

/// <summary>
/// Moments where moving the mouse made something under it change, as hovering does: a menu item or button taking a
/// highlight (spec/06 ADR-108, spec/03 §2.5). The cursor is not in the video, so these are read from the footage around the
/// recorded cursor. The planner must have the drawn cursor where the recorded one was at each of them, or the highlight
/// shows before the cursor gets there. Scanned once per recording and kept in <c>assets/hover-changes.json</c>.
/// Port of the macOS <c>HoverChangeDetector</c>: same constants, same order of tests.
/// </summary>
public static class HoverChangeDetector
{
    public const int CurrentVersion = 2;

    public sealed class Stored
    {
        [JsonPropertyName("version")]
        public int Version { get; set; } = CurrentVersion;

        [JsonPropertyName("videoDurationMs")]
        public double VideoDurationMs { get; set; }

        /// <summary>Recording (source) time of each change, ascending.</summary>
        [JsonPropertyName("changeTimesMs")]
        public List<double> ChangeTimesMs { get; set; } = [];
    }

    public sealed record Settings
    {
        /// <summary>Half-size of the square compared around the cursor.</summary>
        public double ProbeRadiusPt { get; init; } = 8;

        /// <summary>The frame compared against is this much older, and two changes are at least this far apart.</summary>
        public double ReferenceLagMs { get; init; } = 120;

        /// <summary>The area must have been still for this long before the reference frame.</summary>
        public double SettledForMs { get; init; } = 150;

        /// <summary>|dY| + |dCb| + |dCr| at or above this counts as a changed pixel.</summary>
        public int PixelChangeThreshold { get; init; } = 10;

        public double CoherenceTolerance01 { get; init; } = 0.35;
        public int MinimumCoherenceTolerance { get; init; } = 6;
        public double MinimumChangedFraction { get; init; } = 0.4;
        public double MinimumCoherentFraction { get; init; } = 0.3;
        public int MinimumSurroundingQuarters { get; init; } = 3;
        public double MinimumQuarterCoherentFraction { get; init; } = 0.15;
        public double MaximumSettledChangedFraction { get; init; } = 0.08;
        public double ScrollProbeRadiusPt { get; init; } = 24;
        public double MaximumScrollPt { get; init; } = 32;
        public double ScrollExplainedResidual01 { get; init; } = 0.5;

        /// <summary>The mouse must have moved this far, without a button held, within <see cref="MovementWindowMs"/>.</summary>
        public double MinimumMovementPt { get; init; } = 3;

        public double MovementWindowMs { get; init; } = 150;

        /// <summary>A change this close to a click is the click's effect, not a hover.</summary>
        public double ClickExclusionBeforeMs { get; init; } = 300;

        public double ClickExclusionAfterMs { get; init; } = 80;

        /// <summary>Mouse movements closer than this are read as one stretch of video.</summary>
        public double JoinGapMs { get; init; } = 1000;

        /// <summary>Scrolling is only considered with a scroll event this long before the reference frame or later.</summary>
        public double ScrollEventWindowMs { get; init; } = 300;

        public static Settings Standard { get; } = new();
    }

    /// <summary>One decoded NV12 frame, tightly packed (luma rows of <c>Width</c>, then interleaved CbCr).</summary>
    public readonly record struct Nv12Frame(byte[] Nv12, int Width, int Height, double TimeMs);

    /// <summary>
    /// Frames this long before a movement are copied out of the decoder too, for the frame on screen when the movement
    /// starts. A Windows recording has a frame at least every 250 ms; the rest is margin for other recordings.
    /// </summary>
    private const double WaitingFrameMarginMs = 1000;

    private const int ProgressEveryFrames = 15;

    /// <summary>
    /// One pass over the video's frames in order. <paramref name="read"/> is given the times whose pixels are needed (near a
    /// mouse movement) and yields every frame, with no pixels for the others. <paramref name="release"/> gets each buffer back
    /// once it is no longer needed, so the reader can reuse it. <paramref name="progress"/> gets the fraction done and returns
    /// false to stop. Returns null when stopped. Cursor and clicks are on the video clock, normalized like the telemetry files.
    /// </summary>
    public static Stored? Scan(
        Func<Func<double, bool>, IEnumerable<Nv12Frame>> read,
        Action<byte[]> release,
        double durationMs,
        IReadOnlyList<CursorSampleEvent> cursor,
        IReadOnlyList<ClickEvent> clicks,
        MotionPointSize pointSize,
        Func<double, bool> progress,
        Settings? settings = null)
    {
        var s = settings ?? Settings.Standard;
        var path = new CursorPath(cursor, clicks, pointSize);
        var spans = path.MovementSpans(s.JoinGapMs, s.MovementWindowMs);
        var totalMs = Math.Max(1, spans.Sum(span => span.End - span.Start));
        // Screen recordings only have a frame when the picture changed, so the frame shown at a moment can be much older
        // than the moment: the last frame before each span is kept for it.
        var historyMs = s.ReferenceLagMs + s.SettledForMs;
        var detector = new Detector(path, s);
        var changes = new List<double>();
        var spanIndex = 0;
        var doneMs = 0.0;
        var framesInSpan = 0;
        Nv12Frame? waiting = null;
        var wantedSpan = 0;
        bool Wanted(double time)
        {
            while (wantedSpan < spans.Count && time > spans[wantedSpan].End)
            {
                wantedSpan++;
            }

            return wantedSpan < spans.Count && time >= spans[wantedSpan].Start - historyMs - 50 - WaitingFrameMarginMs;
        }

        foreach (var raw in read(Wanted))
        {
            var t = raw.TimeMs;
            while (spanIndex < spans.Count && t > spans[spanIndex].End)
            {
                doneMs += spans[spanIndex].End - spans[spanIndex].Start;
                spanIndex++;
                if (!progress(Math.Min(1, doneMs / totalMs)))
                {
                    Release(waiting);
                    release(raw.Nv12);
                    return null;
                }
            }

            if (spanIndex >= spans.Count)
            {
                release(raw.Nv12);
                break;
            }

            // Not near a movement: decoded but not copied out.
            if (raw.Nv12.Length == 0)
            {
                continue;
            }

            var span = spans[spanIndex];
            // Within a long movement too, so a progress bar does not sit at 0 for the whole of a single span.
            if (t > span.Start && ++framesInSpan % ProgressEveryFrames == 0 && !progress(Math.Min(1, (doneMs + t - span.Start) / totalMs)))
            {
                Release(waiting);
                release(raw.Nv12);
                return null;
            }

            if (t < span.Start - historyMs - 50)
            {
                Release(waiting);
                waiting = raw;
                continue;
            }

            if (waiting is { } earlier)
            {
                waiting = null;
                detector.Remember(Frame.FromNv12(earlier.Nv12, earlier.Width, earlier.Height, earlier.TimeMs, pointSize));
                release(earlier.Nv12);
            }

            var frame = Frame.FromNv12(raw.Nv12, raw.Width, raw.Height, t, pointSize);
            release(raw.Nv12);
            if (t >= span.Start)
            {
                if (detector.Add(frame) is double change)
                {
                    changes.Add(change);
                }
            }
            else
            {
                detector.Remember(frame);
            }
        }

        Release(waiting);
        changes.Sort();
        return new Stored
        {
            VideoDurationMs = Math.Max(1, durationMs),
            ChangeTimesMs = [.. changes.Select(change => Round(change * 10) / 10)]
        };

        void Release(Nv12Frame? frame)
        {
            if (frame is { } held)
            {
                release(held.Nv12);
            }
        }
    }

    /// <summary>Swift's <c>rounded()</c>: halves away from zero.</summary>
    internal static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    // MARK: Recorded cursor

    public sealed class CursorPath
    {
        /// <summary>Points.</summary>
        private readonly double[] ts;
        private readonly double[] xs;
        private readonly double[] ys;

        /// <summary>Whether each sample moved the cursor with no button held.</summary>
        private readonly bool[] isFreeMove;

        /// <summary>Person's clicks (down and up), ascending.</summary>
        private readonly double[] clickTimes;

        /// <summary>Scroll wheel events, ascending.</summary>
        private readonly double[] scrollTimes;

        public CursorPath(IReadOnlyList<CursorSampleEvent> cursor, IReadOnlyList<ClickEvent> clicks, MotionPointSize pointSize)
        {
            var sorted = cursor.OrderBy(e => e.T).ToArray();
            ts = [.. sorted.Select(e => e.T)];
            xs = [.. sorted.Select(e => e.X * pointSize.Width)];
            ys = [.. sorted.Select(e => e.Y * pointSize.Height)];
            var held = CursorTelemetry.HeldIntervals(clicks, sorted.Length > 0 ? sorted[^1].T : 0);
            isFreeMove = new bool[sorted.Length];
            var h = 0;
            for (var i = 1; i < sorted.Length; i++)
            {
                var t = sorted[i].T;
                while (h < held.Count && held[h].End < t)
                {
                    h++;
                }

                var isHeld = h < held.Count && t >= held[h].Start;
                isFreeMove[i] = !isHeld && (sorted[i].X != sorted[i - 1].X || sorted[i].Y != sorted[i - 1].Y);
            }

            clickTimes = [.. clicks.Where(c => c.Type is "down" or "up").Select(c => c.T).Order()];
            scrollTimes = [.. clicks.Where(c => c.Type == "scroll").Select(c => c.T).Order()];
        }

        /// <summary>Index of the last sample at or before <paramref name="t"/>, or -1.</summary>
        public int IndexAtOrBefore(double t)
        {
            int lo = 0, hi = ts.Length;
            while (lo < hi)
            {
                var mid = (lo + hi) >> 1;
                if (ts[mid] <= t)
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

        public (double X, double Y)? Position(double t)
        {
            if (ts.Length == 0)
            {
                return null;
            }

            var i = IndexAtOrBefore(t);
            if (i < 0)
            {
                return (xs[0], ys[0]);
            }

            if (i + 1 >= ts.Length || !(ts[i + 1] > ts[i]))
            {
                return (xs[i], ys[i]);
            }

            var f = (t - ts[i]) / (ts[i + 1] - ts[i]);
            return (xs[i] + (xs[i + 1] - xs[i]) * f, ys[i] + (ys[i + 1] - ys[i]) * f);
        }

        /// <summary>How far the cursor moved with no button held in <c>(t - windowMs, t]</c>.</summary>
        public double FreeMovementPt(double t, double windowMs)
        {
            var i = IndexAtOrBefore(t);
            var sum = 0.0;
            while (i > 0 && ts[i] > t - windowMs)
            {
                if (isFreeMove[i])
                {
                    sum += Math.Sqrt((xs[i] - xs[i - 1]) * (xs[i] - xs[i - 1]) + (ys[i] - ys[i - 1]) * (ys[i] - ys[i - 1]));
                }

                i--;
            }

            return sum;
        }

        /// <summary>Stretches with free movement, joined across short gaps and extended by <paramref name="tailMs"/>.</summary>
        public List<(double Start, double End)> MovementSpans(double joinGapMs, double tailMs)
        {
            var spans = new List<(double Start, double End)>();
            for (var i = 0; i < ts.Length; i++)
            {
                if (!isFreeMove[i])
                {
                    continue;
                }

                var t = ts[i];
                if (spans.Count > 0 && t - spans[^1].End <= joinGapMs)
                {
                    spans[^1] = (spans[^1].Start, Math.Max(spans[^1].End, t + tailMs));
                }
                else
                {
                    spans.Add((t, t + tailMs));
                }
            }

            return spans;
        }

        public bool HasClick(double from, double to) => Contains(clickTimes, from, to);

        public bool HasScroll(double from, double to) => Contains(scrollTimes, from, to);

        private static bool Contains(double[] times, double from, double to)
        {
            int lo = 0, hi = times.Length;
            while (lo < hi)
            {
                var mid = (lo + hi) >> 1;
                if (times[mid] < from)
                {
                    lo = mid + 1;
                }
                else
                {
                    hi = mid;
                }
            }

            return lo < times.Length && times[lo] <= to;
        }
    }

    // MARK: Frames

    /// <summary>A video frame at one pixel per point, video-range Y and interleaved CbCr.</summary>
    public sealed class Frame
    {
        public double TimeMs { get; }
        public int Width { get; }
        public int Height { get; }
        public byte[] Luma { get; }
        public byte[] CbCr { get; }

        private Frame(double timeMs, int width, int height, byte[] luma, byte[] cbcr)
        {
            TimeMs = timeMs;
            Width = width;
            Height = height;
            Luma = luma;
            CbCr = cbcr;
        }

        /// <summary>
        /// Resamples a packed NV12 frame to one pixel per point with a box average. It does not need to match the macOS
        /// resampler exactly (spec/06 ADR-108): the first macOS version used a box average too.
        /// </summary>
        public static Frame FromNv12(byte[] nv12, int pixelWidth, int pixelHeight, double timeMs, MotionPointSize pointSize)
        {
            var w = Math.Max(1, (int)Round(pointSize.Width));
            var h = Math.Max(1, (int)Round(pointSize.Height));
            var luma = new byte[w * h];
            var cbcr = new byte[w * h * 2];
            BoxAverage(nv12, 0, pixelWidth, pixelWidth, pixelHeight, 1, luma, w, h);
            BoxAverage(nv12, pixelWidth * pixelHeight, pixelWidth, pixelWidth / 2, pixelHeight / 2, 2, cbcr, w, h);
            return new Frame(timeMs, w, h, luma, cbcr);
        }

        /// <summary>For tests: a frame already at one pixel per point.</summary>
        public static Frame FromPlanes(double timeMs, int width, int height, byte[] luma, byte[] cbcr) => new(timeMs, width, height, luma, cbcr);

        public int Index(int x, int y) => Math.Min(Height - 1, Math.Max(0, y)) * Width + Math.Min(Width - 1, Math.Max(0, x));

        // Every frame of a mouse movement goes through here, at the recording's full size (a 4K frame is 12 MB): the source
        // spans of each column and row are worked out once, and rows are split over a few cores.
        private static void BoxAverage(byte[] source, int offset, int stride, int sourceWidth, int sourceHeight, int channels, byte[] target, int width, int height)
        {
            if (sourceWidth <= 0 || sourceHeight <= 0)
            {
                return;
            }

            var columns = Spans(sourceWidth, width);
            var rows = Spans(sourceHeight, height);
            var parts = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);
            var band = (height + parts - 1) / parts;
            Parallel.For(0, parts, part =>
            {
                // Every index is inside the planes (the spans stay within the source size), so no bounds checks.
                ref var from = ref MemoryMarshal.GetArrayDataReference(source);
                ref var to = ref MemoryMarshal.GetArrayDataReference(target);
                for (var y = part * band; y < Math.Min(height, (part + 1) * band); y++)
                {
                    var (y0, rowCount) = rows[y];
                    var outputRow = y * width * channels;
                    for (var x = 0; x < width; x++)
                    {
                        var (x0, columnCount) = columns[x];
                        var count = rowCount * columnCount;
                        for (var c = 0; c < channels; c++)
                        {
                            var sum = 0;
                            var index = offset + y0 * stride + x0 * channels + c;
                            for (var yy = 0; yy < rowCount; yy++, index += stride)
                            {
                                for (var xx = 0; xx < columnCount; xx++)
                                {
                                    sum += Unsafe.Add(ref from, index + xx * channels);
                                }
                            }

                            // A division per pixel was most of the time; 1, 2 and 4 pixels (scales up to 2) are shifts.
                            Unsafe.Add(ref to, outputRow + x * channels + c) = count switch
                            {
                                1 => (byte)sum,
                                2 => (byte)((sum + 1) >> 1),
                                4 => (byte)((sum + 2) >> 2),
                                _ => (byte)((sum + count / 2) / count)
                            };
                        }
                    }
                }
            });
        }

        /// <summary>The first source index and how many are averaged, for each of <paramref name="count"/> targets.</summary>
        private static (int Start, int Count)[] Spans(int sourceCount, int count)
        {
            var scale = (double)sourceCount / count;
            var spans = new (int Start, int Count)[count];
            for (var i = 0; i < count; i++)
            {
                var start = Math.Min(sourceCount - 1, (int)(i * scale));
                var end = Math.Min(sourceCount, Math.Max(start + 1, (int)((i + 1) * scale)));
                spans[i] = (start, end - start);
            }

            return spans;
        }
    }

    // MARK: Detection

    public readonly record struct ProbeComparison(double[] QuarterCoherentFractions, double[] QuarterChangedFractions, double ChangedFraction, double CoherentFraction);

    public sealed class Detector(CursorPath path, Settings settings)
    {
        private readonly List<Frame> history = [];
        private readonly List<int> dYs = [];
        private readonly List<int> dCbs = [];
        private readonly List<int> dCrs = [];
        private readonly List<int> quarters = [];

        /// <summary>The frame of the last change found, while frames still compare against a reference from before it.</summary>
        private Frame? lastChange;

        public Detector(CursorPath path) : this(path, Settings.Standard)
        {
        }

        public void Remember(Frame frame)
        {
            history.Add(frame);
            // A video only has a frame when the picture changed, so the reference (the frame on screen 120 ms ago) and the
            // settled frame (on screen 150 ms before the reference) can be much older. Keep both.
            if (Last(frame.TimeMs - settings.ReferenceLagMs) is not { } reference)
            {
                return;
            }

            var keep = LastIndex(reference.TimeMs - settings.SettledForMs);
            if (keep > 0)
            {
                history.RemoveRange(0, keep);
            }
        }

        /// <summary>Adds a frame and returns its time if a hover change shows in it.</summary>
        public double? Add(Frame frame)
        {
            try
            {
                if (Change(frame) is not double change)
                {
                    return null;
                }

                // Until the reference passes the last change, the same highlight still differs from it. It is a new change
                // only if the square changed again since (sweeping down a menu lights a new item every 60 to 100 ms).
                if (lastChange is { } last && frame.TimeMs - last.TimeMs < settings.ReferenceLagMs)
                {
                    var cursor = path.Position(frame.TimeMs) ?? (0, 0);
                    if (Compare(last, frame, (int)Round(cursor.X), (int)Round(cursor.Y)) is not { } since
                        || since.ChangedFraction < settings.MinimumChangedFraction)
                    {
                        return null;
                    }
                }

                lastChange = frame;
                return change;
            }
            finally
            {
                Remember(frame);
            }
        }

        public double? Change(Frame frame)
        {
            var s = settings;
            var t = frame.TimeMs;
            if (path.FreeMovementPt(t, s.MovementWindowMs) < s.MinimumMovementPt
                || path.HasClick(t - s.ClickExclusionBeforeMs, t + s.ClickExclusionAfterMs)
                || path.Position(t) is not { } cursor
                || Last(t - s.ReferenceLagMs) is not { } reference
                || Last(reference.TimeMs - s.SettledForMs) is not { } settled)
            {
                return null;
            }

            var cx = (int)Round(cursor.X);
            var cy = (int)Round(cursor.Y);
            if (Compare(reference, frame, cx, cy) is not { } probe)
            {
                return null;
            }

            var surrounding = 0;
            foreach (var fraction in probe.QuarterCoherentFractions)
            {
                if (fraction >= s.MinimumQuarterCoherentFraction)
                {
                    surrounding++;
                }
            }

            if (probe.ChangedFraction < s.MinimumChangedFraction || probe.CoherentFraction < s.MinimumCoherentFraction || surrounding < s.MinimumSurroundingQuarters)
            {
                return null;
            }

            // Still before: measured where the new change is (quarters at least half coherent), so the previous menu item
            // turning on above or below the cursor does not count against the next one.
            if (settled.TimeMs != reference.TimeMs && Compare(settled, reference, cx, cy) is { } before)
            {
                var moved = -1.0;
                for (var q = 0; q < 4; q++)
                {
                    if (probe.QuarterCoherentFractions[q] >= 0.5)
                    {
                        moved = Math.Max(moved, before.QuarterChangedFractions[q]);
                    }
                }

                if (moved < 0)
                {
                    moved = before.ChangedFraction;
                }

                if (moved > s.MaximumSettledChangedFraction)
                {
                    return null;
                }
            }

            // A highlight stepping down one menu row looks like content shifted by a row, so the shift test only runs when
            // the wheel was actually scrolled.
            if (path.HasScroll(reference.TimeMs - s.ScrollEventWindowMs, t) && IsExplainedByScrolling(reference, frame, cx, cy))
            {
                return null;
            }

            return t;
        }

        /// <summary>
        /// How the square around the cursor changed from <paramref name="a"/> to <paramref name="b"/>. A highlight changes most
        /// of it, all in the same way (close to the median change), on at least three sides of the cursor.
        /// </summary>
        public ProbeComparison? Compare(Frame a, Frame b, int cx, int cy)
        {
            var s = settings;
            var r = Math.Max(2, (int)Round(s.ProbeRadiusPt));
            var xa = Math.Max(0, cx - r);
            var xb = Math.Min(b.Width - 1, cx + r);
            var ya = Math.Max(0, cy - r);
            var yb = Math.Min(b.Height - 1, cy + r);
            if (xb < xa || yb < ya)
            {
                return null;
            }

            var total = (xb - xa + 1) * (yb - ya + 1);
            Span<int> quarterTotal = stackalloc int[4];
            dYs.Clear();
            dCbs.Clear();
            dCrs.Clear();
            quarters.Clear();
            for (var y = ya; y <= yb; y++)
            {
                for (var x = xa; x <= xb; x++)
                {
                    var q = (y < cy ? 0 : 2) + (x >= cx ? 1 : 0);
                    quarterTotal[q]++;
                    var i = a.Index(x, y);
                    var j = b.Index(x, y);
                    var dY = b.Luma[j] - a.Luma[i];
                    var dCb = b.CbCr[2 * j] - a.CbCr[2 * i];
                    var dCr = b.CbCr[2 * j + 1] - a.CbCr[2 * i + 1];
                    if (Math.Abs(dY) + Math.Abs(dCb) + Math.Abs(dCr) >= s.PixelChangeThreshold)
                    {
                        dYs.Add(dY);
                        dCbs.Add(dCb);
                        dCrs.Add(dCr);
                        quarters.Add(q);
                    }
                }
            }

            if (dYs.Count == 0)
            {
                return new ProbeComparison([0, 0, 0, 0], [0, 0, 0, 0], 0, 0);
            }

            var mY = Median(dYs);
            var mCb = Median(dCbs);
            var mCr = Median(dCrs);
            var tolerance = Math.Max(s.MinimumCoherenceTolerance, (int)Round(s.CoherenceTolerance01 * (Math.Abs(mY) + Math.Abs(mCb) + Math.Abs(mCr))));
            var coherent = 0;
            Span<int> quarterCoherent = stackalloc int[4];
            Span<int> quarterChanged = stackalloc int[4];
            for (var k = 0; k < dYs.Count; k++)
            {
                quarterChanged[quarters[k]]++;
                if (Math.Abs(dYs[k] - mY) + Math.Abs(dCbs[k] - mCb) + Math.Abs(dCrs[k] - mCr) <= tolerance)
                {
                    coherent++;
                    quarterCoherent[quarters[k]]++;
                }
            }

            var coherentFractions = new double[4];
            var changedFractions = new double[4];
            for (var q = 0; q < 4; q++)
            {
                coherentFractions[q] = quarterTotal[q] > 0 ? (double)quarterCoherent[q] / quarterTotal[q] : 0;
                changedFractions[q] = quarterTotal[q] > 0 ? (double)quarterChanged[q] / quarterTotal[q] : 0;
            }

            return new ProbeComparison(coherentFractions, changedFractions, (double)dYs.Count / total, (double)coherent / total);
        }

        /// <summary>
        /// Whether shifting <paramref name="a"/> up, down, left or right by up to <c>MaximumScrollPt</c> explains most of the
        /// difference: content moving under a still cursor, not a highlight.
        /// </summary>
        public bool IsExplainedByScrolling(Frame a, Frame b, int cx, int cy)
        {
            var s = settings;
            var r = (int)Round(s.ScrollProbeRadiusPt);
            var maxShift = (int)Round(s.MaximumScrollPt);
            var xa = Math.Max(cx - r, maxShift);
            var xb = Math.Min(cx + r, b.Width - 1 - maxShift);
            var ya = Math.Max(cy - r, maxShift);
            var yb = Math.Min(cy + r, b.Height - 1 - maxShift);
            if (xa >= xb || ya >= yb)
            {
                return false;
            }

            int Residual(int dx, int dy)
            {
                var sum = 0;
                for (var y = ya; y <= yb; y++)
                {
                    for (var x = xa; x <= xb; x++)
                    {
                        sum += Math.Abs(b.Luma[b.Index(x, y)] - a.Luma[a.Index(x - dx, y - dy)]);
                    }
                }

                return sum;
            }

            var baseline = Residual(0, 0);
            if (baseline < 1)
            {
                return false;
            }

            var best = int.MaxValue;
            for (var shift = -maxShift; shift <= maxShift; shift++)
            {
                if (shift != 0)
                {
                    best = Math.Min(best, Math.Min(Residual(0, shift), Residual(shift, 0)));
                }
            }

            return s.ScrollExplainedResidual01 * baseline > best;
        }

        /// <summary>The element at <c>count / 2</c> after sorting, as on macOS.</summary>
        private static int Median(List<int> values)
        {
            var sorted = values.ToArray();
            Array.Sort(sorted);
            return sorted[sorted.Length / 2];
        }

        private Frame? Last(double atOrBefore)
        {
            for (var i = history.Count - 1; i >= 0; i--)
            {
                if (history[i].TimeMs <= atOrBefore)
                {
                    return history[i];
                }
            }

            return null;
        }

        private int LastIndex(double atOrBefore)
        {
            for (var i = history.Count - 1; i >= 0; i--)
            {
                if (history[i].TimeMs <= atOrBefore)
                {
                    return i;
                }
            }

            return -1;
        }
    }
}
