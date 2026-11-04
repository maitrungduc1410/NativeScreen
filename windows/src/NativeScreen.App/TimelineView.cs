using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NativeScreen.Core;
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
    private readonly Canvas ruler = new() { Height = RulerHeight, HorizontalAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
    private readonly TranslateTransform rulerOffset = new();
    private readonly Canvas marks = new() { IsHitTestVisible = false };
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
        canvas.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, args) =>
        {
            if (args.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control))
            {
                ZoomNudged?.Invoke(Math.Pow(1.25, args.GetCurrentPoint(canvas).Properties.MouseWheelDelta / 120.0));
                args.Handled = true;
            }
        }), handledEventsToo: true);
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

    private static readonly Color SystemWaveColor = Color.FromArgb(255, 77, 47, 245);
    private static readonly Color WhiteWaveColor = Color.FromArgb(255, 255, 255, 255);

    private readonly List<WaveLayer> waveLayers = [];
    private readonly List<(BlockGrid Block, double SourceStart, double SourceEnd)> followers = [];
    private readonly List<(BlockGrid Block, string SliceId, Canvas Ticks)> clipBlocks = [];
    private readonly List<UIElement> trimBadges = [];
    private readonly Dictionary<string, WaveformEnvelope> voiceoverWaves = [];
    private WaveformEnvelope? systemWave;
    private WaveformEnvelope? microphoneWave;
    private Border? recordingVoiceoverBlock;

    private double TrackWidth => Math.Max(260, viewportWidth - TrackInset * 2) * zoom;

    /// <summary>The editor's file actions, for menus that upload audio. Set once by the window.</summary>
    public EditorTools? Tools { get; set; }

    /// <summary>A touchpad pinch reaches the window as Ctrl and the wheel; the value multiplies the timeline zoom.</summary>
    public event Action<double>? ZoomNudged;

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

    public void SetVoiceoverWaveform(string id, float[] samples)
    {
        voiceoverWaves[id] = new WaveformEnvelope(samples);
        Rebuild();
    }

    /// <summary>A volume slider moved. Only the waves it changed are traced again.</summary>
    public void RefreshWaveformVolumes()
    {
        foreach (var layer in waveLayers)
        {
            UpdateWave(layer);
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

    /// <summary>Changes the scale with the playhead staying where it is in the viewport.</summary>
    public void SetZoom(double value)
    {
        var onScreen = X(session.PlayheadTimelineMs) - scroller.HorizontalOffset;
        zoom = value;
        Rebuild();
        canvas.UpdateLayout();
        scroller.ChangeView(Math.Max(0, X(session.PlayheadTimelineMs) - onScreen), null, null, true);
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

    public void Rebuild()
    {
        canvas.Children.Clear();
        ruler.Children.Clear();
        wigglingBlocks.Clear();
        waveLayers.Clear();
        followers.Clear();
        clipBlocks.Clear();
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
    private void FollowClipEdit(BlockGrid edited)
    {
        foreach (var mapped in session.Mapper.MappedSlices)
        {
            var entry = clipBlocks.Find(item => item.SliceId == mapped.Slice.Id);
            if (entry.Block is null)
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
            if (entry.Block == edited)
            {
                RetraceClipWaves(edited, mapped.Slice, width);
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
        foreach (var layer in waveLayers)
        {
            var innerWidth = layer.Owner.Width - layer.Owner.BorderThickness.Left * 2;
            if (!clipBlocks.Exists(item => item.Block == layer.Owner) && Math.Abs(innerWidth - layer.Width) > 0.5)
            {
                layer.Width = innerWidth;
                layer.Drawn = -1;
                UpdateWave(layer);
            }
        }

        foreach (var badge in trimBadges)
        {
            ruler.Children.Remove(badge);
        }

        trimBadges.Clear();
        DrawTrimBadges();
    }

    private void RetraceClipWaves(BlockGrid block, ClipSlice slice, double width)
    {
        var (start, end) = WaveRange(slice);
        foreach (var layer in waveLayers)
        {
            if (layer.Owner == block)
            {
                layer.Start = start;
                layer.End = end;
                layer.Width = width - block.BorderThickness.Left * 2;
                layer.Drawn = -1;
                layer.FullTraced = false;
                UpdateWave(layer);
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
            clipBlocks.Add((block, id, ticks));
            var blockWidth = X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs);
            block.SplitAt = time => session.SplitSlice(time);
            Draggable(
                block,
                blockWidth,
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
                SegmentMenu.ForClip(session, id, canvas, args.GetPosition(canvas));
            };
        }

        DrawTrimBadges();
        return y + ClipRowHeight + RowSpacing;
    }

    /// <summary>Gold teardrops on the ruler for what was trimmed or cut; a click restores it.</summary>
    private void DrawTrimBadges()
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
        var content = new Grid { Width = 30, Height = 28 };
        content.Children.Add(Ui.Shape("M0,0 A7,7 0 0 1 14,0 C14,6 9,11 7,16 C5,11 0,6 0,0 Z", 26, new SolidColorBrush(Palette.Clip.Ring)));
        var ink = new SolidColorBrush(Color.FromArgb(255, 60, 40, 5));
        UIElement mark = label is null
            ? Ui.Icon("", 9, ink)
            : new TextBlock { Text = label, FontSize = 8, FontWeight = FontWeights.Bold, Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        ((FrameworkElement)mark).Margin = new Thickness(0, 0, 0, 7);
        content.Children.Add(mark);
        var badge = new Button { Style = Ui.StyleOf("NsIconButton"), Content = content, Width = 30, Height = 28, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        ToolTipService.SetToolTip(badge, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(badge, tooltip);
        badge.Click += (_, _) => click();
        Canvas.SetLeft(badge, X(timelineMs) - 15);
        Canvas.SetTop(badge, RulerHeight - 28);
        Canvas.SetZIndex(badge, 5);
        ruler.Children.Add(badge);
        trimBadges.Add(badge);
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
        ticks.Children.Clear();
        var stepMs = rulerStepSeconds * 1000;
        for (var ms = Math.Ceiling(timelineStart / stepMs) * stepMs; ms < timelineEnd; ms += stepMs)
        {
            var x = (ms - timelineStart) / Math.Max(1, timelineEnd - timelineStart) * width;
            if (x > 4 && x < width - 4)
            {
                var tick = new Rectangle { Width = 1, Height = ClipRowHeight * 0.65, Fill = clipTick };
                Canvas.SetLeft(tick, x - 0.5);
                ticks.Children.Add(tick);
            }
        }
    }

    /// <summary>System audio in purple and the microphone in white, both following their volumes.</summary>
    private void AddClipWaveforms(BlockGrid block, ClipSlice slice, double width)
    {
        var (start, end) = WaveRange(slice);
        var id = slice.Id;
        var layer = 0;
        if (systemWave is { } system)
        {
            AddWave(block, width, ClipRowHeight, system, start, end, SystemWaveColor, 0.52, 0.25, ghost: true, layer++, () =>
            {
                var audio = session.Document.Audio;
                var current = session.Document.Timeline.Slices.Find(other => other.Id == id);
                return current is null || current.Muted || audio.MuteSystemAudio ? 0 : current.SystemAudioVolume * audio.SystemAudioVolume;
            });
        }

        if (microphoneWave is { } microphone)
        {
            AddWave(block, width, ClipRowHeight, microphone, start, end, WhiteWaveColor, 0.44, 0.20, ghost: false, layer, () =>
            {
                var audio = session.Document.Audio;
                var current = session.Document.Timeline.Slices.Find(other => other.Id == id);
                return current is null || current.Muted || audio.MuteMicrophone ? 0 : audio.MicrophoneVolume;
            });
        }
    }

    /// <summary>A filled envelope along the bottom of a block, under its ticks and text. Drawn once per edit, and at rest it costs nothing.</summary>
    private void AddWave(
        BlockGrid block,
        double width,
        double height,
        WaveformEnvelope envelope,
        double startFraction,
        double endFraction,
        Color color,
        double topOpacity,
        double bottomOpacity,
        bool ghost,
        int index,
        Func<double> volume)
    {
        if (!AppSettings.Shared.ShowAudioWaveform || width < 8)
        {
            return;
        }

        // Children are laid out inside the border, so the wave fits what is left.
        var border = block.BorderThickness.Top;
        var innerWidth = width - border * 2;
        var innerHeight = height - border * 2;
        var maximum = WaveformOutline.MaximumHeight(innerHeight);
        var fill = new Polygon
        {
            IsHitTestVisible = false,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Fill = new LinearGradientBrush
            {
                MappingMode = BrushMappingMode.Absolute,
                StartPoint = new Windows.Foundation.Point(0, innerHeight - maximum),
                EndPoint = new Windows.Foundation.Point(0, innerHeight),
                GradientStops =
                {
                    new GradientStop { Color = Color.FromArgb((byte)(topOpacity * 255), color.R, color.G, color.B), Offset = 0 },
                    new GradientStop { Color = Color.FromArgb((byte)(bottomOpacity * 255), color.R, color.G, color.B), Offset = 1 }
                }
            }
        };
        block.Children.Insert(index, fill);
        Polygon? full = null;
        if (ghost)
        {
            // Below 100% volume, the wave at 100% stays as a faint outline.
            full = new Polygon
            {
                IsHitTestVisible = false,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Fill = new SolidColorBrush(Color.FromArgb(31, color.R, color.G, color.B)),
                Visibility = Visibility.Collapsed
            };
            block.Children.Insert(index, full);
        }

        var layer = new WaveLayer(block, fill, full, envelope, startFraction, endFraction, innerWidth, innerHeight, Math.Max(0, block.CornerRadius.TopLeft - border), volume);
        waveLayers.Add(layer);
        UpdateWave(layer);
    }

    private static void UpdateWave(WaveLayer layer)
    {
        var volume = Math.Clamp(layer.Volume(), 0, 1.5);
        if (Math.Abs(volume - layer.Drawn) < 0.001)
        {
            return;
        }

        layer.Drawn = volume;
        layer.Fill.Visibility = volume > 0.005 ? Visibility.Visible : Visibility.Collapsed;
        if (volume > 0.005)
        {
            layer.Fill.Points = TraceWave(layer, volume);
        }

        if (layer.Full is { } full)
        {
            full.Visibility = volume > 0.005 && volume < 0.99 ? Visibility.Visible : Visibility.Collapsed;
            if (full.Visibility == Visibility.Visible && !layer.FullTraced)
            {
                full.Points = TraceWave(layer, 1);
                layer.FullTraced = true;
            }
        }
    }

    private static PointCollection TraceWave(WaveLayer layer, double volume)
    {
        var samplesPerBin = layer.Envelope.SamplesPerBin(layer.Start, layer.End, layer.Width);
        var maximum = WaveformOutline.MaximumHeight(layer.Height);
        var ceiling = WaveformOutline.Ceiling(layer.Height);
        var outline = WaveformOutline.Points(layer.Width, layer.Height, layer.Radius, AppSettings.Shared.SmoothWaveform, fraction =>
        {
            var position = (layer.Start + fraction * (layer.End - layer.Start)) * layer.Envelope.SampleCount;
            return Math.Min(ceiling, layer.Envelope.Read(position, samplesPerBin) * maximum * volume);
        });
        var points = new PointCollection();
        foreach (var (x, y) in outline)
        {
            points.Add(new Windows.Foundation.Point(x, y));
        }

        return points;
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
                    var apply = new MenuFlyoutItem { Text = $"Speed up typing {value:0}x" };
                    apply.Click += (_, _) => session.Mutate(document => TypingSuggestionEdits.Apply(document, target, value));
                    menu.Items.Add(apply);
                }

                var all = new MenuFlyoutItem { Text = "Apply to all suggestions, 4x" };
                all.Click += (_, _) => session.Mutate(document =>
                {
                    foreach (var other in suggestions)
                    {
                        TypingSuggestionEdits.Apply(document, other, 4);
                    }
                });
                menu.Items.Add(all);
                var remove = new MenuFlyoutItem { Text = "Remove suggestion" };
                remove.Click += (_, _) => session.Mutate(document => TypingSuggestionEdits.Dismiss(document, target));
                menu.Items.Add(remove);
                menu.ShowAt(bar);
                args.Handled = true;
            };
            ToolTipService.SetToolTip(bar, "Speed up typing");
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
            AddLabel(row == 0 ? "Voiceovers" : $"Voiceovers {row + 1}", y, MaskRowHeight, eye: true, hidden, () => session.ToggleVoiceoverTrackHidden(row));
            if (session.IsRecordingVoiceover && session.VoiceoverRecordingTrackIndex == row)
            {
                AddRecordingVoiceoverBlock(y);
            }

            foreach (var voiceover in timeline.Voiceovers.Where(item => item.TrackIndex == row))
            {
                var (left, width) = Place(voiceover.SourceStartMs, voiceover.SourceEndMs);
                var block = Block(left, y, width, MaskRowHeight, Palette.Mask, "Voiceover", $"{Math.Round(voiceover.Volume * 100):0}%", false, voiceover.Disabled || hidden || voiceover.Volume <= 0.001);
                Follow(block, voiceover.SourceStartMs, voiceover.SourceEndMs);
                var id = voiceover.Id;
                if (voiceoverWaves.TryGetValue(id, out var voiceoverWave))
                {
                    AddWave(block, width, MaskRowHeight, voiceoverWave, 0, 1, WhiteWaveColor, 0.44, 0.20, ghost: false, 0, () =>
                    {
                        var timelineNow = session.Document.Timeline;
                        var current = timelineNow.Voiceovers.Find(other => other.Id == id);
                        return current is null || current.Disabled || VoiceoverTrackLayout.IsTrackHidden(timelineNow, current.TrackIndex) ? 0 : current.Volume;
                    });
                }

                ToolTipService.SetToolTip(block, $"Voiceover at {Ui.Timecode(voiceover.SourceStartMs)}");
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    if (Tools is { } tools)
                    {
                        SegmentMenu.ForVoiceover(session, tools, id, canvas, args.GetPosition(canvas));
                    }
                };
                Draggable(block, width, () => session.SelectTab(InspectorTab.Audio), (start, end) =>
                {
                    session.Mutate(document => document.Timeline.Voiceovers.First(other => other.Id == id).SourceStartMs = start, structural: false);
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
                resizable: false);
            }

            y += MaskRowHeight + RowSpacing;
        }

        return y;
    }

    /// <summary>Grows with the playhead while a take is running.</summary>
    private void AddRecordingVoiceoverBlock(double y)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        content.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = new SolidColorBrush(Color.FromArgb(255, 255, 59, 48)), VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = "Recording voiceover…", FontSize = 11.5, FontWeight = FontWeights.Medium, Foreground = Ui.Pal("Ink95"), TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center });
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
                $"{item.Scale:0.#}x  ·  {(item.Mode == ZoomMode.FollowCursor ? "Auto" : "Manual")}",
                item.Id == session.SelectedZoomId,
                item.Disabled || timeline.IsZoomTrackHidden);
            Follow(block, item.SourceStartMs, item.SourceEndMs);
            var id = item.Id;
            block.SplitAt = time => session.SplitZoom(id, session.Mapper.SourceTime(time).SourceMs);
            Draggable(block, width, () => session.SelectZoom(id), (start, end) =>
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
            session.Mutate(document => document.Timeline.IsCameraLayoutsTrackHidden = !document.Timeline.IsCameraLayoutsTrackHidden));
        foreach (var layout in timeline.CameraLayouts)
        {
            var (left, width) = Place(layout.SourceStartMs, layout.SourceEndMs);
            var block = Block(left, y, width, MaskRowHeight, Palette.Layout, LayoutTitle(layout.LayoutType), null, layout.Id == session.SelectedLayoutId, layout.Disabled);
            Follow(block, layout.SourceStartMs, layout.SourceEndMs);
            var id = layout.Id;
            block.SplitAt = time => session.SplitLayout(id, session.Mapper.SourceTime(time).SourceMs);
            Draggable(block, width, () => session.SelectLayout(id), (start, end) =>
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
                }));
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
                    mask.Type == MaskType.Spotlight ? "Highlight" : "Sensitive data",
                    mask.Id == session.SelectedMaskId,
                    mask.Disabled || track.IsHidden);
                Follow(block, mask.SourceStartMs, mask.SourceEndMs);
                var id = mask.Id;
                block.SplitAt = time => session.SplitMask(id, session.Mapper.SourceTime(time).SourceMs);
                Draggable(block, width, () => session.SelectMask(id), (start, end) =>
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

    private double DrawShortcuts(double y)
    {
        var captions = session.Document.Captions;
        foreach (var track in captions.ShortcutTracks)
        {
            var trackId = track.Id;
            AddRowTarget(
                y,
                MaskRowHeight,
                GhostStyle.Shortcut,
                () => session.Shortcuts().Where(item => item.TrackId == trackId).Select(item => session.Mapper.TimelineSpan(item.DisplayStartMs, item.DisplayEndMs)).OfType<(double Start, double End)>(),
                450,
                1800,
                300,
                (start, end) => session.AddCustomShortcut(trackId, start, end));
            var trackHidden = track.IsHidden || !captions.ShowKeystrokes;
            AddLabel(track.Name, y, MaskRowHeight, eye: true, trackHidden, () => session.ToggleShortcutTrackHidden(trackId));
            var clusters = session.Shortcuts().Where(item => item.TrackId == track.Id).OrderBy(item => item.DisplayStartMs).ToList();
            foreach (var shortcut in clusters)
            {
                var (left, width) = Place(shortcut.DisplayStartMs, shortcut.DisplayEndMs);
                var block = Block(left, y, width, MaskRowHeight, Palette.Layout, shortcut.Label, null, shortcut.Id == session.SelectedShortcutId, trackHidden || SegmentEdits.IsShortcutHidden(session.Document, shortcut));
                Follow(block, shortcut.DisplayStartMs, shortcut.DisplayEndMs);
                var pressed = shortcut;
                block.RightTapped += (_, args) =>
                {
                    args.Handled = true;
                    SegmentMenu.ForShortcut(session, pressed, canvas, args.GetPosition(canvas));
                };
                var id = shortcut.Id;
                Draggable(block, width, () => session.SelectShortcut(id), (start, end) =>
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
            AddLabel(track.Name, y, MaskRowHeight, eye: true, hidden, () => session.ToggleCaptionTrackHidden(trackId));
            foreach (var item in captions.CaptionBlocks.Where(item => item.TrackId == trackId))
            {
                var (left, width) = Place(item.SourceStartMs, item.SourceEndMs);
                var block = Block(left, y, width, MaskRowHeight, Palette.Caption, "Caption", CaptionLineLayout.DisplayText(item, captions), item.Id == session.SelectedCaptionId, hidden);
                Follow(block, item.SourceStartMs, item.SourceEndMs);
                var id = item.Id;
                block.SplitAt = time => session.SplitCaption(id, session.Mapper.SourceTime(time).SourceMs);
                Draggable(block, width, () => session.SelectCaption(id), (start, end) =>
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

    private void AddLabel(string title, double y, double height, bool eye, bool hidden = false, Action? toggle = null)    {
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
        Canvas.SetTop(row, y);
        labels.Children.Add(row);
    }

    private BlockGrid Block(double x, double y, double width, double height, Palette palette, string title, string? subtitle, bool selected, bool dimmed)
    {
        var block = new BlockGrid
        {
            Width = Math.Max(6, width),
            Height = height,
            CornerRadius = new CornerRadius(height >= 40 ? 9 : 7),
            Background = Ui.Gradient(palette.Top, palette.Bottom),
            BorderBrush = new SolidColorBrush(selected ? Colors.White : palette.Ring),
            BorderThickness = new Thickness(selected ? 2 : 1),
            Opacity = dimmed ? 0.35 : 1
        };
        var text = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        text.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 11,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromArgb(170, 255, 255, 255)),
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
                Foreground = new SolidColorBrush(Colors.White),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1
            });
        }

        block.Children.Add(text);
        Canvas.SetLeft(block, x);
        Canvas.SetTop(block, y);
        canvas.Children.Add(block);
        ElementCompositionPreview.SetIsTranslationEnabled(block, true);
        var row = blockRows.IndexOf(y);
        if (row < 0)
        {
            row = blockRows.Count;
            blockRows.Add(y);
        }

        wigglingBlocks.Add((block, row));
        return block;
    }

    private void Draggable(
        BlockGrid block,
        double width,
        Action select,
        Action<double, double> apply,
        Func<(double Start, double End, double Low, double High)> bounds,
        bool canMove = true,
        Action<int>? movedRows = null,
        bool resizable = true,
        bool keycapHandles = false)
    {
        // Even the narrowest block keeps a part in the middle to move it by.
        var edgeWidth = Math.Min(EdgeHitWidth, Math.Max(5.5, width * 0.34));
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

        block.PointerEntered += (_, _) => hoveredBlock = block;
        block.PointerExited += (_, _) => hoveredBlock = hoveredBlock == block ? null : hoveredBlock;

        block.PointerMoved += (_, args) =>
        {
            if (drag is null)
            {
                var x = args.GetCurrentPoint(block).Position.X;
                var edge = x < edgeWidth || x > width - edgeWidth;
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
            var mode = x < edgeWidth ? DragMode.Start : x > width - edgeWidth ? DragMode.End : canMove ? DragMode.Move : DragMode.None;
            var (start, end, low, high) = bounds();
            session.BeginInteractiveEdit();
            var press = args.GetCurrentPoint(canvas).Position;
            drag = new Drag(block, press.X, press.Y, Canvas.GetTop(block), mode, start, end, low, high, apply, select, movedRows);
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
            switch (active.Mode)
            {
                case DragMode.Move:
                    var length = active.End - active.Start;
                    start = Math.Clamp(active.Start + delta, active.Low, active.High - length);
                    end = start + length;
                    break;
                case DragMode.Start:
                    start = Math.Clamp(active.Start + delta, active.Low, active.End - MinBlockMs);
                    break;
                case DragMode.End:
                    end = Math.Clamp(active.End + delta, active.Start + MinBlockMs, active.High);
                    break;
            }

            active.Apply(start, end);
            if (clipBlocks.Exists(item => item.Block == active.Block))
            {
                FollowClipEdit(active.Block);
            }
            else
            {
                var left = X(TimelineOf(start));
                Canvas.SetLeft(active.Block, left);
                active.Block.Width = Math.Max(6, X(TimelineOf(end)) - left);
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

    private sealed record Drag(BlockGrid Block, double PressX, double PressY, double BlockY, DragMode Mode, double Start, double End, double Low, double High, Action<double, double> Apply, Action Select, Action<int>? MovedRows);

    private sealed class WaveLayer(BlockGrid owner, Polygon fill, Polygon? full, WaveformEnvelope envelope, double start, double end, double width, double height, double radius, Func<double> volume)
    {
        public BlockGrid Owner { get; } = owner;
        public Polygon Fill { get; } = fill;
        public Polygon? Full { get; } = full;
        public WaveformEnvelope Envelope { get; } = envelope;
        public double Start { get; set; } = start;
        public double End { get; set; } = end;
        public double Width { get; set; } = width;
        public double Height { get; } = height;
        public double Radius { get; } = radius;
        public Func<double> Volume { get; } = volume;

        /// <summary>The volume the wave was last traced at. Starts out of range so the first update always traces.</summary>
        public double Drawn { get; set; } = -1;

        public bool FullTraced { get; set; }
    }

    private sealed record Palette(Color Top, Color Bottom, Color Ring)
    {
        public static readonly Palette Clip = new(Color.FromArgb(255, 147, 97, 12), Color.FromArgb(255, 218, 144, 18), Color.FromArgb(255, 244, 198, 119));
        public static readonly Palette Zoom = new(Color.FromArgb(255, 77, 47, 245), Color.FromArgb(255, 139, 120, 249), Color.FromArgb(255, 244, 242, 254));
        public static readonly Palette Mask = new(Color.FromArgb(255, 130, 52, 90), Color.FromArgb(255, 183, 75, 128), Color.FromArgb(255, 220, 166, 192));
        public static readonly Palette Caption = new(Color.FromArgb(255, 22, 99, 110), Color.FromArgb(255, 31, 143, 158), Color.FromArgb(255, 153, 222, 231));
        public static readonly Palette Layout = new(Color.FromArgb(255, 101, 87, 94), Color.FromArgb(255, 141, 124, 132), Color.FromArgb(255, 209, 200, 205));
    }

    /// <summary>A block-colored ghost for most rows; shortcuts have their own see-through purple.</summary>
    private sealed record GhostStyle(Color Top, Color Bottom, Color Ring, double Radius, double IconSize)
    {
        public static readonly GhostStyle Shortcut = new(Color.FromArgb(66, 77, 47, 245), Color.FromArgb(15, 77, 47, 245), Color.FromArgb(158, 77, 47, 245), 7, 12);

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

        public TextBlock? Subtitle { get; set; }

        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
    }

    private sealed partial class TrackSurface : Canvas
    {
        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
    }
}
