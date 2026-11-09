using System.Globalization;
using System.Text.Json;
using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class ConformanceTests
{
    public static IEnumerable<object[]> Cases()
    {
        var root = RepoRoot();
        foreach (var dir in Directory.GetDirectories(Path.Combine(root, "conformance", "cases")).OrderBy(path => path, StringComparer.Ordinal))
        {
            yield return new object[] { Path.GetFileName(dir) };
        }
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void MatchesFixture(string caseId)
    {
        var root = RepoRoot();
        var caseDir = Path.Combine(root, "conformance", "cases", caseId);
        var package = Directory.GetDirectories(caseDir, "*.nativescreen").Single();
        var loaded = new LoadedProject(package);
        var expected = Path.Combine(caseDir, "expected");

        AssertJsonEqual(File.ReadAllText(Path.Combine(package, "project.json")), ProjectJson.Serialize(ProjectJson.Deserialize<ProjectDocument>(File.ReadAllText(Path.Combine(package, "project.json")))), $"{caseId} project");
        AssertTimemap(loaded, File.ReadAllText(Path.Combine(expected, "timemap.json")), caseId);
        AssertTrajectory(loaded, File.ReadAllText(Path.Combine(expected, "trajectory.json")), caseId);
        AssertAutoZoom(loaded, File.ReadAllText(Path.Combine(expected, "autozoom.json")), caseId);
        AssertStage(loaded, File.ReadAllText(Path.Combine(expected, "stage.json")), caseId);
        AssertCaptions(loaded, File.ReadAllText(Path.Combine(expected, "captions.json")), caseId);
        AssertShortcuts(loaded, File.ReadAllText(Path.Combine(expected, "shortcuts.json")), caseId);
        AssertEstimates(loaded, File.ReadAllText(Path.Combine(expected, "estimates.json")), caseId);
    }

    [Fact]
    public void UndoRestoresThePreviousDocumentAndDropsTheOldestPast150()
    {
        var current = new ProjectDocument { Name = "start" };
        var stack = new UndoStack(current);
        for (var i = 1; i <= 160; i++)
        {
            var next = ProjectJson.Clone(stack.Current);
            next.Name = $"edit-{i}";
            stack.Commit(next);
        }

        Assert.False(stack.CanRedo);
        Assert.Equal("edit-160", stack.Current.Name);
        stack.Undo();
        Assert.Equal("edit-159", stack.Current.Name);
        stack.Redo();
        Assert.Equal("edit-160", stack.Current.Name);
        for (var i = 0; i < 149; i++)
        {
            stack.Undo();
        }

        Assert.Equal("edit-11", stack.Current.Name);
        Assert.True(stack.CanUndo);
        stack.Undo();
        Assert.False(stack.CanUndo);
    }

    private static void AssertTimemap(LoadedProject loaded, string expectedJson, string caseId)
    {
        using var expected = JsonDocument.Parse(expectedJson);
        foreach (var row in expected.RootElement.EnumerateArray())
        {
            var timeline = row.GetProperty("timelineMs").GetDouble();
            var mapped = loaded.TimeMapper.SourceTime(timeline);
            Close(row.GetProperty("sourceMs").GetDouble(), mapped.SourceMs, $"{caseId} timemap {timeline}");
            Assert.Equal(row.GetProperty("sliceIndex").GetInt32(), loaded.TimeMapper.SliceIndex(timeline));
        }
    }

    private static void AssertTrajectory(LoadedProject loaded, string expectedJson, string caseId)
    {
        using var expected = JsonDocument.Parse(expectedJson);
        foreach (var row in expected.RootElement.EnumerateArray())
        {
            var t = row.GetProperty("sourceMs").GetDouble();
            var eval = loaded.Trajectory.Evaluate(t);
            var cursor = row.GetProperty("cursor");
            Close(cursor.GetProperty("x").GetDouble(), eval.Cursor.Position01.X, $"{caseId} cursor x {t}");
            Close(cursor.GetProperty("y").GetDouble(), eval.Cursor.Position01.Y, $"{caseId} cursor y {t}");
            Close(cursor.GetProperty("rotation").GetDouble(), eval.Cursor.RotationRadians, $"{caseId} cursor rotation {t}");
            Close(cursor.GetProperty("opacity").GetDouble(), eval.Cursor.Opacity, $"{caseId} cursor opacity {t}");
            Assert.Equal(cursor.GetProperty("kind").GetString(), eval.Cursor.CursorType);
            var camera = row.GetProperty("camera");
            Close(camera.GetProperty("scale").GetDouble(), eval.Camera.Scale, $"{caseId} camera scale {t}");
            Close(camera.GetProperty("cx").GetDouble(), eval.Camera.Center01.X, $"{caseId} camera cx {t}");
            Close(camera.GetProperty("cy").GetDouble(), eval.Camera.Center01.Y, $"{caseId} camera cy {t}");
            Close(camera.GetProperty("loupeScale").GetDouble(), eval.Camera.LoupeScale, $"{caseId} loupe scale {t}");
            Close(camera.GetProperty("loupePresence").GetDouble(), eval.Camera.LoupePresence01, $"{caseId} loupe presence {t}");
        }
    }

    private static void AssertAutoZoom(LoadedProject loaded, string expectedJson, string caseId)
    {
        var zooms = AutoZoomClusterGenerator.GenerateZooms(loaded.ClickEvents, loaded.KeyEvents, loaded.Metadata.DurationMs, 2);
        for (var i = 0; i < zooms.Count; i++)
        {
            zooms[i].Id = $"zoom-{i + 1}";
        }

        using var expected = JsonDocument.Parse(expectedJson);
        var rows = expected.RootElement.EnumerateArray().ToList();
        Assert.Equal(rows.Count, zooms.Count);
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            Assert.Equal(row.GetProperty("id").GetString(), zooms[i].Id);
            Close(row.GetProperty("sourceStartMs").GetDouble(), zooms[i].SourceStartMs, $"{caseId} zoom start");
            Close(row.GetProperty("sourceEndMs").GetDouble(), zooms[i].SourceEndMs, $"{caseId} zoom end");
            Close(row.GetProperty("scale").GetDouble(), zooms[i].Scale, $"{caseId} zoom scale");
            Assert.Equal(row.GetProperty("mode").GetString(), zooms[i].Mode == ZoomMode.Manual ? "manual" : "follow-cursor");
            Assert.Equal(row.GetProperty("presentation").GetString(), zooms[i].Presentation == ZoomPresentation.Loupe ? "loupe" : "screen");
            Close(row.GetProperty("manualCenterX").GetDouble(), zooms[i].ManualCenter01.X, $"{caseId} zoom x");
            Close(row.GetProperty("manualCenterY").GetDouble(), zooms[i].ManualCenter01.Y, $"{caseId} zoom y");
        }
    }

    private static void AssertStage(LoadedProject loaded, string expectedJson, string caseId)
    {
        using var expected = JsonDocument.Parse(expectedJson);
        foreach (var row in expected.RootElement.EnumerateArray())
        {
            var canvas = row.GetProperty("canvas");
            var frame = loaded.StageAt(row.GetProperty("sourceMs").GetDouble(), canvas[0].GetDouble(), canvas[1].GetDouble());
            CloseRect(row.GetProperty("screenRect"), frame.ScreenRect, $"{caseId} screen {frame.SourceMs}");
            var camera = row.GetProperty("camera");
            CloseRect(camera.GetProperty("rect"), frame.CameraRect, $"{caseId} camera {frame.SourceMs}");
            Close(camera.GetProperty("cornerRadius").GetDouble(), frame.CornerRadius, $"{caseId} radius");
            Close(camera.GetProperty("opacity").GetDouble(), frame.Opacity, $"{caseId} opacity");
            Close(camera.GetProperty("shadowOpacity").GetDouble(), frame.ShadowOpacity, $"{caseId} shadow");
            Close(camera.GetProperty("borderOpacity").GetDouble(), frame.BorderOpacity, $"{caseId} border");
            Assert.Equal(camera.GetProperty("isCutout").GetBoolean(), frame.IsCutout);
        }
    }

    private static void AssertCaptions(LoadedProject loaded, string expectedJson, string caseId)
    {
        using var expected = JsonDocument.Parse(expectedJson);
        foreach (var row in expected.RootElement.EnumerateArray())
        {
            var t = row.GetProperty("sourceMs").GetDouble();
            var words = CaptionLineLayout.Frames(loaded.Document.Captions, t, 1920, 1080, (text, _, size) => (text.Length * size * 0.5, size * 1.2)).SelectMany(frame => frame.Words).ToList();
            var expectedWords = row.GetProperty("words").EnumerateArray().ToList();
            Assert.Equal(expectedWords.Count, words.Count);
            for (var i = 0; i < words.Count; i++)
            {
                Assert.Equal(expectedWords[i].GetProperty("text").GetString(), words[i].Text);
                Close(expectedWords[i].GetProperty("opacity").GetDouble(), words[i].Opacity, $"{caseId} caption {t}");
                Assert.Equal(expectedWords[i].GetProperty("isSpokenNow").GetBoolean(), words[i].IsSpokenNow);
            }
        }
    }

    private static void AssertShortcuts(LoadedProject loaded, string expectedJson, string caseId)
    {
        var clusters = ShortcutEngine.Detect(loaded.Document, loaded.KeyEvents);
        var typing = ShortcutEngine.TypingSuggestions(loaded.Document, loaded.KeyEvents);
        using var expected = JsonDocument.Parse(expectedJson);
        var expectedClusters = expected.RootElement.GetProperty("clusters").EnumerateArray().ToList();
        Assert.Equal(expectedClusters.Count, clusters.Count);
        for (var i = 0; i < clusters.Count; i++)
        {
            var row = expectedClusters[i];
            Assert.Equal(row.GetProperty("id").GetString(), clusters[i].Id);
            Assert.Equal(row.GetProperty("label").GetString(), clusters[i].Label);
            Assert.Equal(row.GetProperty("primaryKey").GetString(), clusters[i].PrimaryKey);
            Close(row.GetProperty("displayStartMs").GetDouble(), clusters[i].DisplayStartMs, $"{caseId} shortcut start");
            Close(row.GetProperty("displayEndMs").GetDouble(), clusters[i].DisplayEndMs, $"{caseId} shortcut end");
            var caps = row.GetProperty("keyCaps").EnumerateArray().ToList();
            Assert.Equal(caps.Count, clusters[i].KeyCaps.Count);
            for (var c = 0; c < caps.Count; c++)
            {
                Assert.Equal(caps[c].GetProperty("key").GetString(), clusters[i].KeyCaps[c].Key);
                Assert.Equal(caps[c].GetProperty("label").GetString(), clusters[i].KeyCaps[c].Label);
                Close(caps[c].GetProperty("widthRatio").GetDouble(), clusters[i].KeyCaps[c].WidthRatio, $"{caseId} cap");
            }
        }

        var marks = expected.RootElement.GetProperty("envelopes").EnumerateArray().ToList();
        var actual = new List<JsonElement>();
        foreach (var cluster in clusters)
        {
            foreach (var t in new[]
            {
                cluster.DisplayStartMs,
                cluster.DisplayStartMs + 75,
                cluster.DisplayStartMs + 150,
                (cluster.DisplayStartMs + cluster.DisplayEndMs) * 0.5,
                cluster.DisplayEndMs - 90,
                cluster.DisplayEndMs
            })
            {
                var env = ShortcutEngine.Envelope(cluster.DisplayStartMs, cluster.DisplayEndMs, t);
                Close(marks[actual.Count].GetProperty("opacity").GetDouble(), env.Opacity, $"{caseId} envelope {t}");
                Close(marks[actual.Count].GetProperty("scale").GetDouble(), env.Scale, $"{caseId} envelope scale");
                Close(marks[actual.Count].GetProperty("slide").GetDouble(), env.Slide, $"{caseId} envelope slide");
                actual.Add(marks[actual.Count]);
            }
        }

        Assert.Equal(marks.Count, actual.Count);
        var suggestions = expected.RootElement.GetProperty("typingSuggestions").EnumerateArray().ToList();
        Assert.Equal(suggestions.Count, typing.Count);
        for (var i = 0; i < typing.Count; i++)
        {
            Assert.Equal(suggestions[i].GetProperty("startKeyMs").GetInt32(), typing[i].StartKeyMs);
            Close(suggestions[i].GetProperty("sourceStartMs").GetDouble(), typing[i].SourceStartMs, $"{caseId} typing");
            Close(suggestions[i].GetProperty("sourceEndMs").GetDouble(), typing[i].SourceEndMs, $"{caseId} typing end");
        }
    }

    private static void AssertEstimates(LoadedProject loaded, string expectedJson, string caseId)
    {
        var rows = ExportEstimator.Rows(loaded.Document, loaded.Metadata.CaptureTarget.PixelSize.Width, loaded.Metadata.CaptureTarget.PixelSize.Height, loaded.Metadata.DurationMs);
        using var expected = JsonDocument.Parse(expectedJson);
        var expectedRows = expected.RootElement.EnumerateArray().ToList();
        Assert.Equal(expectedRows.Count, rows.Count);
        for (var i = 0; i < rows.Count; i++)
        {
            var row = expectedRows[i];
            Assert.Equal(row.GetProperty("format").GetString(), rows[i].Format);
            Assert.Equal(row.GetProperty("fps").GetInt32(), rows[i].Fps);
            Assert.Equal(row.GetProperty("height").GetInt32(), rows[i].Height);
            Assert.Equal(row.GetProperty("compression").GetString(), rows[i].Compression);
            Assert.Equal(row.GetProperty("codec").GetString(), rows[i].Codec);
            Assert.Equal(row.GetProperty("size").GetString(), rows[i].Size);
            Assert.Equal(row.GetProperty("duration").GetString(), rows[i].Duration);
            Assert.Equal(row.GetProperty("videoBitrate").GetInt32(), rows[i].VideoBitrate);
        }

        _ = caseId;
    }

    private static void AssertJsonEqual(string expectedJson, string actualJson, string name)
    {
        using var expected = JsonDocument.Parse(expectedJson);
        using var actual = JsonDocument.Parse(actualJson);
        Compare(expected.RootElement, actual.RootElement, name);
    }

    private static void Compare(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Number && actual.ValueKind == JsonValueKind.Number)
        {
            Close(expected.GetDouble(), actual.GetDouble(), path);
            return;
        }

        Assert.Equal(expected.ValueKind, actual.ValueKind);
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var actualProps = actual.EnumerateObject().ToDictionary(prop => prop.Name, prop => prop.Value);
                foreach (var prop in expected.EnumerateObject())
                {
                    Assert.True(actualProps.Remove(prop.Name), $"{path}.{prop.Name} missing");
                    Compare(prop.Value, actualProps.Count >= 0 ? actual.GetProperty(prop.Name) : default, $"{path}.{prop.Name}");
                }

                // The fixtures predate these two camera fields. Remove this once they are regenerated on macOS (windows/HANDOFF.md).
                if (path.EndsWith(".camera", StringComparison.Ordinal))
                {
                    if (actualProps.TryGetValue("faceTrackingZoom", out var zoom) && zoom.GetDouble() == 1.3)
                    {
                        actualProps.Remove("faceTrackingZoom");
                    }

                    if (actualProps.TryGetValue("backgroundMode", out var mode) && mode.GetString() == "original")
                    {
                        actualProps.Remove("backgroundMode");
                    }
                }

                Assert.True(actualProps.Count == 0, $"{path} extra {string.Join(',', actualProps.Keys)}");
                break;
            case JsonValueKind.Array:
                var left = expected.EnumerateArray().ToList();
                var right = actual.EnumerateArray().ToList();
                Assert.Equal(left.Count, right.Count);
                for (var i = 0; i < left.Count; i++)
                {
                    Compare(left[i], right[i], $"{path}[{i}]");
                }
                break;
            default:
                Assert.Equal(expected.ToString(), actual.ToString());
                break;
        }
    }

    private static void CloseRect(JsonElement expected, PixelRect actual, string name)
    {
        Close(expected.GetProperty("x").GetDouble(), actual.X, name + " x");
        Close(expected.GetProperty("y").GetDouble(), actual.Y, name + " y");
        Close(expected.GetProperty("width").GetDouble(), actual.Width, name + " w");
        Close(expected.GetProperty("height").GetDouble(), actual.Height, name + " h");
    }

    private static void Close(double expected, double actual, string name)
    {
        var delta = Math.Abs(expected - actual);
        Assert.True(delta <= 1e-4 || delta <= 1e-6 * Math.Max(Math.Abs(expected), Math.Abs(actual)), $"{name}: {actual.ToString(CultureInfo.InvariantCulture)} != {expected.ToString(CultureInfo.InvariantCulture)}");
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "conformance", "README.md")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException("conformance/README.md");
    }
}
