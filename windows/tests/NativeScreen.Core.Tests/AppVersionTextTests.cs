using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class AppVersionTextTests
{
    [Theory]
    [InlineData("Version", "1.0.0", "1.0.0.0", "Microsoft Store", "Version 1.0.0 (Microsoft Store)")]
    [InlineData("Version", "1.2.0", "1.2.0.57", "GitHub", "Version 1.2.0 (57, GitHub)")]
    [InlineData("Phiên bản", "1.2.3-beta.1", "1.2.3.57", "GitHub", "Phiên bản 1.2.3-beta.1 (57, GitHub)")]
    [InlineData("Version", "1.2.0", null, "GitHub", "Version 1.2.0 (GitHub)")]
    [InlineData("Version", "1.2.0", "1.2", "Debug", "Version 1.2.0 (Debug)")]
    public void NamesTheChannelAndTheRunNumberWhenThereIsOne(string word, string version, string? fileVersion, string channel, string expected) =>
        Assert.Equal(expected, AppVersionText.Format(word, version, fileVersion, channel));
}
