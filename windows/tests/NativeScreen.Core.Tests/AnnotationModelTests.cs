using System.Text.Json;
using System.Text.Json.Nodes;

namespace NativeScreen.Core.Tests;

public sealed class AnnotationModelTests
{
    // What the macOS app writes for every annotation kind and the new camera and cursor fields (spec/02).
    private const string MacTimeline = """
    {
      "annotationTracks": [
        {
          "id": "track-a", "name": "Annotations", "isHidden": false,
          "items": [
            { "id": "t1", "sourceStartMs": 0, "sourceEndMs": 2000, "kind": "text", "anchor": "canvas", "text": "Hello", "fontSizeRatio": 0.5, "color": "#FFFFFF", "enter": "typewriter", "exit": "fade", "animationMs": 300, "futureField": 7 },
            { "id": "a1", "sourceStartMs": 1000, "sourceEndMs": 3000, "kind": "arrow", "from01": { "x": 0.3, "y": 0.8 }, "to01": { "x": 0.4, "y": 0.6 }, "bend": 2 },
            { "id": "p1", "sourceStartMs": 5000, "sourceEndMs": 6000, "kind": "pen", "points01": [{ "x": 0, "y": 0 }, { "x": 1, "y": 1 }, { "x": 0.5, "y": 0.5 }], "pointTimesMs": [0, 10, 20], "strokeStarts": [2, 0, 9], "highlighter": true },
            { "id": "s1", "sourceStartMs": 5500, "sourceEndMs": 7000, "kind": "step", "rotationDegrees": 540, "keyframes": [{ "sourceMs": 6000, "position01": { "x": 0.2, "y": 0.2 }, "from01": { "x": 0, "y": 0 }, "to01": { "x": 0, "y": 0 }, "size01": { "width": 0.1, "height": 0.1 }, "rotationDegrees": 0 }, { "sourceMs": 5600, "position01": { "x": 0.1, "y": 0.1 }, "from01": { "x": 0, "y": 0 }, "to01": { "x": 0, "y": 0 }, "size01": { "width": 0.1, "height": 0.1 }, "rotationDegrees": 0 }] }
          ]
        }
      ]
    }
    """;

    [Fact]
    public void MacItemsReadWithTheSwiftDefaultsAndLimits()
    {
        var timeline = ProjectJson.Deserialize<TimelineConfig>(MacTimeline);
        var items = timeline.AnnotationTracks[0].Items;
        Assert.Equal(AnnotationItem.FontSizeMax, items[0].FontSizeRatio);
        Assert.Equal(AnnotationAnchor.Canvas, items[0].Anchor);
        Assert.Equal(AnnotationAnimation.Typewriter, items[0].Enter);
        Assert.Equal(AnnotationItem.BendMax, items[1].Bend);
        Assert.Equal(AnnotationItem.DefaultArrowColor, items[1].Color);
        Assert.Equal([2], items[2].StrokeStarts);
        Assert.True(items[2].Highlighter);
        Assert.Equal(180, items[3].RotationDegrees);
        Assert.Equal(5600, items[3].Keyframes[0].SourceMs);

        // An unknown field survives, and the arrow's color is written out.
        var written = JsonNode.Parse(ProjectJson.Serialize(timeline))!["annotationTracks"]![0]!["items"]!;
        Assert.Equal(7, written[0]!["futureField"]!.GetValue<int>());
        Assert.Equal("#FF5A36", written[1]!["color"]!.GetValue<string>());
    }

    [Fact]
    public void OverlappingItemsAreRepackedKeepingTheFirstTrack()
    {
        var timeline = ProjectJson.Deserialize<TimelineConfig>(MacTimeline);
        // Track has 0-2000, 1000-3000 (overlap), 5000-6000 and 5500-7000 (overlap).
        Assert.True(AnnotationTrack.RepackOverlapping(timeline.AnnotationTracks));
        Assert.Equal(2, timeline.AnnotationTracks.Count);
        Assert.Equal("track-a", timeline.AnnotationTracks[0].Id);
        Assert.Equal("Annotations 2", timeline.AnnotationTracks[1].Name);
        Assert.Equal(["t1", "p1"], timeline.AnnotationTracks[0].Items.Select(item => item.Id));
        Assert.False(AnnotationTrack.RepackOverlapping(timeline.AnnotationTracks));
    }

    [Fact]
    public void KeyframesEaseAndRotateTheShortWay()
    {
        var item = new AnnotationItem { Keyframes = [new AnnotationKeyframe { SourceMs = 0, RotationDegrees = 170 }, new AnnotationKeyframe { SourceMs = 1000, RotationDegrees = -170 }] };
        Assert.Equal(180, item.Resolved(500).RotationDegrees, 6);
        Assert.Equal(170, item.Resolved(-5).RotationDegrees, 6);
        var plain = new AnnotationItem();
        Assert.Same(plain, plain.Resolved(10));
    }

    [Fact]
    public void AnimationsMatchTheSwiftCurves()
    {
        var item = new AnnotationItem { SourceStartMs = 0, SourceEndMs = 1000, Enter = AnnotationAnimation.Pop, Exit = AnnotationAnimation.Rise, AnimationMs = 200 };
        var entering = item.AnimationState(100);
        Assert.InRange(entering.Scale, 0.9, 1.1);
        Assert.Equal(1, item.AnimationState(500).Opacity);
        Assert.True(item.AnimationState(950).OffsetY < 0);
    }

    [Fact]
    public void DeviceRecordingsOpenAsDisplayAndCameraOnlyLoads()
    {
        var device = ProjectJson.Deserialize<CaptureTargetMetadata>("""{ "mode": "device" }""");
        Assert.Equal(CaptureTargetMode.Display, device.Mode);
        var camera = ProjectJson.Deserialize<CaptureTargetMetadata>("""{ "mode": "camera" }""");
        Assert.Equal(CaptureTargetMode.Camera, camera.Mode);
        Assert.Contains("\"camera\"", ProjectJson.Serialize(camera));
    }

    [Fact]
    public void PresetsKeepHowTheRecordingWasMade()
    {
        var document = new ProjectDocument();
        document.Camera.BackgroundRemoval = CameraBackgroundRemoval.GreenScreen;
        document.Camera.ChromaKeyColor = CameraConfig.BlueScreenColor;
        document.Camera.CameraOnlyFraming = CameraOnlyFraming.Cutout;
        var preset = new ProjectPreset { Camera = new CameraConfig { Mirror = true } };
        preset.Apply(document);
        Assert.True(document.Camera.Mirror);
        Assert.Equal(CameraBackgroundRemoval.GreenScreen, document.Camera.BackgroundRemoval);
        Assert.Equal(CameraConfig.BlueScreenColor, document.Camera.ChromaKeyColor);
        Assert.Equal(CameraOnlyFraming.Cutout, document.Camera.CameraOnlyFraming);
    }

    [Fact]
    public void CustomCursorsAndCameraFieldsRoundTrip()
    {
        var json = """{ "customPointer": { "imagePath": "assets/cursors/a.png", "hotspot01": { "x": 0.1, "y": 0.2 } } }""";
        var cursor = ProjectJson.Deserialize<CursorConfig>(json);
        Assert.Equal("assets/cursors/a.png", cursor.CustomPointer!.ImagePath);
        Assert.Null(cursor.CustomHand);
        var camera = ProjectJson.Deserialize<CameraConfig>("""{ "backgroundRemoval": "green-screen", "cameraOnlyFraming": "full-frame", "chromaSpill": 0 }""");
        Assert.Equal(CameraOnlyFraming.FullFrame, camera.CameraOnlyFraming);
        Assert.Equal(0, camera.ChromaSpill);
        Assert.Equal(0.4, camera.ChromaSimilarity);
        using var written = JsonDocument.Parse(ProjectJson.Serialize(camera));
        Assert.Equal("green-screen", written.RootElement.GetProperty("backgroundRemoval").GetString());
    }

    [Fact]
    public void ASingleClickWithThePenDrawsOnInsteadOfStayingHidden()
    {
        // One point at 0 ms: there is no drawing time to replay, so the dot draws on over the animation.
        var dot = new AnnotationItem { Kind = AnnotationKind.Pen, SourceStartMs = 0, SourceEndMs = 3000, Enter = AnnotationAnimation.Draw, AnimationMs = 300, Points01 = [new Point01(0.5, 0.5)], PointTimesMs = [0] };
        Assert.Equal(0, dot.AnimationState(0).DrawProgress, 6);
        Assert.Equal(1, dot.AnimationState(1000).DrawProgress, 6);

        // A stroke with drawing time still replays at the speed it was drawn.
        var stroke = new AnnotationItem { Kind = AnnotationKind.Pen, SourceStartMs = 0, SourceEndMs = 3000, Enter = AnnotationAnimation.Draw, AnimationMs = 300, Points01 = [new Point01(0, 0), new Point01(1, 1)], PointTimesMs = [0, 1000] };
        Assert.Equal(0.5, stroke.AnimationState(500).DrawProgress, 6);
    }
}
