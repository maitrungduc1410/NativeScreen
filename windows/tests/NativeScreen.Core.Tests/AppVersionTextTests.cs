using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class AppVersionTextTests
{
    [Theory]
    [InlineData("Version", "1.0.0", "1.0.0.0", "Version 1.0.0")]
    [InlineData("Version", "1.2.0", "1.2.0.57", "Version 1.2.0 (57)")]
    [InlineData("Phiên bản", "1.2.3-beta.1", "1.2.3.57", "Phiên bản 1.2.3-beta.1 (57)")]
    [InlineData("Version", "1.2.0", null, "Version 1.2.0")]
    [InlineData("Version", "1.2.0", "1.2", "Version 1.2.0")]
    public void ShowsTheRunNumberOnlyWhenThereIsOne(string word, string version, string? fileVersion, string expected) =>
        Assert.Equal(expected, AppVersionText.Format(word, version, fileVersion));
}
