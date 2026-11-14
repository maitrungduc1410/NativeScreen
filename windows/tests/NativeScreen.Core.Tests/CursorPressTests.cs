using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

/// <summary>The cursor presses in on clicks, with the macOS timing (spec/06 ADR-95).</summary>
public sealed class CursorPressTests
{
    private static ClickEvent Click(double t, string type, string button = "left") => new() { T = t, Type = type, Button = button };

    private static double At(double t, params ClickEvent[] clicks) =>
        SpringTrajectorySolver.PressAmount(t, SpringTrajectorySolver.ButtonPresses(clicks));

    [Fact]
    public void AQuickClickEasesInHoldsAndEasesOut()
    {
        ClickEvent[] click = [Click(1000, "down"), Click(1060, "up")];
        Assert.Equal(0, At(969, click));
        Assert.Equal(0.5, At(1005, click), 6);
        Assert.Equal(1, At(1040, click));
        // Held at least 120 ms, then 140 ms out.
        Assert.Equal(1, At(1120, click));
        Assert.Equal(0.5, At(1190, click), 6);
        Assert.Equal(0, At(1260, click));
    }

    [Fact]
    public void ALongHoldStaysDownUntilTheButtonGoesUp()
    {
        ClickEvent[] hold = [Click(0, "down"), Click(900, "up")];
        Assert.Equal(1, At(800, hold));
        Assert.Equal(0.5, At(970, hold), 6);
    }

    [Fact]
    public void ADoubleClickDoesNotSnapUpBetweenPresses()
    {
        ClickEvent[] twice = [Click(1000, "down"), Click(1050, "up"), Click(1150, "down"), Click(1200, "up")];
        // The second press eases in while the first eases out; the larger one keeps the cursor most of the way down.
        for (var t = 1040.0; t <= 1270; t += 5)
        {
            Assert.True(At(t, twice) > 0.75, $"t = {t}");
        }

        Assert.Equal(1, At(1250, twice));
    }

    [Fact]
    public void HeldStartsPressedAndOtherButtonsAndUpsAreIgnored()
    {
        Assert.Equal(1, At(0, Click(0, "held"), Click(400, "up")));
        Assert.Equal(0, At(1040, Click(1000, "down", "other"), Click(1060, "up", "other")));
        // A down with no up holds for the minimum.
        Assert.Equal(1, At(1110, Click(1000, "down")));
        Assert.Equal(0, At(1260, Click(1000, "down")));
        // An up of the other button does not end the press.
        Assert.Equal(1, At(1500, Click(1000, "down"), Click(1100, "up", "right"), Click(1600, "up")));
    }

    [Fact]
    public void TheSkipIndexGivesTheSameAmount()
    {
        var presses = SpringTrajectorySolver.ButtonPresses([Click(0, "down"), Click(60, "up"), Click(2000, "down"), Click(2060, "up")]);
        Assert.Equal(SpringTrajectorySolver.PressAmount(2040, presses), SpringTrajectorySolver.PressAmount(2040, presses, 1));
    }
}
