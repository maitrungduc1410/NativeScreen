using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using NativeScreen.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.UI;
using ZoomMode = NativeScreen.Core.ZoomMode;

namespace NativeScreen.App;

/// <summary>
/// Multi-track timeline. The ruler stays above the tracks and follows them sideways. Blocks are retained elements; the
/// playhead and the hover ghost sit over both and move by transform without a layout pass.
/// </summary>
internal sealed class TimelineView
{
    private const double LabelColumnWidth = 126;
    private const double TrackInset = 20;
    private const double RulerHeight = 30;
    private const double ClipRowHeight = 48;
    private const double ZoomRowHeight = 48;
    private const double MaskRowHeight = 34;
    private const double RowSpacing = 12;
    private const double EdgeHitWidth = 13;
    private const double GhostDuckDistance = 26;
    private const double GhostDuckDepth = 22;
    private const float HandleRestScale = 0.95f;
    private const float WiggleAmplitude = 1.65f;
    private static readonly TimeSpan WiggleHalfPeriod = TimeSpan.FromMilliseconds(420);
    private static readonly TimeSpan WiggleSettle = TimeSpan.FromMilliseconds(160);
    private const double MinBlockMs = 200;

    private readonly EditorSession session;
    private readonly Grid root;
    private readonly ScrollViewer scroller = new()
    {
        HorizontalScrollMode = ScrollMode.Enabled,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollMode = ScrollMode.Enabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto
    };
    private readonly ScrollViewer labelScroller = new()
    {
        VerticalScrollMode = ScrollMode.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
        HorizontalScrollMode = ScrollMode.Disabled
    };
    private readonly TrackSurface canvas = new();
    private readonly Canvas labels = new();
    private readonly Grid rulerHost = new();
    private readonly RulerSurface ruler = new() { Height = RulerHeight, HorizontalAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
    private readonly TranslateTransform rulerOffset = new();
    private readonly Canvas marks = new() { IsHitTestVisible = false };
    private readonly TimelineSnapController snap = new();
    private readonly Microsoft.UI.Xaml.Shapes.Rectangle snapGuide = new()
    {
        Width = 1,
        Fill = new SolidColorBrush(Color.FromArgb(230, 112, 77, 255)),
        Visibility = Visibility.Collapsed
    };
    private readonly PlayheadMark playhead = new(Color.FromArgb(255, 112, 77, 255), Color.FromArgb(230, 112, 77, 255));
    private readonly PlayheadMark ghost = new(Color.FromArgb(235, 64, 69, 87), Color.FromArgb(166, 64, 69, 87)) { Visibility = Visibility.Collapsed };
    private readonly SolidColorBrush ghostStem = new(Color.FromArgb(166, 64, 69, 87));
    private readonly SolidColorBrush ghostSplitStem = new(Color.FromArgb(230, 240, 82, 66));
    private readonly LinearGradientBrush clipTick = new()
    {
        StartPoint = new Windows.Foundation.Point(0, 0),
        EndPoint = new Windows.Foundation.Point(0, 1),
        GradientStops =
        {
            new GradientStop { Color = Color.FromArgb(46, 255, 255, 255), Offset = 0 },
            new GradientStop { Color = Color.FromArgb(0, 255, 255, 255), Offset = 1 }
        }
    };
    private double rulerStepSeconds = 1;
    private Grid? hoveredHandles;
    private BlockGrid? hoveredBlock;
    private bool splitCursor;
    private readonly List<(UIElement Block, int Row)> wigglingBlocks = [];
    private readonly List<double> blockRows = [];
    private double zoom = 1;
    private double viewportWidth = 800;
    private bool scrubbing;
    private Drag? drag;

    public TimelineView(EditorSession session, Grid root)
    {
        this.session = session;
        this.root = root;
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(LabelColumnWidth) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(RulerHeight) });
        root.RowDefinitions.Add(new RowDefinition());

        var corner = new Border { BorderBrush = Ui.Pal("Ink07"), BorderThickness = new Thickness(0, 0, 1, 0), Padding = new Thickness(14, 0, 0, 0) };
        var cornerLabel = Ui.Text("Tracks", 10.5, "Ink45", medium: true);
        cornerLabel.TextWrapping = TextWrapping.NoWrap;
        corner.Child = cornerLabel;
        root.Children.Add(corner);

        ruler.RenderTransform = rulerOffset;
        rulerHost.Children.Add(ruler);
        Grid.SetColumn(rulerHost, 1);
        root.Children.Add(rulerHost);

        labelScroller.Content = labels;
        Grid.SetRow(labelScroller, 1);
        root.Children.Add(labelScroller);
        scroller.Content = canvas;
        Grid.SetRow(scroller, 1);
        Grid.SetColumn(scroller, 1);
        root.Children.Add(scroller);

        A11y.Decorative(marks);
        ruler.Seconds = () => session.PlayheadTimelineMs / 1000;
        ruler.DurationSeconds = () => session.DurationMs / 1000;
        ruler.MoveTo = seconds =>
        {
            EndSkim();
            session.Scrub(Math.Clamp(seconds * 1000, 0, session.DurationMs));
            UpdatePlayhead();
            PlayheadScrubbed?.Invoke();
        };
        marks.Children.Add(snapGuide);
        marks.Children.Add(ghost);
        marks.Children.Add(playhead);
        Grid.SetColumn(marks, 1);
        Grid.SetRowSpan(marks, 2);
        root.Children.Add(marks);

        scroller.ViewChanged += (_, _) =>
        {
            labelScroller.ChangeView(null, scroller.VerticalOffset, null, true);
            rulerOffset.X = -scroller.HorizontalOffset;
            UpdatePlayhead();
        };
        root.SizeChanged += (_, args) =>
        {
            viewportWidth = Math.Max(300, args.NewSize.Width - LabelColumnWidth);
            rulerHost.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, viewportWidth, RulerHeight) };
            marks.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, viewportWidth, args.NewSize.Height) };
            Rebuild();
        };
        canvas.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        canvas.PointerPressed += CanvasPressed;
        root.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(WheelZoom), handledEventsToo: true);
        canvas.PointerMoved += CanvasMoved;
        canvas.PointerExited += PointerLeft;
        canvas.PointerReleased += CanvasReleased;
        canvas.PointerCaptureLost += (_, _) => EndDrag();
        ruler.PointerPressed += CanvasPressed;
        ruler.PointerMoved += CanvasMoved;
        ruler.PointerExited += PointerLeft;
        ruler.PointerReleased += CanvasReleased;
        ruler.PointerCaptureLost += (_, _) => EndDrag();
    }

    private readonly List<WaveImage> waveImages = [];
    private readonly Dictionary<string, WaveCache> waveCache = [];
    private DispatcherQueueTimer? sharpenTimer;
    private readonly List<(BlockGrid Block, double SourceStart, double SourceEnd)> followers = [];
    private readonly Dictionary<string, (BlockGrid Block, Canvas Ticks)> clipBlocks = [];
    private readonly HashSet<BlockGrid> clipOwners = [];
    private readonly List<TrimBadgeView> trimBadges = [];
    private int trimBadgesUsed;

    /// <summary>Hover rows and prompts that span the whole track, widened by a zoom step.</summary>
    private readonly List<FrameworkElement> fullWidthRows = [];
    private readonly Dictionary<string, WaveformEnvelope> voiceoverWaves = [];
    private readonly Dictionary<string, double> voiceoverFileMs = [];
    private readonly Dictionary<BlockGrid, string> voiceoverWaveIds = [];
    private WaveformEnvelope? systemWave;
    private WaveformEnvelope? microphoneWave;
    private Border? recordingVoiceoverBlock;

    private double TrackWidth => Math.Max(260, viewportWidth - TrackInset * 2) * zoom;

    /// <summary>Which recorded sources the clip menu offers a volume for. Set once by the window from the metadata.</summary>
    public bool HasMicrophone { get; set; }

    public bool HasSystemAudio { get; set; }

    /// <summary>The editor's file actions, for menus that upload audio. Set once by the window.</summary>
    public EditorTools? Tools { get; set; }

    /// <summary>A touchpad pinch reaches the window as Ctrl and the wheel; the value multiplies the timeline zoom.</summary>
    public event Action<double>? ZoomNudged;

    /// <summary>A message for the editor's toast, already translated.</summary>
    public event Action<string>? Toast;

    /// <summary>The hovered time changed while paused, so the preview should redraw.</summary>
    public event Action? Skimmed;

    /// <summary>The playhead was moved by hand, so the clock label and the preview must follow it.</summary>
    public event Action? PlayheadScrubbed;

    public void SetRecordingWaveforms(float[]? system, float[]? microphone)
    {
        systemWave = system is null ? null : new WaveformEnvelope(system);
        microphoneWave = microphone is null ? null : new WaveformEnvelope(microphone);
        Rebuild();
    }

    /// <summary>False when the original's samples have not been read yet; the new ids are then read like any other.</summary>
    public bool CopyVoiceoverWaveform(string original, string first, string second)
    {
        if (!voiceoverWaves.TryGetValue(original, out var wave))
        {
            return false;
        }

        voiceoverWaves[first] = voiceoverWaves[second] = wave;
        voiceoverFileMs[first] = voiceoverFileMs[second] = voiceoverFileMs[original];
        return true;
    }

    public void SetVoiceoverWaveform(string id, float[] samples, double fileMs)
    {
        voiceoverFileMs[id] = fileMs;
        voiceoverWaves[id] = new WaveformEnvelope(samples);
        Rebuild();
    }

    /// <summary>A volume slider moved. Only the waves it changed are drawn again.</summary>
    public void RefreshWaveformVolumes()
    {
        foreach (var wave in waveImages)
        {
            UpdateWave(wave);
        }
    }

    /// <summary>Split mode hides the handles and turns the pointer into a crosshair over everything it can cut.</summary>
    public void RefreshSplitMode()
    {
        if (splitCursor == session.IsSplitModeActive)
        {
            return;
        }

        splitCursor = session.IsSplitModeActive;
        var shape = splitCursor ? InputSystemCursorShape.Cross : InputSystemCursorShape.Arrow;
        canvas.SetCursor(shape);
        hoveredBlock?.SetCursor(shape);
        if (splitCursor)
        {
            StartWiggle();
        }
        else
        {
            StopWiggle();
        }

        if (hoveredHandles is not null)
        {
            ShowHandles(hoveredHandles, !splitCursor);
        }

        UpdatePlayhead();
    }

    /// <summary>
    /// Split mode's tracks bob up and down, neighbors in opposite directions. It runs on the compositor, so the UI thread and
    /// the pointer are left alone, and it costs nothing outside the mode (spec/06 ADR-35).
    /// </summary>
    private void StartWiggle()
    {
        if (A11y.ReduceMotion)
        {
            return;
        }

        foreach (var (block, row) in wigglingBlocks)
        {
            var visual = ElementCompositionPreview.GetElementVisual(block);
            var compositor = visual.Compositor;
            var direction = row % 2 == 0 ? 1f : -1f;
            var ease = compositor.CreateCubicBezierEasingFunction(new System.Numerics.Vector2(0.42f, 0), new System.Numerics.Vector2(0.58f, 1));
            var wiggle = compositor.CreateScalarKeyFrameAnimation();
            wiggle.InsertKeyFrame(0, -WiggleAmplitude * direction);
            wiggle.InsertKeyFrame(1, WiggleAmplitude * direction, ease);
            wiggle.Duration = WiggleHalfPeriod;
            wiggle.Direction = AnimationDirection.Alternate;
            wiggle.IterationBehavior = AnimationIterationBehavior.Forever;
            visual.StartAnimation("Translation.Y", wiggle);
        }
    }

    private void StopWiggle()
    {
        foreach (var (block, _) in wigglingBlocks)
        {
            var visual = ElementCompositionPreview.GetElementVisual(block);
            var settle = visual.Compositor.CreateScalarKeyFrameAnimation();
            settle.InsertKeyFrame(1, 0);
            settle.Duration = WiggleSettle;
            visual.StartAnimation("Translation.Y", settle);
        }
    }

    /// <summary>
    /// Changes the scale. The time under the cursor stays put for a Ctrl + wheel zoom over the lanes or ruler, and the playhead
    /// for everything else (spec/06 ADR-45).
    /// </summary>
    public void SetZoom(double value)
    {
        var anchorTime = session.PlayheadTimelineMs;
        var onScreen = X(anchorTime) - scroller.HorizontalOffset;
        if (zoomAnchorX is { } cursorX)
        {
            anchorTime = (scroller.HorizontalOffset + cursorX - TrackInset) / TrackWidth * session.TimelineScaleDurationMs;
            onScreen = cursorX;
        }

        zoomAnchorX = null;
        var started = System.Diagnostics.Stopwatch.GetTimestamp();
        zoom = value;
        Relayout();
        var rebuilt = System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        canvas.UpdateLayout();
        var target = X(anchorTime) - onScreen;
        scroller.ChangeView(Math.Clamp(target, 0, Math.Max(0, canvas.Width - scroller.ViewportWidth)), null, null, true);
        if (ZoomStatsFile is { } stats)
        {
            File.AppendAllText(stats, $"{value:0.000}\t{rebuilt:0.00}\t{System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds:0.00}\n");
        }
    }

    /// <summary>NS_TIMELINE_ZOOM_STATS=&lt;file&gt; appends the zoom and the milliseconds each zoom step took, for measuring.</summary>
    private static readonly string? ZoomStatsFile = Environment.GetEnvironmentVariable("NS_TIMELINE_ZOOM_STATS");

    /// <summary>Viewport x of the cursor for the zoom step being applied, or null to keep the playhead.</summary>
    private double? zoomAnchorX;

    private long lastZoomStepTicks;

    /// <summary>Hover skim pauses briefly after a zoom step: the content moves under a still cursor (spec/06 ADR-46).</summary>
    private bool IsZooming => Environment.TickCount64 - lastZoomStepTicks < 150;

    /// <summary>
    /// Ctrl + wheel anywhere over the timeline. A wheel notch is x1.15 (at most 4 per event); a touchpad or other precise device
    /// is exp(delta / 1200). Away from you zooms in. Without Ctrl the lanes scroll as usual.
    /// </summary>
    private void WheelZoom(object sender, PointerRoutedEventArgs args)
    {
        if (!args.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control))
        {
            return;
        }

        args.Handled = true;
        var point = args.GetCurrentPoint(root);
        var delta = point.Properties.MouseWheelDelta;
        if (delta == 0)
        {
            return;
        }

        var precise = args.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touchpad || delta % 120 != 0;
        var factor = precise ? Math.Exp(delta / 1200.0) : Math.Pow(1.15, Math.Clamp(delta / 120.0, -4, 4));
        var x = point.Position.X - LabelColumnWidth;
        zoomAnchorX = x >= 0 ? x : null;
        lastZoomStepTicks = Environment.TickCount64;
        ZoomNudged?.Invoke(factor);
        zoomAnchorX = null;
    }

    /// <summary>Called on every clock tick while playing, so it only moves a transform.</summary>
    public void UpdatePlayhead()
    {
        UpdateRecordingVoiceoverBlock();
        var height = root.ActualHeight;
        var mainX = X(session.PlayheadTimelineMs) - scroller.HorizontalOffset;
        playhead.Place(mainX, PlayheadMark.TopY, height);
        if (session.HoverSkimTimelineMs is { } skim && !session.IsPlaying)
        {
            // The ghost's head ducks under the main one as it gets close, so the two never fight for the same spot.
            var ghostX = X(skim) - scroller.HorizontalOffset;
            var proximity = Math.Clamp(1 - Math.Abs(ghostX - mainX) / GhostDuckDistance, 0, 1);
            ghost.Place(ghostX, PlayheadMark.TopY + GhostDuckDepth * proximity * (2 - proximity), height);
            ghost.SetStem(session.IsSplitModeActive ? ghostSplitStem : ghostStem);
            ghost.Visibility = Visibility.Visible;
        }
        else
        {
            ghost.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>
    /// A zoom step only moves and widens what is there: building the tree again cost about 11 ms a step. Waves are shown
    /// stretched until the width settles (spec/06 ADR-46).
    /// </summary>
    private void Relayout()
    {
        if (canvas.Children.Count == 0)
        {
            Rebuild();
            return;
        }

        rulerStepSeconds = TimelineRuler.StepSeconds(session.TimelineScaleDurationMs, TrackWidth);
        ruler.Children.Clear();
        foreach (var badge in trimBadges)
        {
            ruler.Children.Add(badge.Button);
        }

        DrawRuler();
        FollowClipEdit(null);
        foreach (var row in fullWidthRows)
        {
            row.Width = TrackWidth;
        }

        canvas.Width = TrackWidth + TrackInset * 2;
        ruler.Width = canvas.Width;
        UpdatePlayhead();
    }

    public void Rebuild()
    {

        canvas.Children.Clear();
        ruler.Children.Clear();
        wigglingBlocks.Clear();
        waveImages.Clear();
        voiceoverWaveIds.Clear();
        fullWidthRows.Clear();
        followers.Clear();
        clipBlocks.Clear();
        clipOwners.Clear();
        trimBadges.Clear();
        blockRows.Clear();
        labels.Children.Clear();
        rulerStepSeconds = TimelineRuler.StepSeconds(session.TimelineScaleDurationMs, TrackWidth);
        DrawRuler();
        var y = 8.0;
        y = DrawTypingSuggestions(y);
        y = DrawClips(y);
        y = DrawZooms(y);
        y = DrawLayouts(y);
        y = DrawMasks(y);
        y = DrawAnnotations(y);
        y = DrawShortcuts(y);
        y = DrawVoiceovers(y);
        y = DrawCaptions(y);
        y += 12;
        var height = Math.Max(y, root.ActualHeight - RulerHeight);
        canvas.Width = TrackWidth + TrackInset * 2;
        ruler.Width = canvas.Width;
        canvas.Height = height;
        labels.Height = height;
        var rule = new Border { Width = 1, Height = height, Background = Ui.Pal("Ink07") };
        Canvas.SetLeft(rule, LabelColumnWidth - 1);
        labels.Children.Add(rule);
        UpdatePlayhead();
        if (splitCursor)
        {
            StartWiggle();
        }
    }

    private double X(double timelineMs) => TrackInset + timelineMs / session.TimelineScaleDurationMs * TrackWidth;

    private double TimeAtUnclamped(double x) => Math.Max(0, (x - TrackInset) / TrackWidth * session.TimelineScaleDurationMs);

    private double TimeAt(double x) => Math.Clamp((x - TrackInset) / TrackWidth * session.TimelineScaleDurationMs, 0, session.DurationMs);

    /// <summary>A source time inside a removed part of the recording snaps to the next kept slice.</summary>
    private double TimelineOf(double sourceMs)
    {
        foreach (var mapped in session.Mapper.MappedSlices)
        {
            if (sourceMs <= mapped.Slice.SourceStartMs)
            {
                return mapped.TimelineStartMs;
            }

            if (sourceMs <= mapped.Slice.SourceEndMs)
            {
                return mapped.TimelineStartMs + (sourceMs - mapped.Slice.SourceStartMs) / Math.Max(0.1, mapped.Slice.Speed);
            }
        }

        return session.DurationMs;
    }

    /// <summary>Left and width of a segment. One no slice keeps gets its plain length, for when a clip drag brings it back.</summary>
    private (double Left, double Width) Place(double sourceStart, double sourceEnd)
    {
        if (session.Mapper.TimelineSpan(sourceStart, sourceEnd) is { } span)
        {
            var left = X(span.Start);
            return (left, X(span.End) - left);
        }

        return (0, (sourceEnd - sourceStart) / session.TimelineScaleDurationMs * TrackWidth);
    }

    /// <summary>A segment no slice keeps is made anyway, hidden: a clip drag can bring it back, and a drag cannot add to the tree.</summary>
    private void Follow(BlockGrid block, double sourceStart, double sourceEnd)
    {
        followers.Add((block, sourceStart, sourceEnd));
        if (session.Mapper.TimelineSpan(sourceStart, sourceEnd) is null)
        {
            block.Visibility = Visibility.Collapsed;
        }
    }

    private void DrawRuler()
    {
        const double dotY = RulerHeight - 6;
        const double labelWidth = 60;
        var totalSeconds = Math.Max(1, session.TimelineScaleDurationMs / 1000);
        for (var index = 1; ; index++)
        {
            var t = index * rulerStepSeconds;
            if (t >= totalSeconds - 0.001)
            {
                break;
            }

            var x = X(t * 1000);
            var dot = new Ellipse { Width = 3.6, Height = 3.6, Fill = Ui.Pal("Ink45"), Opacity = 0.71 };
            Canvas.SetLeft(dot, x - 1.8);
            Canvas.SetTop(dot, dotY - 1.8);
            ruler.Children.Add(dot);

            // Half seconds get a dot only, and a label too close to either end is left out.
            var ms = (long)Math.Round(t * 1000);
            var fromStart = x - TrackInset;
            if (ms % 1000 == 0 && fromStart >= 14 && fromStart <= TrackWidth - 14)
            {
                var whole = ms / 1000;
                var label = new TextBlock
                {
                    Text = $"{whole / 60}:{whole % 60:00}",
                    Width = labelWidth,
                    FontSize = 11,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Ui.Pal("Ink45"),
                    Opacity = 0.76,
                    TextAlignment = TextAlignment.Center
                };
                Canvas.SetLeft(label, x - labelWidth / 2);
                Canvas.SetTop(label, dotY - 17);
                ruler.Children.Add(label);
            }
        }
    }

    private static string ClipSubtitle(double timelineMs, double speed) => $"{timelineMs / 1000:0.#}s  ·  {speed:0.##}x";

    /// <summary>
    /// A clip's edge moved: the ruler and scale stay, and everything after the edge closes up, so the drag shows how much was
    /// taken off. No tree rebuild, since the pointer is captured and this runs on every move (spec/06 ADR-19).
    /// </summary>
    private void FollowClipEdit(BlockGrid? edited)
    {
        foreach (var mapped in session.Mapper.MappedSlices)
        {
            if (!clipBlocks.TryGetValue(mapped.Slice.Id, out var entry))
            {
                continue;
            }

            var left = X(mapped.TimelineStartMs);
            var width = X(mapped.TimelineEndMs) - left;
            Canvas.SetLeft(entry.Block, left);
            entry.Block.Width = Math.Max(6, width);
            if (entry.Block.Subtitle is { } subtitle)
            {
                subtitle.Text = ClipSubtitle(mapped.TimelineEndMs - mapped.TimelineStartMs, mapped.Slice.Speed);
            }

            FillRulerTicks(entry.Ticks, mapped.TimelineStartMs, mapped.TimelineEndMs, width);
            if (edited is null || entry.Block == edited)
            {
                RetraceClipWaves(entry.Block, mapped.Slice, width);
            }
        }

        foreach (var (block, sourceStart, sourceEnd) in followers)
        {
            var shown = session.Mapper.TimelineSpan(sourceStart, sourceEnd) is not null;
            block.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
            if (shown)
            {
                var (left, width) = Place(sourceStart, sourceEnd);
                Canvas.SetLeft(block, left);
                block.Width = Math.Max(6, width);
            }
        }

        // A voiceover cut short by the edit fits its whole wave into what is left, as it will after the drop.
        foreach (var wave in waveImages)
        {
            var innerWidth = wave.Owner.Width - wave.Owner.BorderThickness.Left * 2;
            if (!clipOwners.Contains(wave.Owner) && Math.Abs(innerWidth - wave.Width) > 0.5)
            {
                wave.Width = innerWidth;
                UpdateWave(wave);
            }
        }

        DrawTrimBadges();
    }

    private void RetraceClipWaves(BlockGrid block, ClipSlice slice, double width)
    {
        var (start, end) = WaveRange(slice);
        foreach (var wave in waveImages)
        {
            if (wave.Owner == block)
            {
                wave.Start = start;
                wave.End = end;
                wave.Width = width - block.BorderThickness.Left * 2;
                UpdateWave(wave);
            }
        }
    }

    private (double Start, double End) WaveRange(ClipSlice slice)
    {
        var total = Math.Max(1, session.SourceDurationMs);
        var start = Math.Clamp(slice.SourceStartMs / total, 0, 1);
        return (start, Math.Max(start + 0.001, Math.Min(1, slice.SourceEndMs / total)));
    }

    private double DrawClips(double y)
    {
        AddLabel("Clip", y, ClipRowHeight, eye: false);
        foreach (var mapped in session.Mapper.MappedSlices)
        {
            var slice = mapped.Slice;
            var seconds = mapped.TimelineEndMs - mapped.TimelineStartMs;
            var block = Block(
                X(mapped.TimelineStartMs),
                y,
                X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs),
                ClipRowHeight,
                Palette.Clip,
                "Clip",
                ClipSubtitle(seconds, slice.Speed),
                slice.Id == session.SelectedSliceId,
                false);
            AddClipWaveforms(block, slice, X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs));
            var id = slice.Id;
            var ticks = AddRulerTicks(block, mapped.TimelineStartMs, mapped.TimelineEndMs, X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs));
            clipBlocks[id] = (block, ticks);
            clipOwners.Add(block);
            var blockWidth = X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs);
            block.SplitAt = time => session.SplitSlice(time);
            Draggable(
                block,
                blockWidth,
                null,
                () => session.SelectSlice(id),
                (start, end) => session.Mutate(document => TimelineEdits.SetSliceRange(document, id, start, end, session.SourceDurationMs), structural: false),
                () =>
                {
                    var current = session.Document.Timeline.Slices.First(other => other.Id == id);
                    var (low, high) = TimelineEdits.SliceBounds(session.Document, id, session.SourceDurationMs);
                    return (current.SourceStartMs, current.SourceEndMs, low, high);
                },
                canMove: false);
            block.RightTapped += (_, args) =>
            {
                args.Handled = true;
                SegmentMenu.ForClip(session, id, HasMicrophone, HasSystemAudio, canvas, args.GetPosition(canvas));
            };
        }

        DrawTrimBadges();
        return y + ClipRowHeight + RowSpacing;
    }

    /// <summary>Runs on every move of a clip drag, so the buttons already there are moved and only the difference is added or removed.</summary>
    private void DrawTrimBadges()
    {
        trimBadgesUsed = 0;
        PlaceTrimBadges();
        while (trimBadges.Count > trimBadgesUsed)
        {
            ruler.Children.Remove(trimBadges[^1].Button);
            trimBadges.RemoveAt(trimBadges.Count - 1);
        }
    }

    /// <summary>Gold teardrops on the ruler for what was trimmed or cut; a click restores it.</summary>
    private void PlaceTrimBadges()
    {
        var cuts = session.Mapper.MappedSlices;
        if (cuts.Count == 0)
        {
            return;
        }

        const double threshold = 20;
        var first = cuts[0].Slice;
        if (first.SourceStartMs > threshold)
        {
            var id = first.Id;
            TrimBadge(cuts[0].TimelineStartMs, TrimLabel(first.SourceStartMs), "Undo trim", () => session.RemoveSliceStartTrim(id));
        }

        for (var index = 0; index + 1 < cuts.Count; index++)
        {
            var id = cuts[index].Slice.Id;
            var gap = Math.Max(0, cuts[index + 1].Slice.SourceStartMs - cuts[index].Slice.SourceEndMs);
            TrimBadge(cuts[index].TimelineEndMs, gap > threshold ? TrimLabel(gap) : null, gap > threshold ? "Undo trim" : "Join clips", () => session.MergeSliceWithNext(id));
        }

        var last = cuts[^1].Slice;
        var tail = session.SourceDurationMs - last.SourceEndMs;
        if (tail > threshold)
        {
            var id = last.Id;
            TrimBadge(cuts[^1].TimelineEndMs, TrimLabel(tail), "Undo trim", () => session.RemoveSliceEndTrim(id));
        }
    }

    private static string TrimLabel(double ms)
    {
        var seconds = Math.Max(0, ms / 1000);
        if (seconds < 1)
        {
            return $"{seconds:0.0}s";
        }

        if (seconds < 60)
        {
            return $"{seconds:0}s";
        }

        var minutes = (int)(seconds / 60);
        return minutes < 60 ? $"{minutes}m" : $"{minutes / 60}h";
    }

    private void TrimBadge(double timelineMs, string? label, string tooltip, Action click)
    {
        tooltip = Loc.T(tooltip);
        if (trimBadgesUsed == trimBadges.Count)
        {
            trimBadges.Add(NewTrimBadge());
        }

        var badge = trimBadges[trimBadgesUsed++];
        badge.Click = click;
        badge.Label.Text = label ?? "";
        badge.Label.Visibility = label is null ? Visibility.Collapsed : Visibility.Visible;
        badge.Icon.Visibility = label is null ? Visibility.Visible : Visibility.Collapsed;
        if (badge.Tooltip != tooltip)
        {
            badge.Tooltip = tooltip;
            Ui.Tip(badge.Button, tooltip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(badge.Button, tooltip);
        }

        Canvas.SetLeft(badge.Button, X(timelineMs) - 15);
    }

    private TrimBadgeView NewTrimBadge()
    {
        var content = new Grid { Width = 30, Height = 28 };
        content.Children.Add(Ui.Shape("M0,0 A7,7 0 0 1 14,0 C14,6 9,11 7,16 C5,11 0,6 0,0 Z", 26, new SolidColorBrush(Palette.Clip.Ring)));
        var ink = new SolidColorBrush(Color.FromArgb(255, 60, 40, 5));
        var icon = Ui.Icon("", 9, ink);
        var label = new TextBlock { FontSize = 8, FontWeight = FontWeights.Bold, Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        icon.Margin = label.Margin = new Thickness(0, 0, 0, 7);
        content.Children.Add(icon);
        content.Children.Add(label);
        var button = new Button { Style = Ui.StyleOf("NsIconButton"), Content = content, Width = 30, Height = 28, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        var badge = new TrimBadgeView(button, label, icon);
        button.Click += (_, _) => badge.Click?.Invoke();
        Canvas.SetTop(button, RulerHeight - 28);
        Canvas.SetZIndex(button, 5);
        ruler.Children.Add(button);
        return badge;
    }

    /// <summary>Faint lines down from the top of a clip, under each ruler mark.</summary>
    private Canvas AddRulerTicks(BlockGrid block, double timelineStart, double timelineEnd, double width)
    {
        var ticks = new Canvas { IsHitTestVisible = false };
        FillRulerTicks(ticks, timelineStart, timelineEnd, width);
        block.Children.Insert(block.Children.Count - 1, ticks);
        return ticks;
    }

    private void FillRulerTicks(Canvas ticks, double timelineStart, double timelineEnd, double width)
    {
        // Runs on every move of a clip drag: the lines already there are moved, not made again.
        var used = 0;
        var stepMs = rulerStepSeconds * 1000;
        for (var ms = Math.Ceiling(timelineStart / stepMs) * stepMs; ms < timelineEnd; ms += stepMs)
        {
            var x = (ms - timelineStart) / Math.Max(1, timelineEnd - timelineStart) * width;
            if (x > 4 && x < width - 4)
            {
                Rectangle tick;
                if (used < ticks.Children.Count)
                {
                    tick = (Rectangle)ticks.Children[used];
                }
                else
                {
                    tick = new Rectangle { Width = 1, Height = ClipRowHeight * 0.65, Fill = clipTick };
                    ticks.Children.Add(tick);
                }

                Canvas.SetLeft(tick, x - 0.5);
                used++;
            }
        }

        while (ticks.Children.Count > used)
        {
            ticks.Children.RemoveAt(ticks.Children.Count - 1);
        }
    }

    /// <summary>The microphone in white under system audio in purple, each at its slice's volume (spec/06 ADR-42).</summary>
    private void AddClipWaveforms(BlockGrid block, ClipSlice slice, double width)
    {
        if (systemWave is null && microphoneWave is null)
        {
            return;
        }

        var (start, end) = WaveRange(slice);
        var id = slice.Id;
        AddWave(block, width, ClipRowHeight, "clip:" + id, start, end, () =>
        {
            var audio = session.Document.Audio;
            var current = session.Document.Timeline.Slices.Find(other => other.Id == id);
            var layers = new List<WaveformRasterLayer>(2);
            if (microphoneWave is { } microphone)
            {
                var volume = current is null || current.Muted || audio.MuteMicrophone ? 0 : current.MicrophoneVolume * audio.MicrophoneVolume;
                layers.Add(new WaveformRasterLayer(microphone, volume, 1, 1, 1, 0.35));
            }

            if (systemWave is { } system)
            {
                var volume = current is null || current.Muted || audio.MuteSystemAudio ? 0 : current.SystemAudioVolume * audio.SystemAudioVolume;
                layers.Add(new WaveformRasterLayer(system, volume, 77 / 255.0, 47 / 255.0, 245 / 255.0, 0.5));
            }

            return layers;
        });
    }

    /// <summary>
    /// The waveform bitmap along the bottom of a block, under its ticks and text. A zoom only changes the width, so the last
    /// bitmap is shown stretched and a sharp one is drawn off the UI thread once the width holds still (spec/06 ADR-46).
    /// </summary>
    private void AddWave(BlockGrid block, double width, double height, string cacheId, double startFraction, double endFraction, Func<List<WaveformRasterLayer>> layers)
    {
        if (!AppSettings.Shared.ShowAudioWaveform || width < 8)
        {
            return;
        }

        // Children are laid out inside the border, so the wave fits what is left.
        var border = block.BorderThickness.Top;
        var image = new Image
        {
            IsHitTestVisible = false,
            Stretch = Stretch.Fill,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top
        };
        block.Children.Insert(0, image);
        var wave = new WaveImage(block, image, cacheId, layers, startFraction, endFraction, width - border * 2, height - border * 2, Math.Max(0, block.CornerRadius.TopLeft - border));
        waveImages.Add(wave);
        UpdateWave(wave);
    }

    private double RasterScale => root.XamlRoot?.RasterizationScale ?? 1;

    private void UpdateWave(WaveImage wave)
    {
        wave.Image.Width = Math.Max(0, wave.Width);
        wave.Image.Height = wave.Height;
        var layers = wave.Layers();
        var scale = RasterScale;
        var smooth = AppSettings.Shared.SmoothWaveform;
        var key = WaveKey(wave, layers, scale, smooth);
        var widthPx = (int)Math.Ceiling(wave.Width * scale);
        if (waveCache.TryGetValue(wave.CacheId, out var cached) && cached.Key == key)
        {
            wave.Image.Source = cached.Bitmap;
            if (cached.WidthPx != widthPx)
            {
                ScheduleSharpen();
            }

            return;
        }

        var raster = WaveformRaster.Rasterize(layers, wave.Start, wave.End, wave.Width, wave.Height, scale, smooth, wave.Radius);
        var bitmap = raster is null ? null : ToBitmap(raster);
        waveCache[wave.CacheId] = new WaveCache(key, widthPx, bitmap);
        wave.Image.Source = bitmap;
    }

    /// <summary>Everything a wave's look depends on except its width.</summary>
    private static string WaveKey(WaveImage wave, List<WaveformRasterLayer> layers, double scale, bool smooth)
    {
        var text = new System.Text.StringBuilder();
        text.Append(wave.Start.ToString("R")).Append('|').Append(wave.End.ToString("R")).Append('|')
            .Append(wave.Height.ToString("R")).Append('|').Append(scale.ToString("R")).Append('|').Append(smooth).Append('|').Append(wave.Radius.ToString("R"));
        foreach (var layer in layers)
        {
            text.Append('|').Append(System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(layer.Envelope)).Append(':').Append(layer.Volume.ToString("R"));
        }

        return text.ToString();
    }

    private static WriteableBitmap ToBitmap(WaveformBitmap raster)
    {
        var bitmap = new WriteableBitmap(raster.Width, raster.Height);
        using (var stream = bitmap.PixelBuffer.AsStream())
        {
            stream.Write(raster.Pixels, 0, raster.Pixels.Length);
        }

        bitmap.Invalidate();
        return bitmap;
    }

    /// <summary>The editor closed: drops the timer, whose native handler would otherwise keep this view alive.</summary>
    public void Detach()
    {
        if (sharpenTimer is { } timer)
        {
            timer.Stop();
            timer.Tick -= SharpenTick;
            sharpenTimer = null;
        }
    }

    private void SharpenTick(DispatcherQueueTimer sender, object args) => Sharpen();

    /// <summary>90 ms after the width last changed, waves shown stretched are drawn again at their real width on a worker thread.</summary>
    private void ScheduleSharpen()
    {
        if (sharpenTimer is null)
        {
            sharpenTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
            sharpenTimer.Interval = TimeSpan.FromMilliseconds(90);
            sharpenTimer.IsRepeating = false;
            sharpenTimer.Tick += SharpenTick;
        }

        sharpenTimer.Stop();
        sharpenTimer.Start();
    }

    private void Sharpen()
    {
        var scale = RasterScale;
        var smooth = AppSettings.Shared.SmoothWaveform;
        foreach (var wave in waveImages.ToList())
        {
            var widthPx = (int)Math.Ceiling(wave.Width * scale);
            if (!waveCache.TryGetValue(wave.CacheId, out var cached) || cached.WidthPx == widthPx)
            {
                continue;
            }

            var layers = wave.Layers();
            var key = WaveKey(wave, layers, scale, smooth);
            if (key != cached.Key)
            {
                continue;
            }

            var (start, end, width, height, radius) = (wave.Start, wave.End, wave.Width, wave.Height, wave.Radius);
            _ = Task.Run(() => WaveformRaster.Rasterize(layers, start, end, width, height, scale, smooth, radius)).ContinueWith(task =>
            {
                // Dropped if the wave was rebuilt, edited or resized again while this was drawn.
                if (task.Result is not { } raster || !waveImages.Contains(wave) || wave.Width != width || WaveKey(wave, wave.Layers(), RasterScale, AppSettings.Shared.SmoothWaveform) != key)
                {
                    return;
                }

                var bitmap = ToBitmap(raster);
                waveCache[wave.CacheId] = new WaveCache(key, widthPx, bitmap);
                wave.Image.Source = bitmap;
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }
    }

    private double DrawTypingSuggestions(double y)
    {
        var suggestions = ShortcutEngine.TypingSuggestions(session.Document, session.KeyEvents);
        if (suggestions.Count == 0)
        {
            return y;
        }

        foreach (var item in suggestions)
        {
            var (left, width) = Place(item.SourceStartMs, item.SourceEndMs);
            var bar = Block(left, y, width, 16, Palette.Clip, "", null, false, false);
            Follow(bar, item.SourceStartMs, item.SourceEndMs);
            var target = item;
            bar.PointerPressed += (_, args) =>
            {
                var menu = new MenuFlyout();
                foreach (var speed in new[] { 2.0, 3, 4, 6, 8 })
                {
                    var value = speed;
                    var apply = new MenuFlyoutItem { Text = Loc.F("Speed up typing %@x", value.ToString("0", CultureInfo.CurrentCulture)) };
                    apply.Click += (_, _) => session.Mutate(document => TypingSuggestionEdits.Apply(document, target, value));
                    menu.Items.Add(apply);
                }

                var all = new MenuFlyoutItem { Text = Loc.T("Apply to all suggestions, 4x") };
                all.Click += (_, _) => session.Mutate(document =>
                {
                    foreach (var other in suggestions)
                    {
                        TypingSuggestionEdits.Apply(document, other, 4);
                    }
                });
                menu.Items.Add(all);
                var remove = new MenuFlyoutItem { Text = Loc.T("Remove suggestion") };
                remove.Click += (_, _) => session.Mutate(document => TypingSuggestionEdits.Dismiss(document, target));
                menu.Items.Add(remove);
                menu.ShowAt(bar);
                args.Handled = true;
            };
            Ui.Tip(bar, "Speed up typing");
        }

        AddLabel("Typing", y - 4, 22, eye: false);
        return y + 16 + 6;
    }

    private double DrawVoiceovers(double y)
    {
        var timeline = session.Document.Timeline;
        recordingVoiceoverBlock = null;
        if (timeline.Voiceovers.Count == 0 && !session.IsRecordingVoiceover)
        {
            return y;
        }

        var count = Math.Max(VoiceoverTrackLayout.TrackCount(timeline.Voiceovers), session.IsRecordingVoiceover ? session.VoiceoverRecordingTrackIndex + 1 : 0);
        for (var track = 0; track < count; track++)
        {
            var row = track;
            var hidden = VoiceoverTrackLayout.IsTrackHidden(timeline, row);
            AddLabel(row == 0 ? "Voiceovers" : $"Voiceovers {row + 1}", y, MaskRowHeight, eye: true, hidden, () => session.ToggleVoiceoverTrackHidden(row),
                session.IsRecordingVoiceover ? null : new DeletableTimelineTrack(DeletableTrackKind.Voiceover, Index: row));
            if (session.IsRecordingVoiceover && session.VoiceoverRecordingTrackIndex == row)
            {
                AddRecordingVoiceoverBlock(y);
            }

            foreach (var voiceover in timeline.Voiceovers.Where(item => item.TrackIndex == row))
            {
                var (left, width) = Place(voiceover.SourceStartMs, voiceover.SourceEndMs);
                var block = Block(left, y, width, MaskRowHeight, Palette.Mask, "Voiceover", $"{Math.Round(voiceover.Volume * 100):0}%", voiceover.Id == session.SelectedVoiceoverId, voiceover.Disabled || hidden || voiceover.Volume <= 0.001);
                Follow(block, voiceover.SourceStartMs, voiceover.SourceEndMs);
                var id = voiceover.Id;
                block.SplitAt = time => session.SplitVoiceover(id, session.Mapper.SourceTime(time).SourceMs);
                if (voiceoverWaves.TryGetValue(id, out var voiceoverWave))
                {
                    var (waveStart, waveEnd) = VoiceoverWaveRange(voiceover);
                    AddWave(block, width, MaskRowHeight, "voiceover:" + id, waveStart, waveEnd, () =>
                    {
                        var timelineNow = session.Document.Timeline;
                        var current = timelineNow.Voiceovers.Find(other => other.Id == id);
                        var volume = current is null || current.Disabled || VoiceoverTrackLayout.IsTrackHidden(timelineNow, current.TrackIndex) ? 0 : current.Volume;
                        return [new WaveformRasterLayer(voiceoverWave, volume, 1, 1, 1, 0.35)];
                    });
                    voiceoverWaveIds[block] = id;
                }

                Ui.Tip(block, Loc.F("Voiceover at %@", Ui.Timecode(voiceover.SourceStartMs)));
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    if (Tools is { } tools)
                    {
                        SegmentMenu.ForVoiceover(session, tools, id, canvas, args.GetPosition(canvas));
                    }
                };
                Draggable(block, width, id, () => session.SelectVoiceover(id), (start, end) =>
                {
                    var current = session.Document.Timeline.Voiceovers.First(other => other.Id == id);
                    // Moving keeps the length and the place in the file; only a trim changes them.
                    if (Math.Abs(end - start - current.DurationMs) < 1e-6)
                    {
                        session.Mutate(document => document.Timeline.Voiceovers.First(other => other.Id == id).SourceStartMs = start, structural: false);
                    }
                    else
                    {
                        session.ResizeVoiceover(id, start, end);
                    }
                }, () =>
                {
                    // Dragging along a track stops at its neighbors.
                    var current = session.Document.Timeline.Voiceovers.First(other => other.Id == id);
                    var neighbors = session.Document.Timeline.Voiceovers.Where(other => other.Id != id && other.TrackIndex == current.TrackIndex).ToList();
                    var low = neighbors.Where(other => other.SourceEndMs <= current.SourceStartMs).Select(other => other.SourceEndMs).DefaultIfEmpty(0).Max();
                    var high = neighbors.Where(other => other.SourceStartMs >= current.SourceEndMs).Select(other => other.SourceStartMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                    return (current.SourceStartMs, current.SourceEndMs, low, high);
                },
                movedRows: rows => session.MoveVoiceoverToTrack(id, row + rows),
                minimumMs: SegmentEdits.MinimumVoiceoverMs,
                startEdgeLow: () =>
                {
                    var current = session.Document.Timeline.Voiceovers.First(other => other.Id == id);
                    return current.SourceStartMs - current.FileOffsetMs;
                });
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    /// <summary>Grows with the playhead while a take is running.</summary>
    /// <summary>The part of the whole-file samples this segment plays, as fractions of the file.</summary>
    private (double Start, double End) VoiceoverWaveRange(VoiceoverSegment voiceover)
    {
        if (!voiceoverFileMs.TryGetValue(voiceover.Id, out var fileMs) || fileMs <= 0)
        {
            return (0, 1);
        }

        return (Math.Clamp(voiceover.FileOffsetMs / fileMs, 0, 1), Math.Clamp((voiceover.FileOffsetMs + voiceover.DurationMs) / fileMs, 0, 1));
    }

    private void AddRecordingVoiceoverBlock(double y)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        content.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = new SolidColorBrush(Color.FromArgb(255, 255, 59, 48)), VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = Loc.T("Recording voiceover..."), FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = Ui.Pal("Ink95"), TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center });
        recordingVoiceoverBlock = new Border
        {
            Height = MaskRowHeight,
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(82, 255, 59, 48)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(217, 255, 59, 48)),
            BorderThickness = new Thickness(1.2),
            IsHitTestVisible = false,
            Child = content
        };
        Canvas.SetTop(recordingVoiceoverBlock, y);
        Canvas.SetZIndex(recordingVoiceoverBlock, 3);
        canvas.Children.Add(recordingVoiceoverBlock);
        UpdateRecordingVoiceoverBlock();
    }

    private void UpdateRecordingVoiceoverBlock()
    {
        if (recordingVoiceoverBlock is not { } block)
        {
            return;
        }

        var start = TimelineOf(session.VoiceoverRecordingStartSourceMs);
        var current = Math.Max(start + 100, session.PlayheadTimelineMs);
        Canvas.SetLeft(block, X(start));
        block.Width = Math.Max(24, X(current) - X(start));
    }

    private double DrawZooms(double y)
    {
        var timeline = session.Document.Timeline;
        AddRowTarget(
            y,
            ZoomRowHeight,
            GhostStyle.Of(Palette.Zoom),
            () => session.Document.Timeline.Zooms.Select(item => session.Mapper.TimelineSpan(item.SourceStartMs, item.SourceEndMs)).OfType<(double Start, double End)>(),
            500,
            2800,
            350,
            session.AddZoomInRange,
            seekToMiddle: false,
            prompt: timeline.Zooms.Count == 0 ? "Click or drag to add zoom on cursor" : null);
        AddLabel("Zoom", y, ZoomRowHeight, eye: true, timeline.IsZoomTrackHidden, () =>
            session.Mutate(document => document.Timeline.IsZoomTrackHidden = !document.Timeline.IsZoomTrackHidden));
        foreach (var item in timeline.Zooms)
        {
            var (left, width) = Place(item.SourceStartMs, item.SourceEndMs);
            var block = Block(
                left,
                y,
                width,
                ZoomRowHeight,
                Palette.Zoom,
                item.Presentation == ZoomPresentation.Loupe ? "Loupe" : "Zoom",
                $"{item.Scale:0.#}x  ·  {Loc.T(item.Mode == ZoomMode.FollowCursor ? "Auto" : "Manual")}",
                item.Id == session.SelectedZoomId,
                item.Disabled || timeline.IsZoomTrackHidden);
            Follow(block, item.SourceStartMs, item.SourceEndMs);
            var id = item.Id;
            block.SplitAt = time => session.SplitZoom(id, session.Mapper.SourceTime(time).SourceMs);
            Draggable(block, width, id, () => session.SelectZoom(id), (start, end) =>
            {
                session.Mutate(document =>
                {
                    var zoomBlock = document.Timeline.Zooms.First(other => other.Id == id);
                    zoomBlock.SourceStartMs = start;
                    zoomBlock.SourceEndMs = end;
                }, structural: false);
            }, () =>
            {
                var current = session.Document.Timeline.Zooms.First(other => other.Id == id);
                var others = session.Document.Timeline.Zooms.Where(other => other.Id != id).ToList();
                var low = others.Where(other => other.SourceEndMs <= current.SourceStartMs).Select(other => other.SourceEndMs).DefaultIfEmpty(0).Max();
                var high = others.Where(other => other.SourceStartMs >= current.SourceEndMs).Select(other => other.SourceStartMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                return (current.SourceStartMs, current.SourceEndMs, low, high);
            });
            block.RightTapped += (_, args) =>
            {
                args.Handled = true;
                SegmentMenu.ForZoom(session, id, canvas, args.GetPosition(canvas));
            };
        }

        return y + ZoomRowHeight + RowSpacing;
    }

    private double DrawLayouts(double y)
    {
        var timeline = session.Document.Timeline;
        if (timeline.CameraLayouts.Count == 0)
        {
            return y;
        }

        AddRowTarget(
            y,
            MaskRowHeight,
            GhostStyle.Of(Palette.Layout),
            () => session.Document.Timeline.CameraLayouts.Select(item => session.Mapper.TimelineSpan(item.SourceStartMs, item.SourceEndMs)).OfType<(double Start, double End)>(),
            450,
            2800,
            350,
            (start, end) => session.AddCameraLayoutInRange(CameraTimelineLayoutType.CameraOverlay, start, end));
        AddLabel("Layouts", y, MaskRowHeight, eye: true, timeline.IsCameraLayoutsTrackHidden, () =>
            session.Mutate(document => document.Timeline.IsCameraLayoutsTrackHidden = !document.Timeline.IsCameraLayoutsTrackHidden),
            new DeletableTimelineTrack(DeletableTrackKind.CameraLayouts));
        foreach (var layout in timeline.CameraLayouts)
        {
            var (left, width) = Place(layout.SourceStartMs, layout.SourceEndMs);
            var block = Block(left, y, width, MaskRowHeight, Palette.Layout, LayoutTitle(layout.LayoutType), null, layout.Id == session.SelectedLayoutId, layout.Disabled);
            Follow(block, layout.SourceStartMs, layout.SourceEndMs);
            var id = layout.Id;
            block.SplitAt = time => session.SplitLayout(id, session.Mapper.SourceTime(time).SourceMs);
            Draggable(block, width, id, () => session.SelectLayout(id), (start, end) =>
            {
                session.Mutate(document =>
                {
                    var target = document.Timeline.CameraLayouts.First(other => other.Id == id);
                    target.SourceStartMs = start;
                    target.SourceEndMs = end;
                }, structural: false);
            }, () =>
            {
                var current = session.Document.Timeline.CameraLayouts.First(other => other.Id == id);
                var others = session.Document.Timeline.CameraLayouts.Where(other => other.Id != id).ToList();
                var low = others.Where(other => other.SourceEndMs <= current.SourceStartMs).Select(other => other.SourceEndMs).DefaultIfEmpty(0).Max();
                var high = others.Where(other => other.SourceStartMs >= current.SourceEndMs).Select(other => other.SourceStartMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                return (current.SourceStartMs, current.SourceEndMs, low, high);
            });
            block.RightTapped += (_, args) =>
            {
                args.Handled = true;
                SegmentMenu.ForLayout(session, id, canvas, args.GetPosition(canvas));
            };
        }

        return y + MaskRowHeight + RowSpacing;
    }

    /// <summary>Annotation tracks: the first draws on top (spec/02). Items never overlap on a track.</summary>
    private double DrawAnnotations(double y)
    {
        foreach (var track in session.Document.Timeline.AnnotationTracks)
        {
            var trackId = track.Id;
            AddRowTarget(
                y,
                MaskRowHeight,
                GhostStyle.Of(Palette.Annotation),
                () => (session.Document.Timeline.AnnotationTracks.Find(other => other.Id == trackId)?.Items ?? []).Select(item => session.Mapper.TimelineSpan(item.SourceStartMs, item.SourceEndMs)).OfType<(double Start, double End)>(),
                450,
                3000,
                (int)AnnotationItem.MinDurationMs,
                (start, end) => session.AddAnnotationInRange(trackId, start, end));
            AddLabel(Loc.TrackName(track.Name), y, MaskRowHeight, eye: true, track.IsHidden, () => session.ToggleAnnotationTrackVisibility(trackId), new DeletableTimelineTrack(DeletableTrackKind.Annotation, trackId));
            foreach (var item in track.Items)
            {
                var (left, width) = Place(item.SourceStartMs, item.SourceEndMs);
                var title = item.Kind == AnnotationKind.Text && item.Text.Trim().Length > 0 ? item.Text.Trim() : Loc.T(item.Kind.Title());
                var block = Block(left, y, width, MaskRowHeight, Palette.Annotation, title, item.Kind == AnnotationKind.Text ? null : Loc.T(item.Anchor == AnnotationAnchor.Screen ? "Pin to screen" : "Pin to frame"), item.Id == session.SelectedAnnotationId, item.Disabled || track.IsHidden);
                block.SubtitleTruncates = true;
                Follow(block, item.SourceStartMs, item.SourceEndMs);
                var id = item.Id;
                block.SplitAt = time => session.SplitAnnotation(id, session.Mapper.SourceTime(time).SourceMs);
                Draggable(block, width, id, () => session.SelectAnnotation(id), (start, end) =>
                {
                    session.UpdateAnnotation(id, current =>
                    {
                        current.ShiftTime(start - current.SourceStartMs);
                        current.SourceEndMs = end;
                    }, "annotation-drag");
                }, () =>
                {
                    var current = session.Annotation(id)!;
                    var siblings = session.Document.Timeline.AnnotationTracks.First(other => other.Items.Exists(entry => entry.Id == id)).Items.Where(entry => entry.Id != id).ToList();
                    var low = siblings.Where(entry => entry.SourceEndMs <= current.SourceStartMs + AnnotationTrack.OverlapToleranceMs).Select(entry => entry.SourceEndMs - AnnotationTrack.OverlapToleranceMs).DefaultIfEmpty(0).Max();
                    var high = siblings.Where(entry => entry.SourceStartMs >= current.SourceEndMs - AnnotationTrack.OverlapToleranceMs).Select(entry => entry.SourceStartMs + AnnotationTrack.OverlapToleranceMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                    return (current.SourceStartMs, current.SourceEndMs, low, high);
                },
                movedRows: rows =>
                {
                    var from = session.AnnotationTrackIndex(id);
                    if (from >= 0)
                    {
                        session.MoveAnnotationToTrack(id, from + rows);
                    }
                });
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    session.SelectAnnotation(id);
                    SegmentMenu.ForAnnotation(session, id, canvas, args.GetPosition(canvas));
                };
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    private double DrawMasks(double y)
    {
        foreach (var track in session.Document.Timeline.MaskTracks)
        {
            var trackId = track.Id;
            AddRowTarget(
                y,
                MaskRowHeight,
                GhostStyle.Of(Palette.Mask),
                () => (session.Document.Timeline.MaskTracks.Find(other => other.Id == trackId)?.Items ?? []).Select(item => session.Mapper.TimelineSpan(item.SourceStartMs, item.SourceEndMs)).OfType<(double Start, double End)>(),
                450,
                2800,
                300,
                (start, end) => session.AddMaskInRange(trackId, start, end));
            AddLabel(track.Name, y, MaskRowHeight, eye: true, track.IsHidden, () =>
                session.Mutate(document =>
                {
                    var target = document.Timeline.MaskTracks.First(other => other.Id == trackId);
                    target.IsHidden = !target.IsHidden;
                }),
                new DeletableTimelineTrack(DeletableTrackKind.Mask, trackId));
            foreach (var mask in track.Items)
            {
                var (left, width) = Place(mask.SourceStartMs, mask.SourceEndMs);
                var block = Block(
                    left,
                    y,
                    width,
                    MaskRowHeight,
                    Palette.Mask,
                    "Mask",
                    Loc.T(mask.Type == MaskType.Spotlight ? "Highlight" : "Sensitive data"),
                    mask.Id == session.SelectedMaskId,
                    mask.Disabled || track.IsHidden);
                block.SubtitleTruncates = true;
                Follow(block, mask.SourceStartMs, mask.SourceEndMs);
                var id = mask.Id;
                block.SplitAt = time => session.SplitMask(id, session.Mapper.SourceTime(time).SourceMs);
                Draggable(block, width, id, () => session.SelectMask(id), (start, end) =>
                {
                    session.Mutate(document =>
                    {
                        var item = document.Timeline.MaskTracks.SelectMany(other => other.Items).First(other => other.Id == id);
                        var shift = start - item.SourceStartMs;
                        item.SourceStartMs = start;
                        item.SourceEndMs = end;
                        foreach (var keyframe in item.Keyframes)
                        {
                            keyframe.SourceMs += shift;
                        }
                    }, structural: false);
                }, () =>
                {
                    var current = session.Document.Timeline.MaskTracks.SelectMany(other => other.Items).First(other => other.Id == id);
                    var siblings = session.Document.Timeline.MaskTracks.First(other => other.Items.Exists(item => item.Id == id)).Items.Where(item => item.Id != id).ToList();
                    var low = siblings.Where(item => item.SourceEndMs <= current.SourceStartMs).Select(item => item.SourceEndMs).DefaultIfEmpty(0).Max();
                    var high = siblings.Where(item => item.SourceStartMs >= current.SourceEndMs).Select(item => item.SourceStartMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                    return (current.SourceStartMs, current.SourceEndMs, low, high);
                },
                movedRows: rows =>
                {
                    var from = session.Document.Timeline.MaskTracks.FindIndex(other => other.Items.Exists(item => item.Id == id));
                    if (from >= 0)
                    {
                        session.MoveMaskToTrack(id, from + rows);
                    }
                });
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    SegmentMenu.ForMask(session, id, canvas, args.GetPosition(canvas));
                };
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    /// <summary>A shortcut's label is the keys, at 12 pt semibold and 96 % white, as on macOS (ShortcutTimelineSegmentView).</summary>
    private static void StyleShortcutLabel(BlockGrid block)
    {
        if (block.Title is { } title)
        {
            title.FontSize = 12;
            title.Foreground = new SolidColorBrush(Color.FromArgb(245, 255, 255, 255));
            block.FitLabels(animated: false);
        }
    }

    private double DrawShortcuts(double y)
    {
        var captions = session.Document.Captions;
        foreach (var track in captions.ShortcutTracks)
        {
            var trackId = track.Id;
            AddRowTarget(
                y,
                MaskRowHeight,
                GhostStyle.Of(Palette.Shortcut),
                () => session.Shortcuts().Where(item => item.TrackId == trackId).Select(item => session.Mapper.TimelineSpan(item.DisplayStartMs, item.DisplayEndMs)).OfType<(double Start, double End)>(),
                450,
                1800,
                300,
                (start, end) => session.AddCustomShortcut(trackId, start, end));
            var trackHidden = track.IsHidden || !captions.ShowKeystrokes;
            AddLabel(track.Name, y, MaskRowHeight, eye: true, trackHidden, () => session.ToggleShortcutTrackHidden(trackId), new DeletableTimelineTrack(DeletableTrackKind.Shortcut, trackId));
            var clusters = session.Shortcuts().Where(item => item.TrackId == track.Id).OrderBy(item => item.DisplayStartMs).ToList();
            foreach (var shortcut in clusters)
            {
                var (left, width) = Place(shortcut.DisplayStartMs, shortcut.DisplayEndMs);
                var shortcutSelected = shortcut.Id == session.SelectedShortcutId;
                var shortcutHidden = trackHidden || SegmentEdits.IsShortcutHidden(session.Document, shortcut);
                var block = Block(left, y, width, MaskRowHeight, Palette.Shortcut, shortcut.Label, null, shortcutSelected, shortcutHidden);
                StyleShortcutLabel(block);
                block.KindName = Loc.T("Shortcut");
                Follow(block, shortcut.DisplayStartMs, shortcut.DisplayEndMs);
                var pressed = shortcut;
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    SegmentMenu.ForShortcut(session, pressed, canvas, args.GetPosition(canvas));
                };
                var id = shortcut.Id;
                Draggable(block, width, id, () => session.SelectShortcut(id), (start, end) =>
                {
                    var current = session.Shortcuts().FirstOrDefault(item => item.Id == id);
                    if (current is not null)
                    {
                        session.Mutate(document => TimelineEdits.SetShortcutRange(document, current, start, end), structural: false);
                    }
                }, () =>
                {
                    var current = session.Shortcuts().First(item => item.Id == id);
                    var others = session.Shortcuts().Where(item => item.TrackId == current.TrackId && item.Id != id).ToList();
                    var low = others.Where(item => item.DisplayEndMs <= current.DisplayStartMs).Select(item => item.DisplayEndMs).DefaultIfEmpty(0).Max();
                    var high = others.Where(item => item.DisplayStartMs >= current.DisplayEndMs).Select(item => item.DisplayStartMs).DefaultIfEmpty(session.SourceDurationMs).Min();
                    return (current.DisplayStartMs, current.DisplayEndMs, low, high);
                },
                keycapHandles: true);
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    private double DrawCaptions(double y)
    {
        var captions = session.Document.Captions;
        var words = CaptionLineLayout.WordsById(captions);
        for (var index = 0; index < captions.CaptionTracks.Count; index++)
        {
            var track = captions.CaptionTracks[index];
            var trackId = track.Id;
            var hidden = track.IsHidden || !captions.Enabled;
            AddRowTarget(
                y,
                MaskRowHeight,
                GhostStyle.Of(Palette.Caption),
                () => session.Document.Captions.CaptionBlocks.Where(item => item.TrackId == trackId).Select(item => session.Mapper.TimelineSpan(item.SourceStartMs, item.SourceEndMs)).OfType<(double Start, double End)>(),
                450,
                2000,
                300,
                (start, end) => session.AddCaption(trackId, start, end),
                marginPoints: 6);
            AddLabel(track.Name, y, MaskRowHeight, eye: true, hidden, () => session.ToggleCaptionTrackHidden(trackId), new DeletableTimelineTrack(DeletableTrackKind.Caption, trackId));
            foreach (var item in captions.CaptionBlocks.Where(item => item.TrackId == trackId))
            {
                var (left, width) = Place(item.SourceStartMs, item.SourceEndMs);
                var block = Block(left, y, width, MaskRowHeight, Palette.Caption, "Caption", CaptionLineLayout.DisplayText(item, words), item.Id == session.SelectedCaptionId, hidden);
                block.SubtitleTruncates = true;
                Follow(block, item.SourceStartMs, item.SourceEndMs);
                var id = item.Id;
                block.SplitAt = time => session.SplitCaption(id, session.Mapper.SourceTime(time).SourceMs);
                Draggable(block, width, id, () => session.SelectCaption(id), (start, end) =>
                {
                    session.Mutate(document =>
                    {
                        if (document.Captions.CaptionBlocks.Find(other => other.Id == id) is { } target)
                        {
                            target.SourceStartMs = start;
                            target.SourceEndMs = Math.Max(start + EditorSession.MinimumCaptionMs, end);
                        }
                    }, structural: false);
                }, () =>
                {
                    var current = session.Document.Captions.CaptionBlocks.First(other => other.Id == id);
                    var (low, high) = session.CaptionNeighborBounds(id, current.TrackId, current.SourceStartMs);
                    return (current.SourceStartMs, current.SourceEndMs, low, high);
                },
                movedRows: rows =>
                {
                    var captionsNow = session.Document.Captions;
                    var currentTrack = captionsNow.CaptionBlocks.Find(other => other.Id == id)?.TrackId;
                    var from = captionsNow.CaptionTracks.FindIndex(other => other.Id == currentTrack);
                    if (from >= 0)
                    {
                        session.MoveCaptionToTrack(id, from + rows);
                    }
                });
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    session.SelectCaption(id);
                    SegmentMenu.ForCaption(session, id, trackId, canvas, args.GetPosition(canvas));
                };
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    private static string LayoutTitle(CameraTimelineLayoutType type) => type switch
    {
        CameraTimelineLayoutType.SplitScreen => "Split screen",
        CameraTimelineLayoutType.CutoutCamera => "Camera cutout",
        CameraTimelineLayoutType.FullscreenCamera => "Fullscreen camera",
        CameraTimelineLayoutType.ScreenOnly => "Only screen",
        _ => "Camera overlay"
    };

    /// <summary>
    /// Hovering an empty part of a row shows a ghost of the block a click would add, centered on the pointer and fitted to the
    /// free gap. Blocks are drawn over the row, so it only hears the pointer where nothing is.
    /// </summary>
    private void AddRowTarget(
        double y,
        double height,
        GhostStyle style,
        Func<IEnumerable<(double Start, double End)>> occupied,
        double minimumGapMs,
        double desiredMs,
        double minimumSourceMs,
        Action<double, double> add,
        bool seekToMiddle = true,
        string? prompt = null,
        double marginPoints = 4)
    {
        var row = new Border { Width = TrackWidth, Height = height, Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)) };
        fullWidthRows.Add(row);
        var plus = Ui.Icon("\uE710", style.IconSize, Ui.Pal("Ink95"));
        plus.HorizontalAlignment = HorizontalAlignment.Center;
        plus.VerticalAlignment = VerticalAlignment.Center;
        plus.IsHitTestVisible = false;
        var ghost = new Border
        {
            Height = height,
            CornerRadius = new CornerRadius(style.Radius),
            Background = Ui.Gradient(style.Top, style.Bottom),
            BorderBrush = new SolidColorBrush(style.Ring),
            BorderThickness = new Thickness(1),
            IsHitTestVisible = false,
            Opacity = 0,
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(120) },
            Child = plus
        };
        Canvas.SetLeft(row, TrackInset);
        Canvas.SetTop(row, y);
        Canvas.SetTop(ghost, y);
        Border? promptBox = null;
        if (prompt is not null)
        {
            var text = Ui.Text(prompt, 12, "Ink45");
            text.HorizontalAlignment = HorizontalAlignment.Center;
            text.TextWrapping = TextWrapping.NoWrap;
            promptBox = new Border
            {
                Width = TrackWidth,
                Height = height,
                CornerRadius = new CornerRadius(10),
                Background = new SolidColorBrush(Color.FromArgb(20, 77, 47, 245)),
                IsHitTestVisible = false,
                Child = text
            };
            Canvas.SetLeft(promptBox, TrackInset);
            fullWidthRows.Add(promptBox);
            Canvas.SetTop(promptBox, y);
        }

        (double Start, double End, double SourceStart, double SourceEnd)? preview = null;
        void Hide()
        {
            preview = null;
            ghost.Opacity = 0;
            if (promptBox is not null)
            {
                promptBox.Visibility = Visibility.Visible;
            }
        }

        row.PointerMoved += (_, args) =>
        {
            preview = null;
            if (drag is null && !scrubbing && !session.IsSplitModeActive
                && TimelineAddPreview.Span(TimeAt(args.GetCurrentPoint(canvas).Position.X), occupied(), session.DurationMs, marginPoints / TrackWidth * session.DurationMs, minimumGapMs, desiredMs) is { } span)
            {
                var sourceStart = session.Mapper.SourceTime(span.Start).SourceMs;
                var sourceEnd = session.Mapper.SourceTime(span.End).SourceMs;
                if (sourceEnd - sourceStart >= minimumSourceMs)
                {
                    preview = (span.Start, span.End, sourceStart, sourceEnd);
                }
            }

            if (preview is { } shown)
            {
                Canvas.SetLeft(ghost, X(shown.Start));
                ghost.Width = Math.Max(24, X(shown.End) - X(shown.Start));
                ghost.Opacity = 1;
                if (promptBox is not null)
                {
                    promptBox.Visibility = Visibility.Collapsed;
                }
            }
            else
            {
                Hide();
            }
        };
        row.PointerExited += (_, _) => Hide();
        row.PointerPressed += (_, args) =>
        {
            // Without a ghost, as in split mode or in a gap too small for a block, the press only moves the playhead.
            if (preview is not { } chosen)
            {
                return;
            }

            args.Handled = true;
            Hide();
            if (seekToMiddle)
            {
                session.Scrub((chosen.Start + chosen.End) * 0.5);
                UpdatePlayhead();
                PlayheadScrubbed?.Invoke();
            }

            add(chosen.SourceStart, chosen.SourceEnd);
        };
        if (promptBox is not null)
        {
            canvas.Children.Add(promptBox);
        }

        canvas.Children.Add(row);
        canvas.Children.Add(ghost);
    }

    /// <summary>
    /// A track's label. Right-click shows Hide Track / Show Track and, for tracks that can go, Delete Track (spec/06 ADR-50).
    /// </summary>
    private void AddLabel(string title, double y, double height, bool eye, bool hidden = false, Action? toggle = null, DeletableTimelineTrack? delete = null)
    {
        title = Loc.TrackName(title);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, Height = height, Padding = new Thickness(12, 0, 0, 0) };
        if (eye)
        {
            var button = Ui.IconButton(Ui.Icon(hidden ? "" : "", 12, Ui.Pal(hidden ? "Ink28" : "Ink60")), hidden ? "Show track" : "Hide track", toggle, 22);
            button.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(button);
        }

        var label = Ui.Text(title, 12.5, hidden ? "Ink28" : "Ink60");
        label.TextWrapping = TextWrapping.NoWrap;
        row.Children.Add(label);
        if (eye && toggle is not null || delete is not null)
        {
            // Covers the whole label column, so a right-click anywhere on the row opens the menu.
            row.Width = LabelColumnWidth;
            row.Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0));
            var name = title;
            row.RightTapped += (_, args) =>
            {
                args.Handled = true;
                var menu = new MenuFlyout();
                if (eye && toggle is not null)
                {
                    var visibility = new MenuFlyoutItem { Text = Loc.T(hidden ? "Show Track" : "Hide Track") };
                    visibility.Click += (_, _) => toggle();
                    menu.Items.Add(visibility);
                }

                if (delete is { } track)
                {
                    if (menu.Items.Count > 0)
                    {
                        menu.Items.Add(new MenuFlyoutSeparator());
                    }

                    var remove = new MenuFlyoutItem { Text = Loc.T("Delete Track"), Foreground = Ui.Rgb(1, 0.35, 0.35) };
                    remove.Click += (_, _) =>
                    {
                        if (session.DeleteTimelineTrack(track))
                        {
                            Toast?.Invoke(Loc.F("Deleted %@. Press Ctrl+Z to undo.", name));
                        }
                    };
                    menu.Items.Add(remove);
                }

                menu.ShowAt(row, args.GetPosition(row));
            };
        }

        Canvas.SetTop(row, y);
        labels.Children.Add(row);
    }

    private BlockGrid Block(double x, double y, double width, double height, Palette palette, string title, string? subtitle, bool selected, bool dimmed)
    {
        title = Loc.T(title);
        var block = new BlockGrid
        {
            Width = Math.Max(6, width),
            Height = height,
            CornerRadius = new CornerRadius(height >= 40 ? 9 : 7),
            Background = Ui.Gradient(palette.Top, palette.Bottom),
            BorderBrush = new SolidColorBrush(palette.Ring),
            BorderThickness = new Thickness(1),
            Opacity = dimmed ? 0.35 : 1
        };
        if (selected)
        {
            // Selection is a 1 px outline 1.5 px outside the block, as on macOS. A rounded panel clips its children, so the
            // outline is the block's sibling on the canvas and follows its place and size.
            block.Outline = new Border
            {
                CornerRadius = new CornerRadius(block.CornerRadius.TopLeft + 2.5),
                BorderBrush = new SolidColorBrush(palette.Selected),
                BorderThickness = new Thickness(1),
                IsHitTestVisible = false
            };
        }

        // Both lines are centered and offset by Translation, so a label that collapses moves without a layout pass.
        var text = new Grid { Margin = new Thickness(BlockGrid.LabelInset - 1, 0, BlockGrid.LabelInset - 1, 0), IsHitTestVisible = false };
        text.Children.Add(block.Title = new TextBlock
        {
            Text = title,
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromArgb(140, 255, 255, 255)),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1
        });
        if (subtitle is not null)
        {
            text.Children.Add(block.Subtitle = new TextBlock
            {
                Text = subtitle,
                FontSize = 11.5,
                FontWeight = FontWeights.Medium,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = new SolidColorBrush(Colors.White),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
                Translation = new System.Numerics.Vector3(0, (float)BlockGrid.LineOffset, 0)
            });
        }

        block.Children.Add(text);
        block.FitLabels(animated: false);
        block.IsSelectedBlock = selected;
        block.AccessibleName = () =>
        {
            var parts = new List<string> { block.KindName ?? title };
            var shown = block.Subtitle?.Text ?? subtitle;
            if (shown is { Length: > 0 })
            {
                parts.AddRange(shown.Split('·', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            }

            if (block.KindName is not null && title.Length > 0)
            {
                parts.Insert(1, title);
            }

            if (dimmed)
            {
                parts.Add(Loc.T("Disabled"));
            }

            return string.Join(", ", parts);
        };
        block.AccessibleRange = () =>
        {
            var left = Canvas.GetLeft(block);
            return A11y.Range(TimeAtUnclamped(left), TimeAtUnclamped(left + block.Width));
        };
        Canvas.SetLeft(block, x);
        Canvas.SetTop(block, y);
        canvas.Children.Add(block);
        ElementCompositionPreview.SetIsTranslationEnabled(block, true);
        if (block.Outline is { } outline)
        {
            canvas.Children.Add(outline);
            void Follow()
            {
                if (block.Outline is null)
                {
                    return;
                }

                Canvas.SetLeft(outline, Canvas.GetLeft(block) - 2.5);
                Canvas.SetTop(outline, Canvas.GetTop(block) - 2.5);
                outline.Width = block.Width + 5;
                outline.Height = block.Height + 5;
            }

            Follow();
            block.SizeChanged += (_, _) => Follow();
            block.LayoutUpdated += (_, _) => Follow();
        }
        var row = blockRows.IndexOf(y);
        if (row < 0)
        {
            row = blockRows.Count;
            blockRows.Add(y);
        }

        wigglingBlocks.Add((block, row));
        if (block.Outline is { } ring)
        {
            ElementCompositionPreview.SetIsTranslationEnabled(ring, true);
            wigglingBlocks.Add((ring, row));
        }
        return block;
    }

    private void Draggable(
        BlockGrid block,
        double width,
        string? snapId,
        Action select,
        Action<double, double> apply,
        Func<(double Start, double End, double Low, double High)> bounds,
        bool canMove = true,
        Action<int>? movedRows = null,
        bool resizable = true,
        bool keycapHandles = false,
        double minimumMs = MinBlockMs,
        Func<double>? startEdgeLow = null)
    {
        // Even the narrowest block keeps a part in the middle to move it by. Read at each event: a zoom step widens the block.
        double EdgeWidth() => Math.Min(EdgeHitWidth, Math.Max(5.5, block.Width * 0.34));
        var handles = resizable ? AddHandles(block, width, keycapHandles) : null;
        if (handles is not null)
        {
            block.PointerEntered += (_, _) =>
            {
                hoveredHandles = handles;
                ShowHandles(handles, !session.IsSplitModeActive);
            };
            block.PointerExited += (_, _) =>
            {
                // A resize keeps its handles when the pointer runs ahead of the block.
                if (drag?.Block != block)
                {
                    hoveredHandles = null;
                    ShowHandles(handles, false);
                }
            };
        }

        block.Invoked = () =>
        {
            if (session.IsSplitModeActive && block.SplitAt is { } splitAt)
            {
                splitAt(TimeAtUnclamped(Canvas.GetLeft(block) + block.Width / 2));
            }
            else
            {
                select();
            }
        };
        block.PointerEntered += (_, _) => hoveredBlock = block;
        block.PointerExited += (_, _) => hoveredBlock = hoveredBlock == block ? null : hoveredBlock;

        block.PointerMoved += (_, args) =>
        {
            if (drag is null)
            {
                var x = args.GetCurrentPoint(block).Position.X;
                var edge = x < EdgeWidth() || x > block.Width - EdgeWidth();
                block.SetCursor(session.IsSplitModeActive ? InputSystemCursorShape.Cross : edge ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.Arrow);
            }
        };
        block.PointerPressed += (_, args) =>
        {
            if (!args.GetCurrentPoint(block).Properties.IsLeftButtonPressed)
            {
                return;
            }

            if (session.IsSplitModeActive)
            {
                args.Handled = true;
                if (block.SplitAt is { } split)
                {
                    var time = TimeAt(args.GetCurrentPoint(canvas).Position.X);
                    EndSkim();
                    session.Scrub(time);
                    split(time);
                    UpdatePlayhead();
                    PlayheadScrubbed?.Invoke();
                }
                else
                {
                    select();
                }

                return;
            }

            // Selecting rebuilds every block, so it waits for release; a rebuild mid-press would cancel the drag.
            var x = args.GetCurrentPoint(block).Position.X;
            var mode = x < EdgeWidth() ? DragMode.Start : x > block.Width - EdgeWidth() ? DragMode.End : canMove ? DragMode.Move : DragMode.None;
            var (start, end, low, high) = bounds();
            if (mode == DragMode.Start && startEdgeLow is not null)
            {
                low = Math.Max(low, startEdgeLow());
            }

            session.BeginInteractiveEdit();
            var press = args.GetCurrentPoint(canvas).Position;
            drag = new Drag(block, press.X, press.Y, Canvas.GetTop(block), mode, start, end, low, high, apply, select, movedRows, snapId, minimumMs);
            if (snapId is not null && AppSettings.Shared.SnapToSegments && mode != DragMode.None)
            {
                snap.Begin(TimelineSnapTargets.Collect(session, snapId), TrackWidth / session.TimelineScaleDurationMs);
            }
            else
            {
                snap.End();
            }
            canvas.CapturePointer(args.Pointer);
            args.Handled = true;
        };
    }

    /// <summary>White bars inside both ends of a block, shown while it is hovered or being resized.</summary>
    private static Grid? AddHandles(BlockGrid block, double width, bool keycap)
    {
        if (width < 10)
        {
            return null;
        }

        var barWidth = keycap ? (width < 24 ? 2.2 : 3.0) : (width < 24 ? 2.4 : 3.0);
        var inset = keycap
            ? Math.Min(5, Math.Max(2, (width - barWidth * 2 - 3) * 0.5))
            : Math.Min(6.5, Math.Max(2.2, (width - barWidth * 2 - 3.5) * 0.5));
        var barHeight = Math.Max(8, block.Height - (keycap ? 14 : 18));
        var fill = new SolidColorBrush(Color.FromArgb((byte)(keycap ? 224 : 242), 255, 255, 255));
        Border Bar(HorizontalAlignment side) => new()
        {
            Width = barWidth,
            Height = barHeight,
            CornerRadius = new CornerRadius(barWidth / 2),
            Background = fill,
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = side == HorizontalAlignment.Left ? new Thickness(inset, 0, 0, 0) : new Thickness(0, 0, inset, 0),
            CenterPoint = new System.Numerics.Vector3((float)barWidth / 2, (float)barHeight / 2, 0),
            Scale = new System.Numerics.Vector3(1, HandleRestScale, 1),
            ScaleTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(160) }
        };

        var handles = new Grid { IsHitTestVisible = false, Opacity = 0, OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(160) } };
        handles.Children.Add(Bar(HorizontalAlignment.Left));
        handles.Children.Add(Bar(HorizontalAlignment.Right));
        block.Children.Add(handles);
        return handles;
    }

    /// <summary>The bars fade and grow together, whether a pointer arrived or split mode ended.</summary>
    private static void ShowHandles(Grid handles, bool show)
    {
        handles.Opacity = show ? 1 : 0;
        foreach (var bar in handles.Children)
        {
            bar.Scale = new System.Numerics.Vector3(1, show ? 1 : HandleRestScale, 1);
        }
    }

    private void CanvasPressed(object sender, PointerRoutedEventArgs args)
    {
        if (!args.GetCurrentPoint(canvas).Properties.IsLeftButtonPressed)
        {
            return;
        }

        EndSkim();
        // The ruler only moves the playhead; a click on the tracks also leaves whatever is selected.
        if (ReferenceEquals(sender, canvas))
        {
            session.ClearSelection();
        }

        scrubbing = true;
        ((UIElement)sender).CapturePointer(args.Pointer);
        session.Scrub(TimeAt(args.GetCurrentPoint(canvas).Position.X));
        UpdatePlayhead();
        PlayheadScrubbed?.Invoke();
    }

    private void EndSkim()
    {
        var changed = session.SetHoverSkim(null);
        UpdatePlayhead();
        if (changed)
        {
            Skimmed?.Invoke();
        }
    }

    /// <summary>Crossing between the ruler and the tracks is still skimming; dropping it there would seek back and forth.</summary>
    private void PointerLeft(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(root).Position;
        var inColumn = point.X > LabelColumnWidth && point.X < root.ActualWidth;
        var intoOther = ReferenceEquals(sender, canvas)
            ? point.Y >= 0 && point.Y < RulerHeight
            : point.Y >= RulerHeight && point.Y < root.ActualHeight;
        if (!inColumn || !intoOther)
        {
            EndSkim();
        }
    }

    private void Skim(double x)
    {
        if (session.IsPlaying || session.PendingAddMaskType is not null)
        {
            EndSkim();
            return;
        }

        if (IsZooming)
        {
            return;
        }

        var changed = session.SetHoverSkim(TimeAt(x));
        UpdatePlayhead();
        if (changed)
        {
            Skimmed?.Invoke();
        }
    }

    private void CanvasMoved(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(canvas).Position;
        var x = point.X;
        if (drag is { } active)
        {
            if (active.MovedRows is not null && active.Mode == DragMode.Move)
            {
                // A mask follows the pointer up and down, between tracks; the drop decides the row.
                Canvas.SetTop(active.Block, active.BlockY + point.Y - active.PressY);
                Canvas.SetZIndex(active.Block, 10);
            }

            if (active.Mode == DragMode.None)
            {
                return;
            }

            var delta = (x - active.PressX) / TrackWidth * session.TimelineScaleDurationMs;
            double start = active.Start;
            double end = active.End;
            // Edges snap in timeline time (spec/06 ADR-43); the usual clamps then still apply.
            switch (active.Mode)
            {
                case DragMode.Move:
                    var length = active.End - active.Start;
                    var movedStart = active.Start + delta;
                    if (active.SnapId is not null)
                    {
                        var timelineStart = TimelineOf(movedStart);
                        var snapped = snap.SnapMove(timelineStart, TimelineOf(movedStart + length) - timelineStart);
                        movedStart = SourceAfterShift(movedStart, snapped - timelineStart);
                    }

                    start = Math.Clamp(movedStart, active.Low, active.High - length);
                    end = start + length;
                    break;
                case DragMode.Start:
                    var trimmedStart = active.Start + delta;
                    if (active.SnapId is not null)
                    {
                        var timelineStart = TimelineOf(trimmedStart);
                        trimmedStart = SourceAfterShift(trimmedStart, snap.SnapEdge(timelineStart) - timelineStart);
                    }

                    start = Math.Clamp(trimmedStart, active.Low, active.End - active.MinimumMs);
                    break;
                case DragMode.End:
                    var trimmedEnd = active.End + delta;
                    if (active.SnapId is not null)
                    {
                        var timelineEnd = TimelineOf(trimmedEnd);
                        trimmedEnd = SourceAfterShift(trimmedEnd, snap.SnapEdge(timelineEnd) - timelineEnd);
                    }

                    end = Math.Clamp(trimmedEnd, active.Start + active.MinimumMs, active.High);
                    break;
            }

            ShowSnapGuide();
            active.Apply(start, end);
            if (clipOwners.Contains(active.Block))
            {
                FollowClipEdit(active.Block);
            }
            else
            {
                var left = X(TimelineOf(start));
                Canvas.SetLeft(active.Block, left);
                active.Block.Width = Math.Max(6, X(TimelineOf(end)) - left);
                FollowVoiceoverWave(active.Block);
            }

            UpdatePlayhead();
        }
        else if (scrubbing)
        {
            session.Scrub(TimeAt(x));
            UpdatePlayhead();
            PlayheadScrubbed?.Invoke();
        }
        else
        {
            Skim(x);
        }
    }

    // A trim shows a different part of the same samples, so it is right while dragging and after undo with no new read.
    private void FollowVoiceoverWave(BlockGrid block)
    {
        if (!voiceoverWaveIds.TryGetValue(block, out var id) || session.Document.Timeline.Voiceovers.Find(item => item.Id == id) is not { } voiceover)
        {
            return;
        }

        foreach (var wave in waveImages)
        {
            if (wave.Owner == block)
            {
                (wave.Start, wave.End) = VoiceoverWaveRange(voiceover);
                wave.Width = block.Width - block.BorderThickness.Left * 2;
                UpdateWave(wave);
            }
        }
    }

    private void CanvasReleased(object sender, PointerRoutedEventArgs args)
    {
        var y = args.GetCurrentPoint(canvas).Position.Y;
        // Releasing raises PointerCaptureLost at once, which would end the drag without a drop row.
        EndDrag(y);
        ((UIElement)sender).ReleasePointerCapture(args.Pointer);
    }

    private void EndDrag(double? y = null)
    {
        scrubbing = false;
        snap.End();
        ShowSnapGuide();
        if (drag is { } finished)
        {
            drag = null;
            session.EndInteractiveEdit();
            var rows = y is { } dropY ? (int)Math.Round((dropY - finished.PressY) / (MaskRowHeight + RowSpacing)) : 0;
            finished.Select();
            if (rows != 0 && finished.Mode == DragMode.Move)
            {
                finished.MovedRows?.Invoke(rows);
            }
        }
    }

    private enum DragMode
    {
        None,
        Move,
        Start,
        End
    }

    private sealed record Drag(BlockGrid Block, double PressX, double PressY, double BlockY, DragMode Mode, double Start, double End, double Low, double High, Action<double, double> Apply, Action Select, Action<int>? MovedRows, string? SnapId, double MinimumMs);

    /// <summary>A source time moved by a timeline distance, at the speed of the slice it lands in.</summary>
    private double SourceAfterShift(double sourceMs, double timelineShiftMs)
    {
        if (Math.Abs(timelineShiftMs) < 1e-9)
        {
            return sourceMs;
        }

        var target = TimelineOf(sourceMs) + timelineShiftMs;
        var (mapped, slice) = session.Mapper.SourceTime(Math.Clamp(target, 0, session.Mapper.TotalTimelineDurationMs));
        return slice is null ? sourceMs + timelineShiftMs : mapped;
    }

    /// <summary>The 1 px purple line at the edge a dragged item snapped to.</summary>
    private void ShowSnapGuide()
    {
        if (snap.GuideTimelineMs is { } guide)
        {
            snapGuide.Height = Math.Max(0, root.ActualHeight - RulerHeight);
            Canvas.SetLeft(snapGuide, Math.Round(X(guide) - scroller.HorizontalOffset - 0.5));
            Canvas.SetTop(snapGuide, RulerHeight);
            snapGuide.Visibility = Visibility.Visible;
        }
        else
        {
            snapGuide.Visibility = Visibility.Collapsed;
        }
    }

    private sealed class TrimBadgeView(Button button, TextBlock label, FontIcon icon)
    {
        public Button Button { get; } = button;
        public TextBlock Label { get; } = label;
        public FontIcon Icon { get; } = icon;
        public Action? Click { get; set; }
        public string? Tooltip { get; set; }
    }

    private sealed class WaveImage(BlockGrid owner, Image image, string cacheId, Func<List<WaveformRasterLayer>> layers, double start, double end, double width, double height, double radius)
    {
        public BlockGrid Owner { get; } = owner;
        public Image Image { get; } = image;
        public string CacheId { get; } = cacheId;
        public Func<List<WaveformRasterLayer>> Layers { get; } = layers;
        public double Start { get; set; } = start;
        public double End { get; set; } = end;
        public double Width { get; set; } = width;
        public double Height { get; } = height;
        public double Radius { get; } = radius;
    }

    /// <summary>The last bitmap of a slice or voiceover, kept across rebuilds so a zoom can show it stretched.</summary>
    private sealed record WaveCache(string Key, int WidthPx, WriteableBitmap? Bitmap);

    private sealed record Palette(Color Top, Color Bottom, Color Ring, Color Selected)
    {

        private static Color C(double r, double g, double b, double a = 1) =>
            Color.FromArgb((byte)Math.Round(a * 255), (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

        // Light theme: brighter, more saturated fills, as on macOS.
        private static readonly Palette ClipLight = new(C(0.851, 0.533, 0.098), C(0.937, 0.663, 0.231), C(1, 0.875, 0.655), C(0.925, 0.58, 0.1, 0.85));
        private static readonly Palette ZoomLight = new(C(0.388, 0.29, 0.973), C(0.596, 0.533, 0.984), C(0.902, 0.882, 1), C(0.553, 0.471, 0.976, 0.85));
        private static readonly Palette MaskLight = new(C(0.733, 0.31, 0.522), C(0.851, 0.475, 0.663), C(0.98, 0.82, 0.898), C(0.8, 0.38, 0.6, 0.85));
        private static readonly Palette CaptionLight = new(C(0.106, 0.561, 0.616), C(0.231, 0.722, 0.773), C(0.7, 0.941, 0.969), C(0.18, 0.69, 0.757, 0.85));
        private static readonly Palette LayoutLight = new(C(0.533, 0.478, 0.51), C(0.69, 0.643, 0.667), C(0.918, 0.89, 0.906), C(0.62, 0.561, 0.6, 0.85));
        private static readonly Palette ShortcutLight = new(C(0.18, 0.62, 0.416), C(0.31, 0.765, 0.553), C(0.76, 0.957, 0.863), C(0.22, 0.7, 0.47, 0.85));
        private static readonly Palette AnnotationLight = new(C(0.894, 0.42, 0.29), C(0.957, 0.565, 0.447), C(1, 0.86, 0.81), C(0.92, 0.47, 0.33, 0.85));

        private static bool IsLight => AppTheme.Current == ElementTheme.Light;

        public static Palette Clip => IsLight ? ClipLight : ClipDark;
        public static Palette Zoom => IsLight ? ZoomLight : ZoomDark;
        public static Palette Mask => IsLight ? MaskLight : MaskDark;
        public static Palette Caption => IsLight ? CaptionLight : CaptionDark;
        public static Palette Layout => IsLight ? LayoutLight : LayoutDark;
        public static Palette Annotation => IsLight ? AnnotationLight : AnnotationDark;
        public static Palette Shortcut => IsLight ? ShortcutLight : ShortcutDark;

        private static readonly Palette ClipDark = new(Color.FromArgb(255, 147, 97, 12), Color.FromArgb(255, 218, 144, 18), Color.FromArgb(255, 244, 198, 119), C(0.925, 0.62, 0.094, 0.8));
        private static readonly Palette ZoomDark = new(Color.FromArgb(255, 77, 47, 245), Color.FromArgb(255, 139, 120, 249), Color.FromArgb(255, 244, 242, 254), C(0.627, 0.569, 0.98, 0.8));
        private static readonly Palette MaskDark = new(Color.FromArgb(255, 130, 52, 90), Color.FromArgb(255, 183, 75, 128), Color.FromArgb(255, 220, 166, 192), C(0.776, 0.365, 0.569, 0.8));
        private static readonly Palette CaptionDark = new(Color.FromArgb(255, 22, 99, 110), Color.FromArgb(255, 31, 143, 158), Color.FromArgb(255, 153, 222, 231), C(0.176, 0.69, 0.757, 0.8));
        private static readonly Palette LayoutDark = new(Color.FromArgb(255, 101, 87, 94), Color.FromArgb(255, 141, 124, 132), Color.FromArgb(255, 209, 200, 205), C(0.66, 0.596, 0.627, 0.8));
        private static readonly Palette ShortcutDark = new(C(0.11, 0.42, 0.278), C(0.165, 0.6, 0.4), C(0.6, 0.906, 0.761), C(0.2, 0.7, 0.47, 0.8));
        private static readonly Palette AnnotationDark = new(C(0.651, 0.259, 0.165), C(0.851, 0.38, 0.255), C(0.98, 0.78, 0.72), C(0.9, 0.45, 0.32, 0.8));
    }

    /// <summary>A ghost in the colors of the row's blocks.</summary>
    private sealed record GhostStyle(Color Top, Color Bottom, Color Ring, double Radius, double IconSize)
    {
        public static GhostStyle Of(Palette palette) => new(palette.Top, palette.Bottom, Color.FromArgb(184, palette.Ring.R, palette.Ring.G, palette.Ring.B), 10, 15);
    }

    private static class Colors
    {
        public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
    }

    /// <summary>A teardrop on a stem that starts exactly at its tip, so a translucent mark shows no brighter overlap and nothing sticks out above the head.</summary>
    private sealed partial class PlayheadMark : Canvas
    {
        public const double TopY = 1.5;
        private const double TipY = 17.49;

        private readonly TranslateTransform offset = new();
        private readonly TranslateTransform headOffset = new() { X = -9 };
        private readonly TranslateTransform stemOffset = new() { X = -0.75 };
        private readonly Rectangle stem = new() { Width = 1.5 };

        public PlayheadMark(Color head, Color stemColor)
        {
            IsHitTestVisible = false;
            RenderTransform = offset;
            stem.Fill = new SolidColorBrush(stemColor);
            stem.RenderTransform = stemOffset;
            Children.Add(stem);
            var shape = Ui.Shape("M3.594,10.386 A6.6,6.6 0 1 1 14.406,10.386 L9,17.49 Z", 18, new SolidColorBrush(head));
            shape.Stretch = Stretch.None;
            shape.RenderTransform = headOffset;
            Children.Add(shape);
        }

        public void Place(double x, double headTop, double totalHeight)
        {
            offset.X = x;
            headOffset.Y = headTop;
            var tip = headTop + TipY;
            stemOffset.Y = tip;
            var height = Math.Max(10, totalHeight - tip);
            if (double.IsNaN(stem.Height) || Math.Abs(stem.Height - height) > 0.25)
            {
                stem.Height = height;
            }
        }

        public void SetStem(Brush brush)
        {
            if (!ReferenceEquals(stem.Fill, brush))
            {
                stem.Fill = brush;
            }
        }
    }

    // UIElement.ProtectedCursor is only reachable from a subclass.
    private sealed partial class BlockGrid : Grid
    {
        /// <summary>What a click does in split mode, given the timeline time. Null for what cannot be cut.</summary>
        public Action<double>? SplitAt { get; set; }

        public const double LabelInset = 16;
        public const double LineOffset = 7.5;

        /// <summary>Every label fits at this width, so wide blocks skip measuring text: a project can have hundreds of captions.</summary>
        private const double AlwaysFitsWidth = 220;

        /// <summary>Text that can be cut off (captions, mask names) is still worth showing with this much room.</summary>
        private const double ShortestTruncatedWidth = 96;

        private static readonly TimeSpan LabelFade = TimeSpan.FromMilliseconds(180);

        [ThreadStatic]
        private static TextBlock? measuring;

        private bool? showsTitle;
        private bool? showsSubtitle;
        private bool subtitleTruncates;

        public BlockGrid()
        {
            SizeChanged += (_, _) => FitLabels(animated: true);
        }

        public TextBlock? Title { get; set; }

        public TextBlock? Subtitle { get; set; }

        /// <summary>The selection outline outside the block, when selected.</summary>
        public Border? Outline { get; set; }

        public bool SubtitleTruncates
        {
            get => subtitleTruncates;
            set
            {
                subtitleTruncates = value;
                FitLabels(animated: false);
            }
        }

        /// <summary>The details go first and the title slides to the middle, then the title goes too, judged by measured text.</summary>
        public void FitLabels(bool animated)
        {
            if (Title is not { } title)
            {
                return;
            }

            var room = Width - LabelInset * 2;
            var showTitle = room >= AlwaysFitsWidth || room >= Measure(title);
            var showSubtitle = showTitle && Subtitle is { } line
                && (room >= AlwaysFitsWidth || room >= (SubtitleTruncates ? Math.Min(Measure(line), ShortestTruncatedWidth) : Measure(line)));
            if (showTitle == showsTitle && showSubtitle == showsSubtitle)
            {
                return;
            }

            if (animated)
            {
                SetTransitions(A11y.ReduceMotion ? null : new ScalarTransition { Duration = LabelFade }, A11y.ReduceMotion ? null : new Vector3Transition { Duration = LabelFade });
            }

            showsTitle = showTitle;
            showsSubtitle = showSubtitle;
            title.Opacity = showTitle ? 1 : 0;
            title.Translation = new System.Numerics.Vector3(0, showSubtitle ? (float)-LineOffset : 0, 0);
            if (Subtitle is { } details)
            {
                details.Opacity = showSubtitle ? 1 : 0;
            }
        }

        private void SetTransitions(ScalarTransition? fade, Vector3Transition? slide)
        {
            Title!.OpacityTransition = fade;
            Title.TranslationTransition = slide;
            if (Subtitle is { } details)
            {
                details.OpacityTransition = fade is null ? null : new ScalarTransition { Duration = LabelFade };
            }
        }

        private static double Measure(TextBlock text)
        {
            var probe = measuring ??= new TextBlock();
            probe.FontSize = text.FontSize;
            probe.FontWeight = text.FontWeight;
            probe.Text = text.Text;
            probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            return Math.Ceiling(probe.DesiredSize.Width);
        }

        /// <summary>Read before the title when the title alone does not say what the block is ("Shortcut").</summary>
        public string? KindName { get; set; }

        public Func<string>? AccessibleName { get; set; }

        public Func<string>? AccessibleRange { get; set; }

        /// <summary>What Invoke does for a screen reader: the same as a click in the block's middle.</summary>
        public Action? Invoked { get; set; }

        public bool IsSelectedBlock { get; set; }

        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);

        protected override AutomationPeer OnCreateAutomationPeer() => new BlockPeer(this);
    }

    /// <summary>One element per segment: its kind and content, its time range, selected, and Invoke (spec/06 ADR-51).</summary>
    private sealed partial class BlockPeer(BlockGrid owner) : FrameworkElementAutomationPeer(owner), IInvokeProvider, ISelectionItemProvider
    {
        public bool IsSelected => owner.IsSelectedBlock;

        public IRawElementProviderSimple? SelectionContainer => null;

        public void Invoke() => owner.Invoked?.Invoke();

        public void Select() => owner.Invoked?.Invoke();

        public void AddToSelection() => owner.Invoked?.Invoke();

        public void RemoveFromSelection()
        {
        }

        protected override string GetNameCore() => owner.AccessibleName?.Invoke() ?? base.GetNameCore();

        protected override string GetHelpTextCore() => owner.AccessibleRange?.Invoke() ?? base.GetHelpTextCore();

        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

        protected override string GetClassNameCore() => "TimelineSegment";

        protected override bool IsControlElementCore() => true;

        protected override bool IsContentElementCore() => true;

        // The block's own texts are in its name, so they are not read again as children.
        protected override IList<AutomationPeer> GetChildrenCore() => [];

        protected override object GetPatternCore(PatternInterface patternInterface) =>
            patternInterface is PatternInterface.Invoke or PatternInterface.SelectionItem ? this : base.GetPatternCore(patternInterface);
    }

    /// <summary>The ruler is the Playhead: a range value in seconds whose small change is one second (spec/06 ADR-51).</summary>
    private sealed partial class RulerSurface : Canvas
    {
        public Func<double>? Seconds { get; set; }

        public Func<double>? DurationSeconds { get; set; }

        public Action<double>? MoveTo { get; set; }

        protected override AutomationPeer OnCreateAutomationPeer() => new RulerPeer(this);
    }

    private sealed partial class RulerPeer(RulerSurface owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        public bool IsReadOnly => false;

        public double LargeChange => 5;

        public double Maximum => owner.DurationSeconds?.Invoke() ?? 0;

        public double Minimum => 0;

        public double SmallChange => 1;

        // Read when a client asks, never pushed from the playback tick.
        public double Value => owner.Seconds?.Invoke() ?? 0;

        public void SetValue(double value) => owner.MoveTo?.Invoke(value);

        protected override string GetNameCore() => Loc.T("Playhead");

        protected override string GetClassNameCore() => "RulerSurface";

        protected override string GetHelpTextCore() => A11y.Duration(Value * 1000);

        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;

        protected override bool IsControlElementCore() => true;

        protected override IList<AutomationPeer> GetChildrenCore() => [];

        protected override object GetPatternCore(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.RangeValue ? this : base.GetPatternCore(patternInterface);
    }

    private sealed partial class TrackSurface : Canvas
    {
        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
    }
}
