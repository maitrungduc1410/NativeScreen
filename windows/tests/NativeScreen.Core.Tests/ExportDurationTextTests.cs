using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>The export estimate's time, built from the unit keys macOS uses (spec/06 ADR-44).</summary>
public sealed class ExportDurationTextTests
{
    private static string English(int seconds) => ExportEstimator.DescribeDuration(seconds, (key, count) => key.Replace("%@", count.ToString(System.Globalization.CultureInfo.InvariantCulture), StringComparison.Ordinal));

    [Theory]
    [InlineData(1, "1 second")]
    [InlineData(19, "19 seconds")]
    [InlineData(60, "1 minute")]
    [InlineData(150, "3 minutes")]
    [InlineData(3570, "1 hour")]
    [InlineData(3600, "1 hour")]
    [InlineData(3900, "1 hour 5 minutes")]
    [InlineData(7260, "2 hours 1 minute")]
    public void DescribesSecondsMinutesAndHours(int seconds, string expected) => Assert.Equal(expected, English(seconds));

    [Fact]
    public void AsksForOneKeyPerUnit()
    {
        var keys = new List<string>();
        ExportEstimator.DescribeDuration(3900, (key, count) =>
        {
            keys.Add(key);
            return key;
        });
        Assert.Equal(["1 hour", "%@ minutes"], keys);
    }
}
