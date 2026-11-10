using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.App;

/// <summary>Drawing on the screen while recording, from the recording bar (spec/06 ADR-79).</summary>
public sealed partial class RecordingHudWindow
{
    private LiveDrawingOverlay? drawingOverlay;
    private bool drawingsStay;

    private bool IsDrawing => drawingOverlay?.IsDrawing == true;

    /// <summary>The draw button, and the tools while drawing. Screen recordings only.</summary>
    private void AddDrawingControls()
    {
        if (target is not { Mode: not CaptureTargetMode.Camera })
        {
            return;
        }

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        row.Children.Add(Item(Ui.Icon("", 16.5, Ui.Rgb(1, 1, 1, 0.9)), IsDrawing ? "Stop drawing (Esc)" : "Draw on screen", ToggleDrawing, 38, 38, IsDrawing));
        if (IsDrawing && drawingOverlay is { } overlay)
        {
            foreach (var (tool, glyph) in (ReadOnlySpan<(LiveDrawingTool, string)>)[(LiveDrawingTool.Pen, ""), (LiveDrawingTool.Highlighter, ""), (LiveDrawingTool.Arrow, ""), (LiveDrawingTool.Rectangle, "")])
            {
                var chosen = tool;
                row.Children.Add(Item(Ui.Icon(glyph, 15, Ui.Rgb(1, 1, 1, 0.9)), tool.Title(), () =>
                {
                    overlay.Tool = chosen;
                    AppSettings.Shared.LiveDrawingTool = chosen.ToString().ToLowerInvariant();
                    AppSettings.Shared.Save();
                    ShowRecording();
                    RaiseBarOverDrawing();
                }, 34, 34, overlay.Tool == tool));
            }

            foreach (var hex in LiveDrawingTools.Palette)
            {
                var color = hex;
                var (r, g, b) = AnnotationMath.HexColor(hex);
                var swatch = new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Ui.Rgb(r, g, b), BorderBrush = Ui.Rgb(1, 1, 1, 0.5), BorderThickness = new Thickness(1) };
                row.Children.Add(Item(swatch, "Color", () =>
                {
                    overlay.Color = color;
                    AppSettings.Shared.LiveDrawingColor = color;
                    AppSettings.Shared.Save();
                    ShowRecording();
                    RaiseBarOverDrawing();
                }, 26, 34, overlay.Color == color));
            }

            row.Children.Add(Item(Ui.Icon("", 15, Ui.Rgb(1, 1, 1, 0.9)), "Undo (Ctrl+Z)", OnDrawing(overlay.Undo), 34, 34));
            row.Children.Add(Item(Ui.Icon("", 15, Ui.Rgb(1, 1, 1, 0.9)), "Clear drawings (C)", OnDrawing(overlay.Clear), 34, 34));
        }

        bar.Children.Add(new Border { Width = 1, Height = 26, Background = Ui.Rgb(1, 1, 1, 0.20) });
        bar.Children.Add(row);
    }

    private void ToggleDrawing()
    {
        if (recorder is not { } engine || target is not { } recorded || package is not { } directory)
        {
            return;
        }

        if (IsDrawing)
        {
            drawingOverlay?.SetDrawing(false);
        }
        else if (!isPaused)
        {
            if (drawingOverlay is null)
            {
                // The choice to keep drawings is fixed for the whole recording when it is first needed.
                drawingOverlay = new LiveDrawingOverlay(recorded.Display, recorded.Rect, directory, engine, drawingsStay)
                {
                    Tool = Enum.TryParse<LiveDrawingTool>(AppSettings.Shared.LiveDrawingTool, true, out var tool) ? tool : LiveDrawingTool.Pen,
                    Color = AppSettings.Shared.LiveDrawingColor
                };
                drawingOverlay.DrawingStopped += ShowRecording;
            }

            drawingOverlay.SetDrawing(true);
            RaiseBarOverDrawing();
        }

        ShowRecording();
    }

    private const uint SwpNoActivate = 0x0010;

    /// <summary>
    /// The overlay takes the keys (Esc, 1-4, C, Ctrl+Z) and the bar sits above it without being activated, so its drawing
    /// tools stay clickable; otherwise the overlay, topmost and taking the mouse, turned every click on the bar into a stroke.
    /// </summary>
    private void RaiseBarOverDrawing()
    {
        if (!IsDrawing)
        {
            return;
        }

        drawingOverlay?.TakeKeys();
        SetWindowPos(Handle, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate);
    }

    /// <summary>A tool, color, undo or clear from the bar, then the keys go back to the overlay.</summary>
    private Action OnDrawing(Action action) => () =>
    {
        action();
        RaiseBarOverDrawing();
    };

    /// <summary>Pausing stops drawing; the strokes stay where they are.</summary>
    private void StopDrawingForPause()
    {
        if (IsDrawing)
        {
            drawingOverlay?.SetDrawing(false);
        }
    }

    private void DisposeDrawing()
    {
        drawingOverlay?.Dispose();
        drawingOverlay = null;
    }
}
