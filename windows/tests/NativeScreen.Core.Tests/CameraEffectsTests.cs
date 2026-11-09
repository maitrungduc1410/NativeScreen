using System.Text.Json;
using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class CameraEffectsTests
{
    private static double[] Sample(double ms, double x = 0.4, double eyeY = 0.3) =>
        [ms, x, 0.2, 0.2, 0.3, x + 0.05, eyeY, x + 0.15, eyeY, x + 0.1, 0.4, x + 0.1, 0.45];

    private static FaceTrack Track(double durationMs, params double[][] samples) =>
        new(new StoredFaceTrack { WebcamDurationMs = durationMs, Samples = [.. samples] });

    [Fact]
    public void CameraFieldsLoadWithTheSwiftDefaultsAndRoundTrip()
    {
        var defaults = JsonSerializer.Deserialize<CameraConfig>("{}", ProjectJson.Compact)!;
        Assert.Equal(1.3, defaults.FaceTrackingZoom);
        Assert.Equal(CameraBackgroundMode.Original, defaults.BackgroundMode);
        Assert.Null(defaults.StickerId);

        const string written = """{"backgroundMode":"image","backgroundImagePath":"assets/camera-bg-1a2b3c4d5e6f7a8b.jpg","backgroundImageName":"background-3","stickerId":"crown","faceTrackingZoom":1.7}""";
        var loaded = JsonSerializer.Deserialize<CameraConfig>(written, ProjectJson.Compact)!;
        var again = JsonSerializer.Serialize(loaded, ProjectJson.Compact);
        Assert.Contains("\"backgroundMode\":\"image\"", again);
        Assert.Contains("\"backgroundImageName\":\"background-3\"", again);
        Assert.Contains("\"stickerId\":\"crown\"", again);
        Assert.Contains("\"faceTrackingZoom\":1.7", again);
    }

    [Fact]
    public void AFaceTrackFileWrittenOnMacOSIsReadAsIs()
    {
        const string file = """{"version":1,"webcamDurationMs":1000,"samples":[[0,0.4,0.2,0.2,0.3,0.45,0.3,0.55,0.3,0.5,0.4,0.5,0.45],[66.7,0.4,0.2,0.2,0.3,0.45,0.3,0.55,0.3,0.5,0.4,0.5,0.45]]}""";
        var stored = JsonSerializer.Deserialize<StoredFaceTrack>(file)!;
        var track = new FaceTrack(stored);
        Assert.True(track.HasFaces);
        Assert.Equal(0.45, track.PointsAt(30)!.Value.Points.EyeA.X, 6);
    }

    [Fact]
    public void ShortGapsAreBridgedAndLongOnesFade()
    {
        var track = Track(5000, Sample(0), Sample(400, 0.5), Sample(3000), Sample(3066));
        Assert.Equal(1, track.PointsAt(200)!.Value.Opacity);
        var fading = track.PointsAt(475)!.Value;
        Assert.Equal(0.5, fading.Opacity, 6);
        Assert.Null(track.PointsAt(1500));
        Assert.Equal(0.5, track.PointsAt(2925)!.Value.Opacity, 6);
    }

    [Fact]
    public void SmoothingUsesNeighboursOnBothSidesWithoutLag()
    {
        var track = Track(1000, Sample(0, 0.40), Sample(66, 0.40), Sample(132, 0.50), Sample(198, 0.40), Sample(264, 0.40));
        // (1, 4, 6, 4, 1) / 16 over the spike, and x + 0.05 is the first eye.
        Assert.Equal(0.40 + 0.1 * 6 / 16 + 0.05, track.PointsAt(132)!.Value.Points.EyeA.X, 6);
    }

    [Fact]
    public void FramingIgnoresSmallMovementsInsideTheDeadZone()
    {
        var samples = Enumerable.Range(0, 100).Select(index => Sample(index * 66.0, index % 2 == 0 ? 0.40 : 0.44)).ToArray();
        var track = Track(6600, samples);
        var a = track.FramingCenterAt(2000)!.Value;
        var b = track.FramingCenterAt(4000)!.Value;
        Assert.Equal(a.X, b.X, 6);
        Assert.Equal(0.5, a.X, 6);
    }

    [Fact]
    public void NoSamplesMeansNoFaceAndNoFraming()
    {
        var track = Track(1000);
        Assert.False(track.HasFaces);
        Assert.Null(track.PointsAt(10));
        Assert.Null(track.FramingCenterAt(10));
    }

    private static readonly FacePoints Upright = new(new FacePoint(100, 100), new FacePoint(200, 100), new FacePoint(150, 150), new FacePoint(150, 200));

    [Fact]
    public void AStickerAboveTheEyesGoesUpAndSizesFromTheFace()
    {
        var crown = new CameraSticker("crown", "Crown", "crown.png", "eyes", 2.2, null, 0, 1.8);
        var placement = CameraEffects.Place(crown, Upright, 0.5)!.Value;
        Assert.Equal(150, placement.Center.X, 6);
        Assert.Equal(100 - 180, placement.Center.Y, 6);
        Assert.Equal(220, placement.Width, 6);
        Assert.Equal(110, placement.Height, 6);
        Assert.Equal(0, placement.Angle, 6);
    }

    [Fact]
    public void EyeOrderDoesNotMatterAndTheStickerTiltsWithTheHead()
    {
        var glasses = new CameraSticker("g", "G", "g.png", "eyes", 2, null, 0, 0);
        var swapped = Upright with { EyeA = Upright.EyeB, EyeB = Upright.EyeA };
        Assert.Equal(CameraEffects.Place(glasses, Upright, 1), CameraEffects.Place(glasses, swapped, 1));
        var tilted = new FacePoints(new FacePoint(100, 100), new FacePoint(200, 200), new FacePoint(120, 180), new FacePoint(100, 200));
        Assert.Equal(Math.PI / 4, CameraEffects.Place(glasses, tilted, 1)!.Value.Angle, 6);
    }

    [Fact]
    public void AnchorsAndTheFaceScaleFollowTheSwiftFormula()
    {
        var nose = new CameraSticker("n", "N", "n.png", "nose", 1, 2, 0, 0);
        var mouth = new CameraSticker("m", "M", "m.png", "mouth", 1, null, 0, 0);
        Assert.Equal(new FacePoint(150, 150), CameraEffects.Place(nose, Upright, 1)!.Value.Center);
        Assert.Equal(200, CameraEffects.Place(nose, Upright, 1)!.Value.Height, 6);
        Assert.Equal(new FacePoint(150, 200), CameraEffects.Place(mouth, Upright, 1)!.Value.Center);
        // A head turned sideways: the eyes come closer, the eyes-to-mouth distance holds the scale.
        var turned = Upright with { EyeA = new FacePoint(140, 100), EyeB = new FacePoint(160, 100) };
        Assert.Equal(100.0 / 1.2, CameraEffects.Place(mouth, turned, 1)!.Value.Width, 6);
        var degenerate = Upright with { EyeB = Upright.EyeA };
        Assert.Null(CameraEffects.Place(mouth, degenerate, 1));
    }

    [Fact]
    public void PointsFollowTheCropAndTheFlip()
    {
        var crop = new Rect01(0.25, 0.25, 0.5, 0.5);
        Assert.Equal(new FacePoint(0.5, 0.5), CameraEffects.Mapped(new FacePoint(0.5, 0.5), crop, false));
        Assert.Equal(new FacePoint(0.8, 0.0), CameraEffects.Mapped(new FacePoint(0.35, 0.25), crop, true));
    }

    [Fact]
    public void ABackgroundFileIsNamedAfterItsSourceBytes()
    {
        byte[] hash = [0x1a, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f, 0x7a, 0x8b, 0xff, 0xff];
        Assert.Equal("camera-bg-1a2b3c4d5e6f7a8b.jpg", CameraEffects.BackgroundFileName(hash));
    }

    [Fact]
    public void TheStickerFileShapeParses()
    {
        var list = CameraStickerCatalog.Parse("""{"stickers":[{"id":"bow","name":"Bow","file":"bow.png","anchor":"eyes","width":1.3,"offsetX":1.0,"offsetY":1.8}]}""");
        Assert.Equal(1.3, Assert.Single(list).Width);
        Assert.Null(list[0].Height);
    }
}
