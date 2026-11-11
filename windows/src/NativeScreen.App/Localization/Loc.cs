using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace NativeScreen.App;

/// <summary>
/// UI text in the chosen language. Strings come from the macOS catalog (`Localizable.xcstrings`), shipped as content, so both
/// apps share one set of translations. A string is looked up by its English text and falls back to it (spec/06 ADR-44).
/// </summary>
internal static partial class Loc
{
    /// <summary>
    /// The languages the catalog has, each with its own name for the picker, in the macOS order. Empty id means the system
    /// language. Arabic text runs right to left inside its controls; the editor keeps its left-to-right layout (spec/06 ADR-44).
    /// </summary>
    public static readonly (string Id, string Name)[] Languages =
    [
        ("en", "English"),
        ("cs", "Čeština"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("pt-BR", "Português (Brasil)"),
        ("tr", "Türkçe"),
        ("vi", "Tiếng Việt"),
        ("ru", "Русский"),
        ("ar", "العربية"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文")
    ];

    private static Dictionary<string, string>? table;

    /// <summary>The language in use for this run. A change in settings applies on the next launch.</summary>
    public static string Current { get; private set; } = "en";

    /// <summary>Picks the language once at startup, before any window is made.</summary>
    public static void Start(string? chosen)
    {
        Current = string.IsNullOrEmpty(chosen) || !Array.Exists(Languages, item => item.Id == chosen) ? SystemLanguage() : chosen;
        table = Current == "en" ? [] : Load(Current);
        if (!string.IsNullOrEmpty(chosen))
        {
            // System-drawn text (pickers, dialogs) follows too. An unpackaged app may not have this.
            try
            {
                Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = chosen;
            }
            catch (Exception)
            {
            }
        }

        try
        {
            var culture = CultureInfo.GetCultureInfo(Current);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            CultureInfo.CurrentUICulture = culture;
        }
        catch (CultureNotFoundException)
        {
        }
    }

    /// <summary>
    /// A track name, translated when it is a default one ("Captions", "Captions 2"). Names are stored in English, so projects do
    /// not depend on the UI language; a name the user typed has no catalog entry and shows as it is.
    /// </summary>
    public static string TrackName(string name)
    {
        var whole = T(name);
        if (whole != name)
        {
            return whole;
        }

        var space = name.LastIndexOf(' ');
        if (space > 0 && int.TryParse(name.AsSpan(space + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var number))
        {
            var stem = name[..space];
            if (table is not null && table.ContainsKey(stem + " %lld"))
            {
                return F(stem + " %lld", number);
            }

            var translated = T(stem);
            if (translated != stem)
            {
                return translated + " " + number.ToString(CultureInfo.CurrentCulture);
            }
        }

        return name;
    }

    /// <summary>Translates the plain text set in a window's XAML: text, tooltips, button content, placeholders.</summary>
    public static void Apply(object? element)
    {
        // Walked in English too: tooltips also name icon-only buttons (spec/06 ADR-51).
        if (element is null)
        {
            return;
        }

        switch (element)
        {
            case Microsoft.UI.Xaml.Controls.TextBlock text:
                text.Text = T(text.Text);
                break;
            case Microsoft.UI.Xaml.Controls.TextBox box:
                box.PlaceholderText = T(box.PlaceholderText);
                break;
            case Microsoft.UI.Xaml.Controls.Primitives.ButtonBase composite when composite.Content is Microsoft.UI.Xaml.Controls.Panel:
                Apply(composite.Content);
                // A tooltip names the button better than its label (the title button shows only part of the name).
                if (Microsoft.UI.Xaml.Controls.ToolTipService.GetToolTip(composite) is not string)
                {
                    A11y.NameFromContent(composite);
                }

                break;
            case Microsoft.UI.Xaml.Controls.ContentControl control:
                if (control.Content is string content)
                {
                    control.Content = T(content);
                }
                else
                {
                    Apply(control.Content);
                }

                break;
            case Microsoft.UI.Xaml.Controls.Panel panel:
                foreach (var child in panel.Children)
                {
                    Apply(child);
                }

                break;
            case Microsoft.UI.Xaml.Controls.Border border:
                Apply(border.Child);
                break;
            case Microsoft.UI.Xaml.Controls.UserControl user:
                Apply(user.Content);
                break;
        }

        if (element is Microsoft.UI.Xaml.DependencyObject dependency && Microsoft.UI.Xaml.Controls.ToolTipService.GetToolTip(dependency) is string tip)
        {
            Microsoft.UI.Xaml.Controls.ToolTipService.SetToolTip(dependency, T(tip));
            A11y.NameFromTooltip(dependency, tip);
        }

        if (element is Microsoft.UI.Xaml.Controls.ScrollViewer scroller)
        {
            Apply(scroller.Content);
        }
    }

    /// <summary>The translation of an English UI string, or the string itself.</summary>
    [return: System.Diagnostics.CodeAnalysis.NotNullIfNotNull(nameof(english))]
    public static string? T(string? english)
    {
        if (string.IsNullOrEmpty(english) || table is null || table.Count == 0)
        {
            return english;
        }

        return table.TryGetValue(english, out var value) ? value : english;
    }

    /// <summary>A catalog key with format specifiers (`%lld`, `%@`), filled in order.</summary>
    public static string F(string key, params object[] values)
    {
        var text = table is not null && table.TryGetValue(key, out var value) ? value : key;
        var index = 0;
        var format = Specifier().Replace(text.Replace("{", "{{").Replace("}", "}}"), match =>
        {
            if (match.Value == "%%")
            {
                return "%";
            }

            var position = match.Groups[1].Success ? int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : index++;
            return "{" + position.ToString(CultureInfo.InvariantCulture) + "}";
        });
        return string.Format(CultureInfo.CurrentCulture, format, values);
    }

    /// <summary>The catalog id for the system's UI language, or English.</summary>
    public static string SystemLanguage()
    {
        var name = CultureInfo.InstalledUICulture.Name;
        try
        {
            if (Windows.System.UserProfile.GlobalizationPreferences.Languages is { Count: > 0 } preferred)
            {
                name = preferred[0];
            }
        }
        catch (Exception)
        {
        }

        return Match(name);
    }

    public static string Match(string tag)
    {
        var lower = tag.ToLowerInvariant();
        if (lower.StartsWith("zh", StringComparison.Ordinal))
        {
            return lower.Contains("hant") || lower.EndsWith("-tw", StringComparison.Ordinal) || lower.EndsWith("-hk", StringComparison.Ordinal) || lower.EndsWith("-mo", StringComparison.Ordinal) ? "zh-Hant" : "zh-Hans";
        }

        if (lower.StartsWith("pt", StringComparison.Ordinal))
        {
            return "pt-BR";
        }

        var primary = lower.Split('-')[0];
        return Array.Find(Languages, item => item.Id == primary).Id ?? "en";
    }

    /// <summary>Reads one language out of the catalog.</summary>
    public static Dictionary<string, string> Load(string language, string? path = null)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        path ??= Path.Combine(AppContext.BaseDirectory, "Localization", "Localizable.xcstrings");
        if (!File.Exists(path))
        {
            return result;
        }

        using var stream = File.OpenRead(path);
        using var document = JsonDocument.Parse(stream);
        foreach (var entry in document.RootElement.GetProperty("strings").EnumerateObject())
        {
            if (entry.Value.TryGetProperty("localizations", out var localizations)
                && localizations.TryGetProperty(language, out var localized)
                && localized.TryGetProperty("stringUnit", out var unit)
                && unit.TryGetProperty("value", out var text)
                && text.GetString() is { Length: > 0 } value)
            {
                result[entry.Name] = value;
            }
        }

        return result;
    }

    [GeneratedRegex(@"%%|%(?:(\d+)\$)?(?:lld|ld|lu|llu|d|u|@|g|f|\.\d+f|s)")]
    private static partial Regex Specifier();
}
