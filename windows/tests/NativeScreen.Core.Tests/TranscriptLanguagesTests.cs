using System.Globalization;
using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>Every interface language can be picked for a transcript, and each reaches the model as it needs (spec/06 ADR-104).</summary>
public sealed class TranscriptLanguagesTests
{
    [Fact]
    public void EveryInterfaceLanguageIsOffered()
    {
        string[] interfaceLanguages = ["en", "vi", "es", "fr", "de", "it", "pt", "ru", "tr", "cs", "ar", "ja", "ko", "zh-Hans", "zh-Hant"];
        var offered = TranscriptLanguages.Codes.Where(code => code != TranscriptLanguages.Detect).Select(TranscriptLanguages.CultureFor).ToList();
        Assert.All(interfaceLanguages, language => Assert.Contains(language, offered));
        Assert.Equal(TranscriptLanguages.Codes.Length, TranscriptLanguages.Codes.Distinct().Count());
        // The two Chinese entries are named apart.
        Assert.NotEqual(CultureInfo.GetCultureInfo(TranscriptLanguages.CultureFor("zh_CN")).DisplayName, CultureInfo.GetCultureInfo(TranscriptLanguages.CultureFor("zh_TW")).DisplayName);
    }

    [Theory]
    [InlineData("vi_VN", "vi")]
    [InlineData("pt_BR", "pt")]
    [InlineData("ar_SA", "ar")]
    [InlineData("cs_CZ", "cs")]
    [InlineData("en-US", "en")]
    [InlineData("zh_CN", "zh")]
    [InlineData("zh_TW", "zh")]
    public void TheModelGetsTheTwoLetterCode(string locale, string expected) =>
        Assert.Equal(expected, TranscriptLanguages.ForModel(locale, null).Language);

    [Fact]
    public void DetectLeavesTheLanguageToTheModel() =>
        Assert.Null(TranscriptLanguages.ForModel(TranscriptLanguages.Detect, "Native Screen").Language);

    [Fact]
    public void TraditionalChineseIsAskedForWithItsOwnCharacters()
    {
        Assert.Equal("", TranscriptLanguages.ForModel("zh_CN", null).Prompt);
        Assert.Equal("Native Screen", TranscriptLanguages.ForModel("zh_CN", " Native Screen ").Prompt);
        var traditional = TranscriptLanguages.ForModel("zh_TW", "Native Screen").Prompt;
        Assert.StartsWith("以下是繁體中文", traditional);
        Assert.EndsWith("Native Screen", traditional);
        Assert.StartsWith("以下是繁體中文", TranscriptLanguages.ForModel("zh-HK", null).Prompt);
    }
}
