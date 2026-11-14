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
    public void SpeechRegionsSkipSilenceAndMergeShortGaps()
    {
        const int Rate = 16000;
        var samples = new float[Rate * 10];
        void Tone(double from, double to)
        {
            for (var index = (int)(from * Rate); index < (int)(to * Rate); index++)
            {
                samples[index] = 0.3f * MathF.Sin(index * 0.2f);
            }
        }

        Tone(2, 3);
        Tone(3.3, 4);
        Tone(7, 8);
        var regions = SpeechRegions.Find(samples, Rate);
        Assert.Equal(2, regions.Count);
        Assert.InRange(regions[0].Start / (double)Rate, 1.7, 2);
        Assert.InRange((regions[0].Start + regions[0].Length) / (double)Rate, 4, 4.3);
        Assert.InRange(regions[1].Start / (double)Rate, 6.7, 7);
        Assert.Empty(SpeechRegions.Find(new float[Rate], Rate));
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

    /// <summary>Automatic masks never overlap on one track, and a rescan or turning the scan off leaves no empty rows (ADR-91).</summary>
    [Fact]
    public void AutomaticMasksArePackedIntoTracksWithoutOverlaps()
    {
        static MaskItem Auto(string id, double start, double end) => new() { Id = id, SourceStartMs = start, SourceEndMs = end, IsAutoSensitiveMask = true };
        var document = new ProjectDocument();
        var user = new MaskItem { Id = "user", SourceStartMs = 0, SourceEndMs = 4000 };
        document.Timeline.MaskTracks.Add(new MaskTrack { Id = "mine", Name = "Masks", Items = [user, Auto("old-in-mine", 5000, 6000)] });
        document.Timeline.MaskTracks.Add(new MaskTrack { Id = "old", Name = "Masks 2", Items = [Auto("old", 0, 1000)] });
        List<MaskItem> Scan() => [Auto("b", 8800, 16800), Auto("a", 0, 9300), Auto("c", 16800, 20000)];

        static void NoOverlaps(ProjectDocument document)
        {
            foreach (var track in document.Timeline.MaskTracks)
            {
                var items = track.Items.OrderBy(item => item.SourceStartMs).ToList();
                for (var index = 1; index < items.Count; index++)
                {
                    Assert.True(items[index - 1].SourceEndMs <= items[index].SourceStartMs, track.Name);
                }
            }
        }

        AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, Scan());
        var tracks = document.Timeline.MaskTracks;
        Assert.Equal(["mine", null, null], tracks.Select(track => track.Id == "mine" ? "mine" : null));
        Assert.Equal(["user"], tracks[0].Items.Select(item => item.Id));
        Assert.Equal(["a", "c"], tracks[1].Items.Select(item => item.Id));
        Assert.Equal(["b"], tracks[2].Items.Select(item => item.Id));
        Assert.Equal(["Masks", "Masks 2", "Masks 3"], tracks.Select(track => track.Name));
        NoOverlaps(document);

        AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, Scan());
        Assert.Equal(3, tracks.Count);
        Assert.Equal(["a", "c"], tracks[1].Items.Select(item => item.Id));
        NoOverlaps(document);

        AutoMaskBuilder.Replace(document, item => item.IsAutoSensitiveMask, []);
        Assert.Equal(["mine"], tracks.Select(track => track.Id));
        Assert.Equal(["user"], tracks[0].Items.Select(item => item.Id));
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
