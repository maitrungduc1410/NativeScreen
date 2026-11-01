using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class RenderingMathTests
{
    [Fact]
    public void HexFallsBackAndParsesAlpha()
    {
        var fallback = Rgba.ParseHex("nope");
        Assert.Equal(0.28, fallback.R);
        Assert.Equal(0.46, fallback.G);
        Assert.Equal(0.90, fallback.B);
        var white = Rgba.ParseHex("#FFFFFF80");
        Assert.Equal(1, white.R);
        Assert.Equal(128 / 255.0, white.A, 6);
    }

    [Fact]
    public void Bt709LimitedRoundTripsAMidGray()
    {
        var encoded = Rgba.Opaque(0.5, 0.5, 0.5).ToBt709Limited();
        var decoded = Rgba.Bt709LimitedToRgb(encoded.Y, encoded.Cb, encoded.Cr);
        Assert.InRange(Math.Abs(decoded.R - 0.5), 0, 1e-4);
        Assert.InRange(Math.Abs(decoded.G - 0.5), 0, 1e-4);
        Assert.InRange(Math.Abs(decoded.B - 0.5), 0, 1e-4);
    }

    [Fact]
    public void SourceOverCompositesPremultipliedStraightColor()
    {
        var over = Rgba.Opaque(1, 0, 0) with { A = 0.5 };
        var under = Rgba.Opaque(0, 0, 1);
        var result = over.SourceOver(under);
        Assert.Equal(0.5, result.R, 6);
        Assert.Equal(0.5, result.B, 6);
        Assert.Equal(1, result.A, 6);
    }

    [Fact]
    public void ScreenMetricsMatchTheCanvasScale()
    {
        var frame = new FrameStyleConfig();
        Assert.Equal(12.8, CompositeMetrics.ScreenCornerRadius(frame, 720), 6);
        var shadow = CompositeMetrics.ScreenShadow(frame.Shadow, 720, 12.8);
        Assert.InRange(Math.Abs(shadow.OffsetX), 0, 1e-9);
        Assert.Equal(9.68, shadow.OffsetY, 6);
        Assert.Equal(12.96, shadow.Sigma, 6);
        var click = CompositeMetrics.Click(0.5, 720.0 / 900.0, 1.6, 1);
        Assert.NotNull(click);
        Assert.Equal(29.44, click.Value.Radius, 6);
        Assert.Equal(0.36, click.Value.Alpha, 6);
        Assert.Equal(79, CompositeMetrics.KeycapHeight(720, 0.11));
        Assert.Equal(32.4, CompositeMetrics.CaptionFontPx(720, 0.045), 6);
    }

    [Fact]
    public void MotionBlurCapsStayOffThePerFrame4KPath()
    {
        Assert.Equal(8, CompositeMetrics.MotionBlurSampleCap(false));
        Assert.Equal(24, CompositeMetrics.MotionBlurSampleCap(true));
        Assert.Equal(10, CompositeMetrics.MotionBlurPixelsPerSample(false));
        Assert.Equal(3, CompositeMetrics.MotionBlurPixelsPerSample(true));
    }

    [Fact]
    public void PassOrderSkipsBlurAtTheFirstFrameAndAtAPausedEnd()
    {
        var document = new ProjectDocument();
        var camera = new SpringTrajectorySolver.CameraFrameState();
        var start = CompositePlanBuilder.Build(document, camera, 0, false, true, 0, 6000);
        Assert.DoesNotContain(start, pass => pass.Kind == CompositePassKind.MotionBlur);
        Assert.Contains(start, pass => pass.Kind == CompositePassKind.Keycaps);
        Assert.DoesNotContain(start, pass => pass.Kind == CompositePassKind.Captions);

        var playing = CompositePlanBuilder.Build(document, camera, 400, false, true, 400, 6000);
        Assert.Contains(playing, pass => pass.Kind == CompositePassKind.MotionBlur && pass.Detail == "samples=8");

        var export = CompositePlanBuilder.Build(document, camera, 400, true, false, 6000, 6000);
        Assert.Contains(export, pass => pass.Detail == "samples=24");

        var paused = CompositePlanBuilder.Build(document, camera, 400, false, false, 6000, 6000);
        Assert.DoesNotContain(paused, pass => pass.Kind == CompositePassKind.MotionBlur);
    }

    [Fact]
    public void LoupeAddsTheLensPass()
    {
        var camera = new SpringTrajectorySolver.CameraFrameState { LoupePresence01 = 1, LoupeScale = 2 };
        var passes = CompositePlanBuilder.Build(new ProjectDocument(), camera, 400, true, true, 400, 6000);
        var lens = passes.Select(pass => pass.Kind).ToList();
        Assert.True(lens.IndexOf(CompositePassKind.Lens) > lens.IndexOf(CompositePassKind.Screen));
        Assert.True(lens.IndexOf(CompositePassKind.Camera) > lens.IndexOf(CompositePassKind.Lens));
    }

    [Fact]
    public void MeshPresetsMatchTheSwiftCatalog()
    {
        Assert.Equal(8, MeshPreset.BuiltIn.Count);
        Assert.Equal("#00D2FF", MeshPreset.Find("spring-aurora").ColorsHex[0]);
        Assert.Equal("spring-aurora", MeshPreset.Find("missing").Id);
    }

    [Fact]
    public void CursorFileNameCarriesTheHotspot()
    {
        var sprite = CursorSpriteName.Parse("pointer-1__12-6.svg", "arrow");
        Assert.Equal("pointer", sprite.Kind);
        Assert.Equal(1, sprite.Variant);
        Assert.Equal(0.12, sprite.HotspotX);
        Assert.Equal(0.06, sprite.HotspotY);
        Assert.Equal("touch", CursorSpriteName.NormalizeThemeId("touch-legacy"));
        Assert.Equal("arrow", CursorSpriteName.NormalizeThemeId("nope"));
    }

    [Fact]
    public void StudioLutIsRedFastest()
    {
        var path = FindRepoFile(Path.Combine("conformance", "looks", "studio.cube"));
        var lut = CubeLut.Parse(File.ReadAllText(path));
        Assert.Equal(33, lut.Size);
        Assert.Equal(33 * 33 * 33 * 3, lut.Rgb.Length);
        for (var red = 0; red < 11; red++)
        {
            var sample = lut.Sample(red, 0, 0);
            Assert.Equal(1, sample.G, 3);
            Assert.Equal(1, sample.B, 3);
        }

        Assert.True(lut.Sample(2, 0, 0).R > lut.Sample(0, 0, 0).R);
    }

    [Fact]
    public void LookBlendIsALerp()
    {
        var blended = Rgba.Opaque(0, 0, 0).BlendLook(Rgba.Opaque(1, 0, 0), 0.25);
        Assert.Equal(0.25, blended.R, 6);
    }

    private static string FindRepoFile(string relative)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, relative);
            if (File.Exists(candidate))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(relative);
    }
}
