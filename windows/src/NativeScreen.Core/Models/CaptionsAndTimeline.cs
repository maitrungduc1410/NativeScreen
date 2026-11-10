using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public sealed class CaptionSegment
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public string Text { get; set; } = "";
    public bool IsHidden { get; set; }
}

public sealed class ShortcutStyleConfig
{
    public ShortcutDockPosition DockPosition { get; set; } = ShortcutDockPosition.Bottom;
    public double OffsetX { get; set; }
    public double OffsetY { get; set; }
    public ShortcutColorMode ColorMode { get; set; } = ShortcutColorMode.DefaultDark;
    public string SolidColorHex { get; set; } = "#4D2FF5";
    public string GradientStartHex { get; set; } = "#4776E6";
    public string GradientEndHex { get; set; } = "#8E54E9";
    public string TextColorHex { get; set; } = "#FFFFFF";
}

public sealed class ShortcutTrackConfig
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "Shortcuts";
    public bool IsHidden { get; set; }
    public ShortcutStyleConfig Style { get; set; } = new();
}

public sealed class CustomShortcutSegment
{
    public string Id { get; set; } = "";
    public string TrackId { get; set; } = "default-shortcuts-track";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public List<string> Modifiers { get; set; } = ["Meta"];
    public string PrimaryKey { get; set; } = "K";
    public bool IsHidden { get; set; }
    public ShortcutStyleConfig? CustomStyle { get; set; }
}

/// <summary>Look of a caption track, or of one caption that overrides its track.</summary>
public sealed class CaptionStyle
{
    public static Point01 BottomPosition01 => new(0.5, 1);
    public static Point01 CenterPosition01 => new(0.5, 0.5);

    public CaptionFontStyle FontStyle { get; set; } = CaptionFontStyle.SansSerif;
    /// <summary>Share of the canvas's shortest side.</summary>
    public double FontSizeRatio { get; set; } = 0.045;
    public CaptionWordsReveal WordsReveal { get; set; } = CaptionWordsReveal.LineByLine;
    public CaptionLineGrowth LineGrowth { get; set; } = CaptionLineGrowth.Expanding;
    public CaptionWordAnimation WordAnimation { get; set; } = CaptionWordAnimation.Appear;
    public CaptionColorTheme ColorTheme { get; set; } = CaptionColorTheme.Dark;
    /// <summary>Where the line sits inside the canvas margins: (0, 0) is the top-left corner, (1, 1) the bottom-right.</summary>
    public Point01 Position01 { get; set; } = BottomPosition01;

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class CaptionTrack
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "Captions";
    public bool IsHidden { get; set; }
    public CaptionStyle Style { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

/// <summary>
/// One caption on a track. Its timing is separate from the words' spoken times, so moving a caption never changes what Edit by
/// transcript cuts. Words are stretched to fit the block's span.
/// </summary>
public sealed class CaptionBlock
{
    public string Id { get; set; } = "";
    public string TrackId { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    /// <summary>Transcript words shown by this caption. Empty when CustomText is set.</summary>
    public List<string> WordIds { get; set; } = [];
    /// <summary>Text typed by hand, or a transcript caption whose word count was changed.</summary>
    public string? CustomText { get; set; }
    public CaptionStyle? StyleOverride { get; set; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class CaptionsConfig
{
    public bool Enabled { get; set; }
    public bool ShowKeystrokes { get; set; } = true;
    public double ShortcutsSizeRatio { get; set; } = 0.11;
    public bool ShowSingleKeyShortcuts { get; set; }
    public List<int> HiddenShortcutStartMs { get; set; } = [];
    public List<int> DeletedShortcutStartMs { get; set; } = [];
    public ShortcutStyleConfig DefaultShortcutStyle { get; set; } = new();
    public List<ShortcutTrackConfig> ShortcutTracks { get; set; } = [];
    public List<CustomShortcutSegment> CustomShortcuts { get; set; } = [];
    public Dictionary<string, ShortcutStyleConfig> ShortcutStyleOverrides { get; set; } = [];
    public Dictionary<int, Point01> ShortcutTimingOverrides { get; set; } = [];
    public Dictionary<int, CustomShortcutSegment> ShortcutKeyOverrides { get; set; } = [];
    public Point01 KeystrokesPosition01 { get; set; } = new(0.5, 0.90);
    public string FontFamily { get; set; } = "SF Pro Rounded";
    public CaptionFontStyle FontStyle { get; set; } = CaptionFontStyle.SansSerif;
    public double FontSizeRatio { get; set; } = 0.045;
    public CaptionWordsReveal WordsReveal { get; set; } = CaptionWordsReveal.LineByLine;
    public CaptionLineGrowth LineGrowth { get; set; } = CaptionLineGrowth.Expanding;
    public CaptionWordAnimation WordAnimation { get; set; } = CaptionWordAnimation.Appear;
    public CaptionColorTheme ColorTheme { get; set; } = CaptionColorTheme.Dark;
    public string TextColor { get; set; } = "#FFFFFF";
    public string BackgroundColor { get; set; } = "#000000CC";
    public Point01 Position01 { get; set; } = new(0.5, 0.88);
    public string AnimationStyle { get; set; } = "word-by-word";
    public string TranscriptLocale { get; set; } = "en_US";
    public string LocalModelVariant { get; set; } = "system";
    public string WhisperModelTier { get; set; } = "small";
    public string CustomPrompt { get; set; } = "";
    public bool ShowDeletedTextInTranscript { get; set; } = true;
    public bool ShowHiddenWordsInTranscript { get; set; } = true;
    public List<CaptionSegment> Segments { get; set; } = [];
    public List<CaptionTrack> CaptionTracks { get; set; } = [];
    public List<CaptionBlock> CaptionBlocks { get; set; } = [];

    /// <summary>Projects saved before caption tracks keep their look: the old project-wide style becomes the first track's style.</summary>
    public void MigrateTranscriptToCaptionTracksIfNeeded()
    {
        if (CaptionTracks.Count > 0 || Segments.Count == 0)
        {
            return;
        }

        CaptionTracks.Add(new CaptionTrack
        {
            Id = EditorSession.NewId(),
            Name = "Captions",
            Style = new CaptionStyle
            {
                FontStyle = FontStyle,
                FontSizeRatio = FontSizeRatio,
                WordsReveal = WordsReveal,
                LineGrowth = LineGrowth,
                WordAnimation = WordAnimation,
                ColorTheme = ColorTheme,
                Position01 = new Point01(Position01.X, Position01.Y)
            }
        });
        RebuildTranscriptCaptionBlocks();
    }

    /// <summary>A track always holds a caption. The rest are numbered by position.</summary>
    public void RemoveEmptyCaptionTracks()
    {
        CaptionTracks.RemoveAll(track => !CaptionBlocks.Exists(block => block.TrackId == track.Id));
        for (var index = 0; index < CaptionTracks.Count; index++)
        {
            CaptionTracks[index].Name = index == 0 ? "Captions" : $"Captions {index + 1}";
        }
    }

    /// <summary>Fills the first track from the transcript. Captions typed by hand on other tracks stay.</summary>
    public void RebuildTranscriptCaptionBlocks()
    {
        if (CaptionTracks.Count == 0)
        {
            CaptionTracks.Add(new CaptionTrack { Id = EditorSession.NewId(), Name = "Captions" });
        }

        var trackId = CaptionTracks[0].Id;
        CaptionBlocks.RemoveAll(block => block.WordIds.Count > 0 || block.TrackId == trackId);
        foreach (var words in CaptionLineLayout.GroupWordsIntoLines(Segments))
        {
            CaptionBlocks.Add(new CaptionBlock
            {
                Id = EditorSession.NewId(),
                TrackId = trackId,
                SourceStartMs = words[0].SourceStartMs,
                SourceEndMs = words[^1].SourceEndMs,
                WordIds = words.Select(word => word.Id).ToList()
            });
        }
    }

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class ClipSlice
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public double Speed { get; set; } = 1;
    public double SystemAudioVolume { get; set; } = 1;

    /// <summary>Multiplies the project's microphone volume while this slice plays. Missing in older files, read as 1.</summary>
    public double MicrophoneVolume
    {
        get => microphoneVolume;
        set => microphoneVolume = Math.Clamp(value, 0, 2);
    }

    private double microphoneVolume = 1;

    public bool Muted { get; set; }
    public bool HideCursor { get; set; }
    public bool DisableSmoothCursor { get; set; }

    [JsonIgnore]
    public double SourceDurationMs => Math.Max(0, SourceEndMs - SourceStartMs);

    [JsonIgnore]
    public double TimelineDurationMs => SourceDurationMs / Math.Max(0.1, Speed);
}

public sealed class LoupeConfig
{
    public double Radius01 { get; set; } = 0.35;
    public double BevelRatio { get; set; } = 0.2;
    public double ChromaticAberration { get; set; } = 0.5;
}

public sealed class ZoomBlock
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public double Scale { get; set; } = 1.8;
    public ZoomMode Mode { get; set; } = ZoomMode.FollowCursor;
    public ZoomPresentation Presentation { get; set; } = ZoomPresentation.Screen;
    public Point01 ManualCenter01 { get; set; } = Point01.Center;
    public LoupeConfig Loupe { get; set; } = new();
    public bool InstantAnimation { get; set; }
    public bool Disabled { get; set; }
}

public sealed class MaskKeyframe
{
    public double SourceMs { get; set; }
    public Rect01 Rect01 { get; set; } = new(0.25, 0.25, 0.4, 0.15);
}

public sealed class MaskItem
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public MaskType Type { get; set; } = MaskType.Blur;
    public MaskStyle Style { get; set; } = MaskStyle.Gaussian;
    public double Intensity { get; set; } = 36;

    /// <summary>Fill of a solid mask, #RRGGBB. Null means the default dark fill.</summary>
    public string? SolidColor { get; set; }

    public double CornerRadius { get; set; } = 10;
    public List<MaskKeyframe> Keyframes { get; set; } = [];
    public bool Disabled { get; set; }
    public bool IsAutoSensitiveMask { get; set; }
    public bool IsAutoFaceMask { get; set; }

    public Rect01 InterpolatedRect(double sourceMs)
    {
        if (Keyframes.Count == 0)
        {
            return new Rect01(0.25, 0.25, 0.4, 0.15);
        }

        var sorted = Keyframes.OrderBy(frame => frame.SourceMs).ToList();
        if (sorted.Count == 1 || sourceMs <= sorted[0].SourceMs)
        {
            return sorted[0].Rect01;
        }

        if (sourceMs >= sorted[^1].SourceMs)
        {
            return sorted[^1].Rect01;
        }

        for (var i = 0; i < sorted.Count - 1; i++)
        {
            var k0 = sorted[i];
            var k1 = sorted[i + 1];
            if (sourceMs >= k0.SourceMs && sourceMs <= k1.SourceMs)
            {
                var span = Math.Max(0.001, k1.SourceMs - k0.SourceMs);
                var t = (sourceMs - k0.SourceMs) / span;
                return new Rect01(
                    k0.Rect01.X + (k1.Rect01.X - k0.Rect01.X) * t,
                    k0.Rect01.Y + (k1.Rect01.Y - k0.Rect01.Y) * t,
                    k0.Rect01.Width + (k1.Rect01.Width - k0.Rect01.Width) * t,
                    k0.Rect01.Height + (k1.Rect01.Height - k0.Rect01.Height) * t);
            }
        }

        return sorted[^1].Rect01;
    }
}

public sealed class MaskTrack
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool IsHidden { get; set; }
    public List<MaskItem> Items { get; set; } = [];
}

public sealed class CameraLayoutSegment
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double SourceEndMs { get; set; }
    public CameraTimelineLayoutType LayoutType { get; set; } = CameraTimelineLayoutType.CameraOverlay;
    public Point01? OverlayPosition01 { get; set; }
    public double? CutoutPositionX01 { get; set; }
    public bool Disabled { get; set; }
}

public sealed class VoiceoverSegment
{
    public string Id { get; set; } = "";
    public double SourceStartMs { get; set; }
    public double DurationMs { get; set; } = 2000;
    public string RelativePath { get; set; } = "";
    public double Volume { get; set; } = 1;
    public VoiceoverAttachMode AttachMode { get; set; } = VoiceoverAttachMode.Synchronized;
    public bool HideRecording { get; set; }
    public bool Disabled { get; set; }
    public int TrackIndex { get; set; }

    /// <summary>Where in the audio file this segment starts playing. Above 0 after a cut; both halves share one file.</summary>
    public double FileOffsetMs
    {
        get;
        set => field = Math.Max(0, value);
    }

    [JsonIgnore]
    public double SourceEndMs => SourceStartMs + Math.Max(200, DurationMs);
}

public sealed class TimelineConfig
{
    public List<ClipSlice> Slices { get; set; } = [];
    public List<ZoomBlock> Zooms { get; set; } = [];
    public bool IsZoomTrackHidden { get; set; }
    public List<CameraLayoutSegment> CameraLayouts { get; set; } = [];
    public bool IsCameraLayoutsTrackHidden { get; set; }
    public List<MaskTrack> MaskTracks { get; set; } = [];
    /// <summary>Text, arrows, shapes, steps, images and pen strokes; the first track draws on top (spec/02).</summary>
    public List<AnnotationTrack> AnnotationTracks { get; set; } = [];
    public List<VoiceoverSegment> Voiceovers { get; set; } = [];
    public bool IsVoiceoversTrackHidden { get; set; }
    public List<int> HiddenVoiceoverTracks { get; set; } = [];
    public bool IsShortcutsTrackHidden { get; set; }
    public List<int> DismissedTypingSuggestionStarts { get; set; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}
