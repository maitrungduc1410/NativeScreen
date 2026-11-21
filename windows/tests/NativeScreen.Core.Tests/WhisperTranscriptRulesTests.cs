using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>Whisper's words never overlap, and a project opens on a speech model this computer has (spec/06 ADR-105).</summary>
public sealed class WhisperTranscriptRulesTests
{
    [Fact]
    public void AWordStretchedIntoThePauseEndsWhereTheNextStarts()
    {
        // The owner's Vietnamese recording: "3..." ran to 4460 ms, the next block's "3," started at 4390 ms.
        var words = TranscriptSegments.Normalize([("3...", 2260, 4460), ("3,", 4390, 5190)], 10000);
        Assert.Equal(2, words.Count);
        Assert.Equal(2260, words[0].SourceStartMs);
        Assert.Equal(4390, words[0].SourceEndMs);
        Assert.Equal(4390, words[1].SourceStartMs);
        Assert.Equal(5190, words[1].SourceEndMs);
    }

    [Fact]
    public void WordsAreTrimmedSortedAndNeverOverlap()
    {
        var words = TranscriptSegments.Normalize(
            [(" b ", 1000, 1500), ("a", 0, 1200), ("   ", 1300, 1400), ("c", 1000, 1100), ("d", 9990, 12000), ("e", 12000, 13000)],
            10000);
        Assert.Equal(["a", "b", "c", "d"], words.Select(word => word.Text));
        for (var index = 0; index < words.Count; index++)
        {
            Assert.True(words[index].SourceEndMs > words[index].SourceStartMs, $"word {index} is empty");
            if (index > 0)
            {
                Assert.True(words[index].SourceStartMs >= words[index - 1].SourceEndMs, $"word {index} overlaps");
            }
        }

        // Same start: the first gets 1 ms, the second starts after it. Nothing passes the end of the recording.
        Assert.Equal(1000, words[1].SourceStartMs);
        Assert.Equal(1001, words[1].SourceEndMs);
        Assert.Equal(1001, words[2].SourceStartMs);
        Assert.Equal(10000, words[3].SourceEndMs);
    }

    [Theory]
    [InlineData("small", false, new string[0], null, "small")]
    [InlineData("small", false, new[] { "base" }, null, "base")]
    [InlineData("small", false, new[] { "base", "medium" }, "medium", "medium")]
    [InlineData("small", false, new[] { "base", "small" }, null, "small")]
    [InlineData("small", false, new[] { "base", "medium" }, "small", "base")]
    [InlineData("medium", true, new[] { "base" }, "base", "medium")]
    public void AProjectOpensOnAModelThisComputerHas(string current, bool hasTranscript, string[] installed, string? lastUsed, string expected) =>
        Assert.Equal(expected, WhisperModelChoice.ForOpening(current, hasTranscript, installed, lastUsed));
}
