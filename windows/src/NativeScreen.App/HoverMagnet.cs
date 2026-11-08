using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace NativeScreen.App;

/// <summary>
/// The directional hover highlight of tool buttons: the background flies in from where the pointer came from, leans toward it
/// by 2 points while inside, and flies out the way it left. It all runs on the compositor, so a hover costs the UI thread only
/// the pointer events and nothing runs at rest (spec/06 ADR-38).
/// </summary>
public static class HoverMagnet
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled",
        typeof(bool),
        typeof(HoverMagnet),
        new PropertyMetadata(false, EnabledChanged));

    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.RegisterAttached(
        "IsActive",
        typeof(bool),
        typeof(HoverMagnet),
        new PropertyMetadata(false));

    private static readonly DependencyProperty StateProperty = DependencyProperty.RegisterAttached(
        "State",
        typeof(object),
        typeof(HoverMagnet),
        new PropertyMetadata(null));

    public static bool GetIsEnabled(DependencyObject element) => (bool)element.GetValue(IsEnabledProperty);

    public static void SetIsEnabled(DependencyObject element, bool value) => element.SetValue(IsEnabledProperty, value);

    /// <summary>A lit tool button keeps its fill at rest, so its highlight only leans toward the pointer and does not fly.</summary>
    public static bool GetIsActive(DependencyObject element) => (bool)element.GetValue(IsActiveProperty);

    public static void SetIsActive(DependencyObject element, bool value) => element.SetValue(IsActiveProperty, value);

    private static void EnabledChanged(DependencyObject element, DependencyPropertyChangedEventArgs args)
    {
        // Animation effects off: the template's plain hover fill stays, without the fly-in or the pull (spec/06 ADR-51).
        if (A11y.ReduceMotion)
        {
            return;
        }

        if (element is Control control && args.NewValue is true && control.GetValue(StateProperty) is null)
        {
            control.SetValue(StateProperty, new Tracker(control));
        }
    }

    private sealed class Tracker
    {
        private const float MaximumOffset = 2;
        private const float EscapeMultiplier = 10;
        private const float EntryShrink = 0.2f;
        private const float RestOpacity = 0.095f;
        private const float PressedOpacity = 0.14f;
        private const long SettledAfterMs = 250;
        // Stiffness 1500, damping 100 and mass 2. A compositor spring's Period acts as 1 / omega, not 2 pi / omega (measured, spec/06 ADR-38).
        private const float SpringDamping = 0.913f;
        private static readonly TimeSpan SpringPeriod = TimeSpan.FromSeconds(0.0365);

        private readonly Control control;
        private Border? layer;
        private CompositionPropertySet? state;
        private SpringScalarNaturalMotionAnimation? hoverSpring;
        private SpringVector2NaturalMotionAnimation? offsetSpring;
        private long leftAt;
        private bool inside;

        public Tracker(Control control)
        {
            this.control = control;
            control.Loaded += (_, _) => FindLayers();
            control.PointerEntered += Entered;
            control.PointerMoved += Moved;
            control.PointerExited += Exited;
            control.PointerCanceled += Exited;
            control.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(Pressed), handledEventsToo: true);
            control.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(Released), handledEventsToo: true);
        }

        /// <summary>Hides the plain hover fill. A template without these layers keeps it.</summary>
        private void FindLayers()
        {
            if (layer is not null || VisualTreeHelper.GetChildrenCount(control) == 0 || VisualTreeHelper.GetChild(control, 0) is not Panel root)
            {
                return;
            }

            foreach (var child in root.Children)
            {
                if (child is Border { Name: "MagnetLayer" } magnet)
                {
                    layer = magnet;
                }
                else if (child is Border { Name: "HoverLayer" } plain)
                {
                    plain.Visibility = Visibility.Collapsed;
                }
            }
        }

        /// <summary>Made on the first hover, so a panel full of buttons pays nothing for the ones never touched.</summary>
        private CompositionPropertySet? EnsureState()
        {
            if (state is not null || layer is null)
            {
                return state;
            }

            layer.Visibility = Visibility.Visible;
            ElementCompositionPreview.SetIsTranslationEnabled(layer, true);
            var visual = ElementCompositionPreview.GetElementVisual(layer);
            var compositor = visual.Compositor;
            state = compositor.CreatePropertySet();
            state.InsertScalar("hover", 0);
            state.InsertVector2("offset", Vector2.Zero);
            state.InsertScalar("escape", EscapeMultiplier);
            state.InsertScalar("peak", RestOpacity);

            ExpressionAnimation Expression(string text)
            {
                var expression = compositor.CreateExpressionAnimation(text);
                expression.SetReferenceParameter("s", state);
                return expression;
            }

            visual.StartAnimation("Translation", Expression("Vector3(s.offset.X * (1 + (1 - Clamp(s.hover, 0, 1)) * s.escape), s.offset.Y * (1 + (1 - Clamp(s.hover, 0, 1)) * s.escape), 0)"));
            var scale = FormattableString.Invariant($"1 - (1 - Clamp(s.hover, 0, 1)) * {EntryShrink / EscapeMultiplier} * s.escape");
            visual.StartAnimation("Scale", Expression($"Vector3({scale}, {scale}, 1)"));
            visual.StartAnimation("Opacity", Expression("Clamp(s.hover, 0, 1) * s.peak"));

            hoverSpring = compositor.CreateSpringScalarAnimation();
            hoverSpring.Period = SpringPeriod;
            hoverSpring.DampingRatio = SpringDamping;
            offsetSpring = compositor.CreateSpringVector2Animation();
            offsetSpring.Period = SpringPeriod;
            offsetSpring.DampingRatio = SpringDamping;
            return state;
        }

        private Vector2 TargetOffset(PointerRoutedEventArgs args)
        {
            var point = args.GetCurrentPoint(control).Position;
            var u = Math.Clamp(point.X / Math.Max(1, control.ActualWidth), 0, 1);
            var v = Math.Clamp(point.Y / Math.Max(1, control.ActualHeight), 0, 1);
            return new Vector2((float)(u * 2 - 1) * MaximumOffset, (float)(v * 2 - 1) * MaximumOffset);
        }

        private void SpringOffset(Vector2 target)
        {
            offsetSpring!.FinalValue = target;
            state!.StartAnimation("offset", offsetSpring);
        }

        private void SpringHover(float target)
        {
            hoverSpring!.FinalValue = target;
            state!.StartAnimation("hover", hoverSpring);
        }

        private void Entered(object sender, PointerRoutedEventArgs args)
        {
            FindLayers();
            if (EnsureState() is not { } current || layer is null)
            {
                return;
            }

            var visual = ElementCompositionPreview.GetElementVisual(layer);
            visual.CenterPoint = new Vector3((float)layer.ActualWidth / 2, (float)layer.ActualHeight / 2, 0);
            current.InsertScalar("escape", GetIsActive(control) ? 0 : EscapeMultiplier);
            inside = true;
            var target = TargetOffset(args);
            if (Environment.TickCount64 - leftAt > SettledAfterMs)
            {
                // From rest it starts on the side the pointer came in, so it flies in from there.
                current.StopAnimation("offset");
                current.InsertVector2("offset", target);
            }
            else
            {
                SpringOffset(target);
            }

            SpringHover(1);
        }

        private void Moved(object sender, PointerRoutedEventArgs args)
        {
            if (inside && state is not null)
            {
                SpringOffset(TargetOffset(args));
            }
        }

        private void Exited(object sender, PointerRoutedEventArgs args)
        {
            if (!inside || state is null)
            {
                return;
            }

            inside = false;
            leftAt = Environment.TickCount64;
            state.InsertScalar("peak", RestOpacity);
            SpringOffset(TargetOffset(args));
            SpringHover(0);
        }

        private void Pressed(object sender, PointerRoutedEventArgs args) => state?.InsertScalar("peak", PressedOpacity);

        private void Released(object sender, PointerRoutedEventArgs args) => state?.InsertScalar("peak", RestOpacity);
    }
}
