using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NativeScreen.Core;

namespace NativeScreen.App;

/// <summary>The selected annotation's inspector, ported from `annotationEditor` in `InspectorSidebarView.swift` (spec/06 ADR-75).</summary>
internal sealed partial class InspectorPanel
{
    private void AnnotationEditor(AnnotationItem shown)
    {
        var id = shown.Id;
        // An item removed while this panel is up (an agent, an undo) takes the edit on a throwaway copy instead of throwing.
        AnnotationItem Find(ProjectDocument document) => EditorSession.FindAnnotation(document, id) ?? new AnnotationItem();
        AnnotationItem? Live() => session.Annotation(id);
        // With keyframes, geometry is shown and edited where the item is at the playhead.
        var at = Math.Clamp(session.SourceAtPlayhead, shown.SourceStartMs, shown.SourceEndMs);
        var item = shown.Resolved(at);
        var kind = item.Kind;
        Add(CloseEditor("Close annotation editor", () => session.SelectAnnotation(null)));

        // Styles: built-in and saved looks, never the text, position or size.
        var styles = Action("Styles", () => { });
        styles.Click += (_, _) =>
        {
            var menu = new MenuFlyout();
            var builtIn = new MenuFlyoutSubItem { Text = Loc.T("Built-in") };
            foreach (var style in AnnotationStyle.BuiltIn)
            {
                var chosen = style;
                var entry = new MenuFlyoutItem { Text = Loc.T(style.Name) };
                entry.Click += (_, _) => session.ApplyAnnotationStyle(chosen, id);
                builtIn.Items.Add(entry);
            }

            menu.Items.Add(builtIn);
            if (AppSettings.Shared.AnnotationStyles.Count > 0)
            {
                var saved = new MenuFlyoutSubItem { Text = Loc.T("Saved") };
                foreach (var style in AppSettings.Shared.AnnotationStyles)
                {
                    var chosen = style;
                    var entry = new MenuFlyoutItem { Text = style.Name };
                    entry.Click += (_, _) => session.ApplyAnnotationStyle(chosen, id);
                    saved.Items.Add(entry);
                }

                var delete = new MenuFlyoutSubItem { Text = Loc.T("Delete saved style") };
                foreach (var style in AppSettings.Shared.AnnotationStyles)
                {
                    var chosen = style;
                    var entry = new MenuFlyoutItem { Text = style.Name };
                    entry.Click += (_, _) =>
                    {
                        AppSettings.Shared.AnnotationStyles.Remove(chosen);
                        AppSettings.Shared.Save();
                    };
                    delete.Items.Add(entry);
                }

                menu.Items.Add(saved);
                menu.Items.Add(delete);
            }

            menu.Items.Add(new MenuFlyoutSeparator());
            var save = new MenuFlyoutItem { Text = Loc.T("Save this style...") };
            save.Click += (_, _) =>
            {
                if (Live() is { } current)
                {
                    var name = $"{Loc.T("Style")} {AppSettings.Shared.AnnotationStyles.Count + 1}";
                    AppSettings.Shared.AnnotationStyles.Add(AnnotationStyle.From(name, current));
                    AppSettings.Shared.Save();
                }
            };
            var all = new MenuFlyoutItem { Text = Loc.T("Apply this style to all annotations") };
            all.Click += (_, _) =>
            {
                if (Live() is { } current)
                {
                    session.ApplyAnnotationStyleToAll(AnnotationStyle.From("", current));
                }
            };
            menu.Items.Add(save);
            menu.Items.Add(all);
            menu.ShowAt(styles);
        };
        Add(styles);

        var kinds = new List<(string, bool, Action?)>();
        foreach (var option in Enum.GetValues<AnnotationKind>())
        {
            if (option.IsAddable() || option == kind)
            {
                var chosen = option;
                kinds.Add((option.Title(), option == kind, () => Edit(d =>
                {
                    var target = Find(d);
                    var hadDefault = target.Color == AnnotationItem.DefaultColor(target.Kind);
                    target.Kind = chosen;
                    if (hadDefault)
                    {
                        target.Color = AnnotationItem.DefaultColor(chosen);
                    }
                })));
            }
        }

        Add(Labeled("Type", 10, OptionsWrap([.. kinds])));
        Add(Labeled("Pin to", 10, Options(
            ("Screen", item.Anchor == AnnotationAnchor.Screen, () => session.SetAnnotationAnchor(id, AnnotationAnchor.Screen)),
            ("Frame", item.Anchor == AnnotationAnchor.Canvas, () => session.SetAnnotationAnchor(id, AnnotationAnchor.Canvas)))));
        Add(Note(item.Anchor == AnnotationAnchor.Screen ? "Follows what it points at when the video zooms or pans." : "Stays in the same place in the frame."));
        AddDivider();


        UIElement ColorRow(string title, string hex, Action<AnnotationItem, string> set) => Labeled(title, 10, ColorField.Create(
            title,
            hex,
            value => session.UpdateAnnotation(id, a => set(a, value), "annotation-color"),
            value => session.UpdateAnnotation(id, a => set(a, value))));

        switch (kind)
        {
            case AnnotationKind.Text:
            {
                var text = new TextBox { Text = item.Text, PlaceholderText = Loc.T("Add your text"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
                AutomationName(text, "Text");
                text.TextChanged += (_, _) =>
                {
                    if (Live() is { } current && current.Text != text.Text)
                    {
                        session.UpdateAnnotation(id, a => a.Text = text.Text, "annotation-text");
                    }
                };
                Add(Labeled("Text", 10, text));
                Add(Note("Double-click the text on the preview to type there."));
                Add(Slider("Font size", () => (Live()?.FontSizeRatio ?? 0.042) * 100, (d, v) => Find(d).FontSizeRatio = AnnotationItem.ClampedFontSize(v / 100), 1.5, 20, 4.2));
                Add(Slider("Maximum width", () => (Live()?.MaxWidthRatio ?? 0.5) * 100, (d, v) => Find(d).MaxWidthRatio = AnnotationItem.ClampedMaxWidth(v / 100), 10, 100, 50));
                Add(Toggle("Bold", null, () => Live()?.Bold ?? true, (d, v) => Find(d).Bold = v));
                Add(ColorRow("Text color", item.Color, (a, v) => a.Color = v));
                Add(Labeled("Background", 10, Options(
                    ("None", item.TextBackground == AnnotationTextBackground.None, () => Edit(d => Find(d).TextBackground = AnnotationTextBackground.None)),
                    ("Solid", item.TextBackground == AnnotationTextBackground.Solid, () => Edit(d => Find(d).TextBackground = AnnotationTextBackground.Solid)))));
                if (item.TextBackground == AnnotationTextBackground.Solid)
                {
                    Add(ColorRow("Background", item.BackgroundColor, (a, v) => a.BackgroundColor = v));
                }

                break;
            }

            case AnnotationKind.Arrow:
                Add(ColorRow("Color", item.Color, (a, v) => a.Color = v));
                Add(Slider("Thickness", () => (Live()?.StrokeRatio ?? 0.007) * 1000, (d, v) => Find(d).StrokeRatio = AnnotationItem.ClampedStroke(v / 1000), 2, 30, 7));
                Add(Slider("Curve", () => (Live()?.Bend ?? 0.18) * 100, (d, v) => Find(d).Bend = AnnotationItem.ClampedBend(v / 100), -80, 80, 18));
                break;
            case AnnotationKind.Rectangle:
            case AnnotationKind.Ellipse:
                Add(ColorRow("Color", item.Color, (a, v) => a.Color = v));
                Add(Slider("Thickness", () => (Live()?.StrokeRatio ?? 0.007) * 1000, (d, v) => Find(d).StrokeRatio = AnnotationItem.ClampedStroke(v / 1000), 2, 30, 7));
                Add(Slider("Fill", () => (Live()?.FillOpacity ?? 0) * 100, (d, v) => Find(d).FillOpacity = Math.Clamp(v / 100, 0, 1), 0, 100, 0));
                if (kind == AnnotationKind.Rectangle)
                {
                    Add(Slider("Corner radius", () => (Live()?.CornerRatio ?? 0.012) * 1000, (d, v) => Find(d).CornerRatio = AnnotationItem.ClampedCorner(v / 1000), 0, 100, 12));
                }

                break;
            case AnnotationKind.Pen:
                Add(ColorRow("Color", item.Color, (a, v) => a.Color = v));
                Add(Slider("Thickness", () => (Live()?.StrokeRatio ?? 0.005) * 1000, (d, v) => Find(d).StrokeRatio = AnnotationItem.ClampedStroke(v / 1000), 2, 30, item.Highlighter ? 20 : 5));
                Add(Toggle("Highlighter", null, () => Live()?.Highlighter ?? false, (d, v) => Find(d).Highlighter = v));
                break;
            case AnnotationKind.Image:
                Add(Action(item.ImagePath.Length == 0 ? "Choose image..." : "Replace image...", () => _ = ReplaceAnnotationImage(id)));
                Add(Slider("Width", () => (Live()?.MaxWidthRatio ?? 0.25) * 100, (d, v) => Find(d).MaxWidthRatio = AnnotationItem.ClampedMaxWidth(v / 100), 10, 100, 25));
                Add(Slider("Corner radius", () => (Live()?.CornerRatio ?? 0.01) * 1000, (d, v) => Find(d).CornerRatio = AnnotationItem.ClampedCorner(v / 1000), 0, 100, 10));
                break;
            case AnnotationKind.Step:
                Add(ColorRow("Color", item.Color, (a, v) => a.Color = v));
                Add(Slider("Size", () => (Live()?.FontSizeRatio ?? 0.036) * 100, (d, v) => Find(d).FontSizeRatio = AnnotationItem.ClampedFontSize(v / 100), 1.5, 12, 3.6));
                Add(Note("Steps are numbered in the order they appear."));
                break;
        }

        if (kind.CanRotate())
        {
            AddDivider();
            Add(Slider("Rotation", () => Live()?.Resolved(Math.Clamp(session.SourceAtPlayhead, shown.SourceStartMs, shown.SourceEndMs)).RotationDegrees ?? 0, (d, v) =>
            {
                var target = Find(d);
                if (target.Keyframes.Count == 0)
                {
                    target.RotationDegrees = AnnotationItem.NormalizedRotation(v);
                }
            }, -180, 180, 0));
        }

        // Motion: keyframes at the playhead.
        AddDivider();
        var keyframes = new StackPanel { Spacing = 6 };
        if (shown.Keyframes.Count == 0)
        {
            keyframes.Children.Add(Note("Still"));
        }

        for (var index = 0; index < shown.Keyframes.Count; index++)
        {
            var position = index;
            var time = shown.Keyframes[index].SourceMs;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            row.Children.Add(Ui.Text(string.Create(System.Globalization.CultureInfo.CurrentCulture, $"{time / 1000:0.00}s"), 12, "Ink88"));
            row.Children.Add(Action("Go to keyframe", () =>
            {
                if (session.Mapper.TimelineTime(time) is { } timelineMs)
                {
                    session.Scrub(timelineMs);
                }
            }));
            row.Children.Add(Action("Remove keyframe", () => session.RemoveAnnotationKeyframe(id, position)));
            keyframes.Children.Add(row);
        }

        keyframes.Children.Add(Action("Add keyframe at playhead", () => session.AddAnnotationKeyframe(id)));
        if (shown.Keyframes.Count > 0)
        {
            keyframes.Children.Add(Action("Remove all keyframes", () => session.ClearAnnotationKeyframes(id)));
            keyframes.Children.Add(Note("While keyframes exist, moving the item on the preview changes the keyframe at the playhead."));
        }

        Add(Labeled("Motion", 10, keyframes));
        AddDivider();
        UIElement AnimationPicker(string title, AnnotationAnimation current, Action<AnnotationItem, AnnotationAnimation> set)
        {
            var options = new List<(string, bool, Action?)>();
            foreach (var animation in Enum.GetValues<AnnotationAnimation>())
            {
                if (animation.IsOffered(kind))
                {
                    var chosen = animation;
                    options.Add((animation.Title(), animation == current, () => session.UpdateAnnotation(id, a => set(a, chosen))));
                }
            }

            return Labeled(title, 10, OptionsWrap([.. options]));
        }

        Add(AnimationPicker("Appear", item.Enter, (a, v) => a.Enter = v));
        Add(AnimationPicker("Disappear", item.Exit, (a, v) => a.Exit = v));
        Add(Slider("Animation length (ms)", () => Live()?.AnimationMs ?? 250, (d, v) => Find(d).AnimationMs = AnnotationItem.ClampedAnimation(v), 0, 1500, 250));
        AddDivider();
        Add(Action("Duplicate", () => session.DuplicateAnnotation(id)));
        Add(Action("Remove annotation", () => session.DeleteAnnotation(id)));

    }

    private async Task ReplaceAnnotationImage(string id)
    {
        if (await tools.PickImageIntoPackage("annotations") is { } path)
        {
            session.UpdateAnnotation(id, a => a.ImagePath = path);
        }
    }
}
