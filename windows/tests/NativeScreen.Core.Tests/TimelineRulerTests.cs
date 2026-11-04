using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TimelineRulerTests
{
    [Theory]
    [InlineData(60_000, 1200, 5)]
    [InlineData(60_000, 4800, 2.5)]
    [InlineData(60_000, 24_000, 0.5)]
    [InlineData(600_000, 1200, 60)]
    [InlineData(3_600_000, 1200, 120)]
    [InlineData(500, 1200, 0.5)]
    public void PicksTheClosestRoundInterval(double durationMs, double width, double expected)
    {
        Assert.Equal(expected, TimelineRuler.StepSeconds(durationMs, width));
    }
}
