using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;

namespace NativeScreen.App;

/// <summary>
/// Names, announcements and Reduce Motion for Narrator, Voice Access and other UI Automation clients (spec/06 ADR-51). Labels
/// are English catalog keys like every other string. Peers are built only when a client asks, so nothing here runs per frame.
/// </summary>
internal static partial class A11y
{
    private static readonly Windows.UI.ViewManagement.UISettings Settings = new();

    /// <summary>Sets a name from an English catalog key.</summary>
    public static void Name(DependencyObject element, string english) => AutomationProperties.SetName(element, Loc.T(english));

    /// <summary>A tooltip without its shortcut suffix: "Split clip (Alt)" names "Split clip". Translated.</summary>
    public static string FromTooltip(string tooltip)
    {
        var translated = Loc.T(tooltip);
        return TrailingShortcut().Replace(translated, "").Trim();
    }

    /// <summary>
    /// An icon-only button takes its tooltip as its name, unless it already has one. A button with text keeps its text and
    /// gets the tooltip as help text.
    /// </summary>
    public static void NameFromTooltip(DependencyObject element, string? tooltip)
    {
        if (tooltip is not { Length: > 0 } || element is not Microsoft.UI.Xaml.Controls.Primitives.ButtonBase button)
        {
            return;
        }

        if (button.Content is string)
        {
            AutomationProperties.SetHelpText(button, Loc.T(tooltip));
        }
        else if (string.IsNullOrEmpty(AutomationProperties.GetName(button)))
        {
            AutomationProperties.SetName(button, FromTooltip(tooltip));
        }
    }

    /// <summary>A button holding an icon and text reads its text, when nothing named it yet.</summary>
    public static void NameFromContent(Microsoft.UI.Xaml.Controls.Primitives.ButtonBase button)
    {
        if (!string.IsNullOrEmpty(AutomationProperties.GetName(button)) || button.Content is not Microsoft.UI.Xaml.Controls.Panel panel)
        {
            return;
        }

        var texts = panel.Children.OfType<Microsoft.UI.Xaml.Controls.TextBlock>().Select(text => text.Text).Where(text => !string.IsNullOrWhiteSpace(text));
        var name = string.Join(" ", texts);
        if (name.Length > 0)
        {
            AutomationProperties.SetName(button, name);
        }
    }

    /// <summary>A thumbnail's state for a screen reader: selected, favorite.</summary>
    public static void Status(DependencyObject element, bool selected, bool favorite = false)
    {
        var parts = new List<string>(2);
        if (selected)
        {
            parts.Add(Loc.T("Selected"));
        }

        if (favorite)
        {
            parts.Add(Loc.T("Favorite"));
        }

        AutomationProperties.SetItemStatus(element, string.Join(", ", parts));
    }

    /// <summary>A built-in wallpaper file is named "spring-01": it reads "Spring 1" in the UI language.</summary>
    public static string WallpaperName(string id)
    {
        var match = NumberedWallpaper().Match(id);
        if (!match.Success)
        {
            return id;
        }

        var category = Array.Find(NativeScreen.Core.BundledWallpaperCatalog.Categories, item => string.Equals(item, match.Groups[1].Value, StringComparison.OrdinalIgnoreCase));
        return category is null ? id : $"{Loc.T(category)} {int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture)}";
    }

    [GeneratedRegex(@"^([A-Za-z]+)-(\d+)$")]
    private static partial Regex NumberedWallpaper();

    /// <summary>Drawing with no meaning of its own (playhead lines, guides, meters): skipped by screen readers.</summary>
    public static void Decorative(UIElement element) => AutomationProperties.SetAccessibilityView(element, AccessibilityView.Raw);

    /// <summary>A timeline time in words in the UI language: "3.2 seconds", "1 minute, 5.2 seconds".</summary>
    public static string Duration(double ms)
    {
        var culture = UiCulture();
        var total = Math.Max(0, ms) / 1000;
        if (total < 60)
        {
            return Loc.F("%@ seconds", total.ToString("0.0", culture));
        }

        var minutes = (int)(total / 60);
        var seconds = (total - minutes * 60).ToString("0.0", culture);
        return minutes == 1 ? Loc.F("1 minute, %@ seconds", seconds) : Loc.F("%lld minutes, %@ seconds", minutes, seconds);
    }

    /// <summary>"From 3.0 seconds to 5.5 seconds".</summary>
    public static string Range(double startMs, double endMs) => Loc.F("From %@ to %@", Duration(startMs), Duration(endMs));

    /// <summary>Reads a message out without moving the screen reader's focus (toasts).</summary>
    public static void Announce(UIElement anchor, string text)
    {
        try
        {
            var peer = FrameworkElementAutomationPeer.FromElement(anchor) ?? FrameworkElementAutomationPeer.CreatePeerForElement(anchor);
            peer?.RaiseNotificationEvent(AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent, text, "toast");
        }
        catch (Exception)
        {
            // An element that left the tree has no peer; the toast still shows.
        }
    }

    /// <summary>Settings > Accessibility > Visual effects > Animation effects turned off.</summary>
    public static bool ReduceMotion
    {
        get
        {
            try
            {
                return !Settings.AnimationsEnabled;
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    private static CultureInfo UiCulture()
    {
        try
        {
            return CultureInfo.GetCultureInfo(Loc.Current);
        }
        catch (CultureNotFoundException)
        {
            return CultureInfo.InvariantCulture;
        }
    }

    [GeneratedRegex(@"\s*[(（][^()（）]*[)）]\s*$")]
    private static partial Regex TrailingShortcut();
}
