using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class TranscriptEditingTests
{
    private static ProjectDocument Document(params (double Start, double End)[] slices)
    {
        var document = new ProjectDocument();
        document.Timeline.Slices = slices.Select(slice => new ClipSlice { Id = EditorSession.NewId(), SourceStartMs = slice.Start, SourceEndMs = slice.End }).ToList();
        return document;
    }

    private static CaptionSegment Word(string text, double start, double end) => new() { Id = EditorSession.NewId(), Text = text, SourceStartMs = start, SourceEndMs = end };

    [Fact]
    public void CuttingTheMiddleSplitsAndShortEndsAreDropped()
    {
        var document = Document((0, 10000));
        TranscriptEditing.CutSourceRange(document, 4000, 5000);
        Assert.Equal([(0.0, 4000.0), (5000.0, 10000.0)], document.Timeline.Slices.Select(slice => (slice.SourceStartMs, slice.SourceEndMs)));

        TranscriptEditing.CutSourceRange(document, 50, 3000);
        Assert.Equal(3000, document.Timeline.Slices[0].SourceStartMs);
    }

    [Fact]
    public void TheWholeVideoCanNeverBeCut()
    {
        var document = Document((0, 1000));
        TranscriptEditing.CutSourceRange(document, 0, 1000);
        Assert.Single(document.Timeline.Slices);
    }

    [Fact]
    public void RestoreBridgesTheTwoSidesOfACut()
    {
        var document = Document((0, 4000), (5000, 10000));
        TranscriptEditing.RestoreSourceRange(document, 4000, 5000, 10000);
        var slice = Assert.Single(document.Timeline.Slices);
        Assert.Equal(0, slice.SourceStartMs);
        Assert.Equal(10000, slice.SourceEndMs);
    }

    [Fact]
    public void FillersAndPausesAreFoundOnlyWhileStillInTheVideo()
    {
        var document = Document((0, 10000));
        document.Captions.Segments = [Word("Um,", 100, 300), Word("hello", 300, 700), Word("world", 2000, 2400)];
        Assert.True(TranscriptEditing.IsFillerWord("  UH. "));
        Assert.False(TranscriptEditing.IsFillerWord("umbrella"));
        Assert.Single(TranscriptEditing.PresentFillers(document));
        Assert.Equal([(700.0, 2000.0)], TranscriptEditing.TightenablePauses(document));

        TranscriptEditing.TightenPauses(document);
        Assert.Equal([(0.0, 800.0), (1900.0, 10000.0)], document.Timeline.Slices.Select(slice => (slice.SourceStartMs, slice.SourceEndMs)));
        Assert.Empty(TranscriptEditing.TightenablePauses(document));
    }

    [Fact]
    public void SrtFollowsTheEditedTimeline()
    {
        var document = Document((0, 1000), (2000, 4000));
        var segments = new[] { Word("Hello", 100, 400), Word("world.", 400, 900), Word("Again", 2100, 2500) };
        var srt = TranscriptEditing.FormatSrt(segments, new NLETimeMapper(document.Timeline.Slices));
        Assert.Equal("1\n00:00:00,100 --> 00:00:00,900\nHello world.\n\n2\n00:00:01,100 --> 00:00:01,500\nAgain", srt);
    }

    [Fact]
    public void TypingBurstsBecomeSuggestionsAndApplySplitsTheClip()
    {
        var document = Document((0, 10000));
        var keys = Enumerable.Range(0, 20).Select(index => new KeyStrokeEvent { T = 2000 + index * 150.0, Kind = "typing" }).ToList();
        var suggestion = Assert.Single(ShortcutEngine.TypingSuggestions(document, keys));
        Assert.Equal(2000, suggestion.SourceStartMs);
        Assert.Equal(4850, suggestion.SourceEndMs);

        TypingSuggestionEdits.Apply(document, suggestion, 4);
        Assert.Equal(3, document.Timeline.Slices.Count);
        Assert.Equal(4, document.Timeline.Slices[1].Speed);
        Assert.Empty(ShortcutEngine.TypingSuggestions(document, keys));
    }

    [Fact]
    public void HitsOnNearbyFramesMergeIntoOneTrackedMask()
    {
        var masks = new List<MaskItem>();
        var rect = AutoMaskBuilder.PadSensitive(0.2, 0.2, 0.2, 0.05);
        Assert.NotNull(rect);
        AutoMaskBuilder.AddSensitiveHit(masks, 200, 1000, 8000, rect);
        AutoMaskBuilder.AddSensitiveHit(masks, 1200, 1000, 8000, rect);
        AutoMaskBuilder.AddSensitiveHit(masks, 1200, 1000, 8000, new Rect01(0.7, 0.7, 0.1, 0.05));
        Assert.Equal(2, masks.Count);
        Assert.Equal(2, masks[0].Keyframes.Count);
        Assert.True(masks[0].IsAutoSensitiveMask);

        Assert.Null(AutoMaskBuilder.PadSensitive(0.2, 0.2, -0.01, 0.001));
        var document = new ProjectDocument();
        AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, masks);
        AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, [masks[0]]);
        Assert.Equal(1, document.Timeline.MaskTracks.Sum(track => track.Items.Count));
    }

    [Theory]
    [InlineData("reach me at someone@example.com please", true)]
    [InlineData("token sk-abcdefghijklmnop", true)]
    [InlineData("card 4242 4242 4242 4242", true)]
    [InlineData("call 415-555-0100", true)]
    [InlineData("just a normal sentence", false)]
    public void SensitivePatternsMatchLikeTheMacApp(string text, bool expected)
    {
        var match = AutoMaskBuilder.SensitivePatterns.Any(pattern => System.Text.RegularExpressions.Regex.IsMatch(text, pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase));
        Assert.Equal(expected, match);
    }

    [Fact]
    public void PresetKeepsWhatBelongsToTheRecordingAndRoundTrips()
    {
        var root = Directory.CreateTempSubdirectory("ns-presets-").FullName;
        try
        {
            var store = new ProjectPresetStore(root);
            Assert.Equal(3, store.Load().Count);
            var document = new ProjectDocument();
            document.Canvas.CropRect01 = new Rect01(0.1, 0.1, 0.8, 0.8);
            document.Camera.Enabled = true;
            var preset = store.Load().First(item => item.Name.StartsWith("Social"));
            preset.Apply(document);
            Assert.Equal(AspectRatioPreset.Vertical9x16, document.Canvas.AspectRatioPreset);
            Assert.Equal(0.8, document.Canvas.CropRect01.Width);
            Assert.True(document.Camera.Enabled);

            var saved = ProjectPreset.From("Mine", document);
            store.Save(saved);
            Assert.Contains(store.Load(), item => item.Name == "Mine" && item.Id == saved.Id);
            var file = Directory.GetFiles(root).First(path => path.Contains("Mine"));
            var imported = store.Import(file);
            Assert.NotNull(imported);
            Assert.NotEqual(saved.Id, imported.Id);
            File.WriteAllText(Path.Combine(root, "other.json"), "not json");
            Assert.Null(store.Import(Path.Combine(root, "other.json")));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
