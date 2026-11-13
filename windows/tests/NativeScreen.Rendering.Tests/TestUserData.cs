using System.Runtime.CompilerServices;

namespace NativeScreen.Rendering.Tests;

internal static class TestUserData
{
    /// <summary>
    /// Tests never move or write the real user data folder (spec/06 ADR-90). The folder is kept between runs, so the opt-in
    /// model tests download their models once.
    /// </summary>
    [ModuleInitializer]
    internal static void UseSandbox()
    {
        if (Environment.GetEnvironmentVariable("NS_LOCAL_APP_DATA") is not { Length: > 0 })
        {
            Environment.SetEnvironmentVariable("NS_LOCAL_APP_DATA", Path.Combine(Path.GetTempPath(), "ns-test-local-app-data"));
        }
    }
}
