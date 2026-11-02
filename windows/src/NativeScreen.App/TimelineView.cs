using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NativeScreen.Core;
using Windows.UI;
using ZoomMode = NativeScreen.Core.ZoomMode;

namespace NativeScreen.App;

/// <summary>Multi-track timeline. Blocks are retained elements; the playhead moves by transform without a layout pass.</summary>
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
    private readonly Canvas canvas = new();
    private readonly Canvas labels = new();
    private readonly Canvas playhead = new() { IsHitTestVisible = false };
    private readonly TranslateTransform playheadOffset = new();
    private readonly Rectangle stem = new() { Width = 1.5, Fill = new SolidColorBrush(Color.FromArgb(230, 112, 77, 255)) };
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
        labelScroller.Content = labels;
        root.Children.Add(labelScroller);
        scroller.Content = canvas;
        Grid.SetColumn(scroller, 1);
        root.Children.Add(scroller);
        scroller.ViewChanged += (_, _) => labelScroller.ChangeView(null, scroller.VerticalOffset, null, true);
        root.SizeChanged += (_, args) =>
        {
            viewportWidth = Math.Max(300, args.NewSize.Width - LabelColumnWidth);
            Rebuild();
        };
        canvas.Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        canvas.PointerPressed += CanvasPressed;
        canvas.PointerMoved += CanvasMoved;
        canvas.PointerReleased += CanvasReleased;
        canvas.PointerCaptureLost += (_, _) => EndDrag();

        stem.RenderTransform = new TranslateTransform { X = -0.75 };
        playhead.Children.Add(stem);
        var head = Ui.Shape("M0,0 A7,7 0 0 1 14,0 C14,6 9,11 7,16 C5,11 0,6 0,0 Z", 15, new SolidColorBrush(Color.FromArgb(255, 112, 77, 255)));
        head.RenderTransform = new TranslateTransform { X = -7.5, Y = 3 };
        playhead.Children.Add(head);
        playhead.RenderTransform = playheadOffset;
    }

    private float[]? waveform;

    private double TrackWidth => Math.Max(260, viewportWidth - TrackInset * 2) * zoom;

    /// <summary>The editor's file actions, for menus that upload audio. Set once by the window.</summary>
    public EditorTools? Tools { get; set; }

    /// <summary>The playhead was moved by hand, so the clock label and the preview must follow it.</summary>
    public event Action? PlayheadScrubbed;

    public void SetWaveform(float[] peaks)
    {
        waveform = peaks;
        Rebuild();
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
    public void UpdatePlayhead() => playheadOffset.X = X(session.PlayheadTimelineMs);

    public void Rebuild()
    {
        canvas.Children.Clear();
        labels.Children.Clear();
        DrawRuler();
        var y = RulerHeight + 8;
        y = DrawTypingSuggestions(y);
        y = DrawClips(y);
        y = DrawZooms(y);
        y = DrawLayouts(y);
        y = DrawMasks(y);
        y = DrawShortcuts(y);
        y = DrawVoiceovers(y);
        y += 12;
        var height = Math.Max(y, root.ActualHeight);
        canvas.Width = TrackWidth + TrackInset * 2;
        canvas.Height = height;
        labels.Height = height;
        stem.Height = height;
        var rule = new Border { Width = 1, Height = height, Background = Ui.Pal("Ink07") };
        Canvas.SetLeft(rule, LabelColumnWidth - 1);
        labels.Children.Add(rule);
        canvas.Children.Add(playhead);
        UpdatePlayhead();
    }

    private double X(double timelineMs) => TrackInset + timelineMs / Math.Max(1, session.DurationMs) * TrackWidth;

    private double TimeAt(double x) => Math.Clamp((x - TrackInset) / TrackWidth * session.DurationMs, 0, session.DurationMs);

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

    private void DrawRuler()
    {
        var seconds = session.DurationMs / 1000;
        var pixelsPerSecond = TrackWidth / Math.Max(0.001, seconds);
        var step = new[] { 1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600 }.FirstOrDefault(item => item * pixelsPerSecond >= 90, 1200);
        for (var t = 0.0; t <= seconds + 0.001; t += step)
        {
            if (t > 0)
            {
                var minutes = (int)(t / 60);
                var label = Ui.Text($"{minutes}:{(int)(t % 60):00}", 11, "Ink60");
                label.TextWrapping = TextWrapping.NoWrap;
                Canvas.SetLeft(label, X(t * 1000) - 11);
                Canvas.SetTop(label, 8);
                canvas.Children.Add(label);
            }

            var dot = new Ellipse { Width = 3, Height = 3, Fill = Ui.Pal("Ink28") };
            Canvas.SetLeft(dot, X((t + step / 2) * 1000) - 1.5);
            Canvas.SetTop(dot, 15);
            if (t + step / 2 <= seconds)
            {
                canvas.Children.Add(dot);
            }
        }

        AddLabel("Tracks", 8, 18, eye: false);
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
                $"{seconds / 1000:0.#}s  ·  {slice.Speed:0.##}x",
                slice.Id == session.SelectedSliceId,
                false);
            AddWaveform(block, slice.SourceStartMs, slice.SourceEndMs, X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs));
            var id = slice.Id;
            var blockWidth = X(mapped.TimelineEndMs) - X(mapped.TimelineStartMs);
            block.PointerPressed += (_, args) =>
            {
                if (session.IsSplitModeActive)
                {
                    session.SplitSlice(TimeAt(args.GetCurrentPoint(canvas).Position.X));
                    args.Handled = true;
                }
            };
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

        // A badge on each cut merges the two clips around it.
        var cuts = session.Mapper.MappedSlices;
        for (var index = 0; index + 1 < cuts.Count; index++)
        {
            var left = cuts[index].Slice.Id;
            var badge = new Button
            {
                Style = Ui.StyleOf("NsIconButton"),
                Width = 18,
                Height = 18,
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(0),
                Background = new SolidColorBrush(Palette.Clip.Ring),
                Content = Ui.Icon("\uE71B", 9, new SolidColorBrush(Color.FromArgb(255, 60, 40, 5)))
            };
            ToolTipService.SetToolTip(badge, "Merge with next");
            badge.Click += (_, _) => session.MergeSliceWithNext(left);
            Canvas.SetLeft(badge, X(cuts[index].TimelineEndMs) - 9);
            Canvas.SetTop(badge, y - 7);
            Canvas.SetZIndex(badge, 5);
            canvas.Children.Add(badge);
        }

        return y + ClipRowHeight + RowSpacing;
    }

    /// <summary>A filled envelope along the bottom of a clip; one point per 3 px is plenty, and it is rebuilt only on edits.</summary>
    private void AddWaveform(BlockGrid block, double sourceStart, double sourceEnd, double width)
    {
        if (waveform is null || width < 8)
        {
            return;
        }

        var points = new PointCollection();
        var msPerBin = session.SourceDurationMs / waveform.Length;
        var count = Math.Max(2, (int)(width / 3));
        points.Add(new Windows.Foundation.Point(0, ClipRowHeight));
        for (var index = 0; index <= count; index++)
        {
            var from = sourceStart + (sourceEnd - sourceStart) * index / count;
            var to = sourceStart + (sourceEnd - sourceStart) * (index + 1) / count;
            var peak = 0f;
            for (var bin = (int)(from / msPerBin); bin < Math.Min(waveform.Length, (int)(to / msPerBin) + 1); bin++)
            {
                peak = Math.Max(peak, waveform[Math.Max(0, bin)]);
            }

            points.Add(new Windows.Foundation.Point(width * index / count, ClipRowHeight - peak * ClipRowHeight * 0.55));
        }

        points.Add(new Windows.Foundation.Point(width, ClipRowHeight));
        block.Children.Insert(0, new Polygon { Points = points, Fill = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255)), IsHitTestVisible = false });
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
            var left = X(TimelineOf(item.SourceStartMs));
            var width = X(TimelineOf(item.SourceEndMs)) - left;
            var bar = Block(left, y, width, 16, Palette.Clip, "", null, false, false);
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
        if (timeline.Voiceovers.Count == 0)
        {
            return y;
        }

        AddLabel("Voiceovers", y, MaskRowHeight, eye: true, timeline.IsVoiceoversTrackHidden, () =>
            session.Mutate(document => document.Timeline.IsVoiceoversTrackHidden = !document.Timeline.IsVoiceoversTrackHidden));
        foreach (var voiceover in timeline.Voiceovers)
        {
            var left = X(TimelineOf(voiceover.SourceStartMs));
            var width = X(TimelineOf(voiceover.SourceEndMs)) - left;
            var block = Block(left, y, width, MaskRowHeight, Palette.Layout, "Voiceover", null, false, voiceover.Disabled || timeline.IsVoiceoversTrackHidden);
            var id = voiceover.Id;
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
                var current = session.Document.Timeline.Voiceovers.First(other => other.Id == id);
                return (current.SourceStartMs, current.SourceEndMs, 0, session.SourceDurationMs);
            });
        }

        return y + MaskRowHeight + RowSpacing;
    }

    private double DrawZooms(double y)
    {
        var timeline = session.Document.Timeline;
        AddRowTarget(y, ZoomRowHeight, Palette.Zoom, time => session.AddZoomAt(ZoomPresentation.Screen, time));
        AddLabel("Zoom", y, ZoomRowHeight, eye: true, timeline.IsZoomTrackHidden, () =>
            session.Mutate(document => document.Timeline.IsZoomTrackHidden = !document.Timeline.IsZoomTrackHidden));
        foreach (var item in timeline.Zooms)
        {
            var left = X(TimelineOf(item.SourceStartMs));
            var width = X(TimelineOf(item.SourceEndMs)) - left;
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
            var id = item.Id;
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

        AddLabel("Layouts", y, MaskRowHeight, eye: true, timeline.IsCameraLayoutsTrackHidden, () =>
            session.Mutate(document => document.Timeline.IsCameraLayoutsTrackHidden = !document.Timeline.IsCameraLayoutsTrackHidden));
        foreach (var layout in timeline.CameraLayouts)
        {
            var left = X(TimelineOf(layout.SourceStartMs));
            var width = X(TimelineOf(layout.SourceEndMs)) - left;
            var block = Block(left, y, width, MaskRowHeight, Palette.Layout, LayoutTitle(layout.LayoutType), null, layout.Id == session.SelectedLayoutId, layout.Disabled);
            var id = layout.Id;
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
            AddRowTarget(y, MaskRowHeight, Palette.Mask, time => session.AddMaskAt(MaskType.Blur, time));
            AddLabel(track.Name, y, MaskRowHeight, eye: true, track.IsHidden, () =>
                session.Mutate(document =>
                {
                    var target = document.Timeline.MaskTracks.First(other => other.Id == trackId);
                    target.IsHidden = !target.IsHidden;
                }));
            foreach (var mask in track.Items)
            {
                var left = X(TimelineOf(mask.SourceStartMs));
                var width = X(TimelineOf(mask.SourceEndMs)) - left;
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
                var id = mask.Id;
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
            AddRowTarget(y, MaskRowHeight, Palette.Layout, time => session.AddCustomShortcut(trackId, time));
            AddLabel(track.Name, y, MaskRowHeight, eye: false);
            var clusters = session.Shortcuts().Where(item => item.TrackId == track.Id).OrderBy(item => item.DisplayStartMs).ToList();
            foreach (var shortcut in clusters)
            {
                var left = X(TimelineOf(shortcut.DisplayStartMs));
                var width = X(TimelineOf(shortcut.DisplayEndMs)) - left;
                var block = Block(left, y, width, MaskRowHeight, Palette.Layout, shortcut.Label, null, shortcut.Id == session.SelectedShortcutId, SegmentEdits.IsShortcutHidden(session.Document, shortcut));
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
                });
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

    /// <summary>An empty row shows a plus where the pointer is, and clicking it adds a block there. Blocks are drawn over it.</summary>
    private void AddRowTarget(double y, double height, Palette palette, Action<double> add)
    {
        var row = new Border { Width = TrackWidth, Height = height, Background = new SolidColorBrush(Color.FromArgb(0, 0, 0, 0)) };
        var ghost = new Border
        {
            Width = 34,
            Height = height,
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Color.FromArgb(70, palette.Top.R, palette.Top.G, palette.Top.B)),
            BorderBrush = new SolidColorBrush(palette.Ring),
            BorderThickness = new Thickness(1),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Child = new TextBlock { Text = "+", FontSize = 15, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(Colors.White) }
        };
        Canvas.SetLeft(row, TrackInset);
        Canvas.SetTop(row, y);
        Canvas.SetTop(ghost, y);
        row.PointerMoved += (_, args) =>
        {
            if (drag is null && !scrubbing)
            {
                ghost.Visibility = Visibility.Visible;
                Canvas.SetLeft(ghost, args.GetCurrentPoint(canvas).Position.X - 17);
            }
        };
        row.PointerExited += (_, _) => ghost.Visibility = Visibility.Collapsed;
        row.PointerPressed += (_, args) =>
        {
            args.Handled = true;
            add(session.Mapper.SourceTime(TimeAt(args.GetCurrentPoint(canvas).Position.X)).SourceMs);
        };
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
            text.Children.Add(new TextBlock
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
        return block;
    }

    private void Draggable(
        BlockGrid block,
        double width,
        Action select,
        Action<double, double> apply,
        Func<(double Start, double End, double Low, double High)> bounds,
        bool canMove = true,
        Action<int>? movedRows = null)
    {
        block.PointerMoved += (_, args) =>
        {
            if (drag is null)
            {
                var x = args.GetCurrentPoint(block).Position.X;
                var edge = x < EdgeHitWidth || x > width - EdgeHitWidth;
                block.SetCursor(edge ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.Arrow);
            }
        };
        block.PointerPressed += (_, args) =>
        {
            if (!args.GetCurrentPoint(block).Properties.IsLeftButtonPressed)
            {
                return;
            }

            // Selecting rebuilds every block, so it waits for release; a rebuild mid-press would cancel the drag.
            var x = args.GetCurrentPoint(block).Position.X;
            var mode = x < EdgeHitWidth ? DragMode.Start : x > width - EdgeHitWidth ? DragMode.End : canMove ? DragMode.Move : DragMode.None;
            var (start, end, low, high) = bounds();
            session.BeginInteractiveEdit();
            var press = args.GetCurrentPoint(canvas).Position;
            drag = new Drag(block, press.X, press.Y, Canvas.GetTop(block), session.DurationMs, mode, start, end, low, high, apply, select, movedRows);
            canvas.CapturePointer(args.Pointer);
            args.Handled = true;
        };
    }

    private void CanvasPressed(object sender, PointerRoutedEventArgs args)
    {
        if (!args.GetCurrentPoint(canvas).Properties.IsLeftButtonPressed)
        {
            return;
        }

        session.ClearSelection();
        scrubbing = true;
        canvas.CapturePointer(args.Pointer);
        session.Scrub(TimeAt(args.GetCurrentPoint(canvas).Position.X));
        UpdatePlayhead();
        PlayheadScrubbed?.Invoke();
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

            // The scale at the press: trimming a clip changes the total duration under the pointer.
            var delta = (x - active.PressX) / TrackWidth * active.PressDurationMs;
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
            var left = X(TimelineOf(start));
            Canvas.SetLeft(active.Block, left);
            active.Block.Width = Math.Max(6, X(TimelineOf(end)) - left);
        }
        else if (scrubbing)
        {
            session.Scrub(TimeAt(x));
            UpdatePlayhead();
            PlayheadScrubbed?.Invoke();
        }
    }

    private void CanvasReleased(object sender, PointerRoutedEventArgs args)
    {
        var y = args.GetCurrentPoint(canvas).Position.Y;
        // Releasing raises PointerCaptureLost at once, which would end the drag without a drop row.
        EndDrag(y);
        canvas.ReleasePointerCapture(args.Pointer);
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

    private sealed record Drag(BlockGrid Block, double PressX, double PressY, double BlockY, double PressDurationMs, DragMode Mode, double Start, double End, double Low, double High, Action<double, double> Apply, Action Select, Action<int>? MovedRows);

    private sealed record Palette(Color Top, Color Bottom, Color Ring)
    {
        public static readonly Palette Clip = new(Color.FromArgb(255, 147, 97, 12), Color.FromArgb(255, 218, 144, 18), Color.FromArgb(255, 244, 198, 119));
        public static readonly Palette Zoom = new(Color.FromArgb(255, 77, 47, 245), Color.FromArgb(255, 139, 120, 249), Color.FromArgb(255, 244, 242, 254));
        public static readonly Palette Mask = new(Color.FromArgb(255, 130, 52, 90), Color.FromArgb(255, 183, 75, 128), Color.FromArgb(255, 220, 166, 192));
        public static readonly Palette Layout = new(Color.FromArgb(255, 101, 87, 94), Color.FromArgb(255, 141, 124, 132), Color.FromArgb(255, 209, 200, 205));
    }

    private static class Colors
    {
        public static readonly Color White = Color.FromArgb(255, 255, 255, 255);
    }

    // UIElement.ProtectedCursor is only reachable from a subclass.
    private sealed partial class BlockGrid : Grid
    {
        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
    }
}
