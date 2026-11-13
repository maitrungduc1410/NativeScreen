using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>Right-to-left captions read from the right in every reveal style (spec/06 ADR-89, the macOS caption checks).</summary>
public sealed class CaptionDirectionTests
{
    private const string Arabic = "مرحبا بكم في التطبيق";

    // A fixed-width measure, so the layout does not depend on installed fonts.
    private static (double Width, double Height) Measure(string text, CaptionFontStyle style, double size) => (text.Length * size * 0.5, size * 1.2);

    private static IReadOnlyList<CaptionLineLayout.DrawnWord> Words(string text, CaptionStyle style, double t)
    {
        var captions = new CaptionsConfig { Enabled = true };
        captions.CaptionTracks = [new CaptionTrack { Id = Guid.NewGuid().ToString(), Style = style }];
        captions.CaptionBlocks = [new CaptionBlock { Id = "b", TrackId = captions.CaptionTracks[0].Id, SourceStartMs = 0, SourceEndMs = 2000, CustomText = text }];
        var frames = CaptionLineLayout.Frames(captions, t, 1280, 720, Measure);
        return frames.Count > 0 ? frames[0].Words : [];
    }

    [Fact]
    public void DirectionComesFromTheFirstStrongLetter()
    {
        Assert.True(CaptionLineLayout.IsRightToLeft(Arabic));
        Assert.True(CaptionLineLayout.IsRightToLeft("2026 שלום"));
        Assert.False(CaptionLineLayout.IsRightToLeft("Hello مرحبا"));
        Assert.False(CaptionLineLayout.IsRightToLeft("123"));
        // Arabic-Indic digits are neutral: the first letter decides.
        Assert.True(CaptionLineLayout.IsRightToLeft("٢٠٢٦ مرحبا"));
    }

    public static IEnumerable<object[]> Styles()
    {
        yield return new object[] { "line", new CaptionStyle() };
        yield return new object[] { "full line", new CaptionStyle { LineGrowth = CaptionLineGrowth.FullLine } };
        yield return new object[] { "slide in", new CaptionStyle { WordAnimation = CaptionWordAnimation.SlideIn } };
        yield return new object[] { "fade in", new CaptionStyle { WordAnimation = CaptionWordAnimation.FadeIn } };
    }

    [Theory]
    [MemberData(nameof(Styles))]
    public void RightToLeftReadsFromTheRightAndLeftToRightFromTheLeft(string name, CaptionStyle style)
    {
        var rtl = Words(Arabic, style, 1990);
        var ltr = Words("Welcome to the app", style, 1990);
        Assert.True(rtl.Count == 4, $"{name}: {rtl.Count} words");
        Assert.True(rtl.Zip(rtl.Skip(1)).All(pair => pair.First.Rect.X > pair.Second.Rect.X + pair.Second.Rect.Width), $"right-to-left caption ({name}) reads from the right");
        Assert.True(ltr.Count == 4, $"{name}: {ltr.Count} words");
        Assert.True(ltr.Zip(ltr.Skip(1)).All(pair => pair.First.Rect.X + pair.First.Rect.Width < pair.Second.Rect.X), $"left-to-right caption ({name}) still reads from the left");
    }

    [Fact]
    public void RightToLeftGrowsFromTheRightEdge()
    {
        var firstWordOnly = Words(Arabic, new CaptionStyle(), 100);
        var fullLine = Words(Arabic, new CaptionStyle(), 1990);
        Assert.Single(firstWordOnly);
        Assert.True(Math.Abs(firstWordOnly[0].Rect.X + firstWordOnly[0].Rect.Width - (fullLine[0].Rect.X + fullLine[0].Rect.Width)) < 0.5, "right-to-left caption grows from the right edge");
    }
}
