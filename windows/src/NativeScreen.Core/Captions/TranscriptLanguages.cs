namespace NativeScreen.Core;

/// <summary>
/// The spoken languages offered for an on-device transcript, and what the speech model is told for each (spec/06 ADR-104).
/// Every language the app's interface has is here; Whisper knows them all.
/// </summary>
public static class TranscriptLanguages
{
    /// <summary>Lets the model detect the language.</summary>
    public const string Detect = "auto";

    /// <summary>The picker's order: Detect, then the app's interface languages.</summary>
    public static readonly string[] Codes =
    [
        Detect, "en_US", "vi_VN", "es_ES", "fr_FR", "de_DE", "it_IT", "pt_BR", "ru_RU", "tr_TR", "cs_CZ", "ar_SA", "ja_JP", "ko_KR", "zh_CN", "zh_TW"
    ];

    // Whisper has one code for Chinese and writes Simplified characters unless the prompt is in Traditional ones.
    private const string TraditionalChinesePrompt = "以下是繁體中文的句子。";

    /// <summary>
    /// The model's language code ("vi"), or null to detect it, and the prompt to give it: the user's prompt, after a
    /// Traditional Chinese sentence for Taiwan and Hong Kong Chinese so the words come out in Traditional characters.
    /// </summary>
    public static (string? Language, string Prompt) ForModel(string locale, string? userPrompt)
    {
        var prompt = userPrompt?.Trim() ?? "";
        var parts = locale.Split('_', '-');
        var language = parts[0].ToLowerInvariant();
        if (language.Length != 2)
        {
            return (null, prompt);
        }

        var region = parts.Length > 1 ? parts[1] : "";
        var traditional = language == "zh" && (region.Equals("TW", StringComparison.OrdinalIgnoreCase) || region.Equals("HK", StringComparison.OrdinalIgnoreCase) || region.Equals("Hant", StringComparison.OrdinalIgnoreCase));
        return (language, traditional ? (prompt.Length == 0 ? TraditionalChinesePrompt : TraditionalChinesePrompt + " " + prompt) : prompt);
    }

    /// <summary>The culture a picker names a language with: Chinese by script, so the two entries differ.</summary>
    public static string CultureFor(string locale) => locale switch
    {
        "zh_CN" => "zh-Hans",
        "zh_TW" => "zh-Hant",
        _ => locale.Split('_', '-')[0]
    };
}
