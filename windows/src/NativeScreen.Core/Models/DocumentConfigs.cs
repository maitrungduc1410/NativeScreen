using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public sealed class CustomAspectRatio
{
    public double Width { get; set; } = 16;
    public double Height { get; set; } = 9;
}

public sealed class CanvasConfig
{
    public AspectRatioMode AspectRatioMode { get; set; } = AspectRatioMode.Preset;
    public AspectRatioPreset AspectRatioPreset { get; set; } = AspectRatioPreset.Widescreen16x9;
    public CustomAspectRatio CustomAspectRatio { get; set; } = new();
    public double PaddingRatio { get; set; } = 0.10;
    public Rect01 CropRect01 { get; set; } = Rect01.Full;

    public double EffectiveAspectRatio(double sourceWidth, double sourceHeight)
    {
        switch (AspectRatioMode)
        {
            case AspectRatioMode.Auto:
                var w = Math.Max(1, sourceWidth * CropRect01.Width);
                var h = Math.Max(1, sourceHeight * CropRect01.Height);
                var shortest = Math.Min(w, h);
                var pad = shortest * Math.Max(0, PaddingRatio);
                return (w + 2 * pad) / (h + 2 * pad);
            case AspectRatioMode.Preset:
                return AspectRatioOf(AspectRatioPreset);
            default:
                return Math.Max(0.1, CustomAspectRatio.Width) / Math.Max(0.1, CustomAspectRatio.Height);
        }
    }

    public static double AspectRatioOf(AspectRatioPreset preset) => preset switch
    {
        AspectRatioPreset.Widescreen16x9 => 16.0 / 9.0,
        AspectRatioPreset.Square1x1 => 1,
        AspectRatioPreset.Classic4x3 => 4.0 / 3.0,
        AspectRatioPreset.Vertical9x16 => 9.0 / 16.0,
        AspectRatioPreset.Tall3x4 => 3.0 / 4.0,
        AspectRatioPreset.Portrait4x5 => 4.0 / 5.0,
        AspectRatioPreset.Mac16x10 => 16.0 / 10.0,
        _ => 16.0 / 9.0
    };

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class GradientStopConfig
{
    public string Color { get; set; } = "";
    public double Location { get; set; }

    public GradientStopConfig()
    {
    }

    public GradientStopConfig(string color, double location)
    {
        Color = color;
        Location = location;
    }
}

public sealed class GradientConfig
{
    public GradientType Type { get; set; } = GradientType.Linear;
    public Point01 Start01 { get; set; } = Point01.Zero;
    public Point01 End01 { get; set; } = Point01.One;
    public List<GradientStopConfig> Stops { get; set; } =
    [
        new("#4776E6", 0),
        new("#8E54E9", 1)
    ];
}

public sealed class BackgroundConfig
{
    public BackgroundType Type { get; set; } = BackgroundType.Mesh;
    public string SolidColor { get; set; } = "#1E1E2E";
    public GradientConfig Gradient { get; set; } = new();
    public string? MeshPresetId { get; set; } = "spring-aurora";
    public string? WallpaperRelativePath { get; set; }
    public string? SystemWallpaperName { get; set; }
    public double BlurRadius { get; set; }
    public double NoiseIntensity { get; set; } = 0.02;
    public bool HideSensitiveData { get; set; }
    public List<string> SensitiveDataCustomPhrases { get; set; } = [];
    public bool HideFaces { get; set; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class FrameInsetConfig
{
    public bool Enabled { get; set; } = true;
    public double Size { get; set; } = 1.5;
    public string Color { get; set; } = "#FFFFFF";
    public double Opacity { get; set; } = 0.18;
}

public sealed class FrameShadowConfig
{
    public bool Enabled { get; set; } = true;
    public bool IsDirectional { get; set; } = true;
    public double Intensity { get; set; } = 0.42;
    public double Blur { get; set; } = 36;
    public double Distance { get; set; } = 22;
    public double AngleDegrees { get; set; } = 90;
}

public sealed class DeviceMockupConfig
{
    public bool Enabled { get; set; }
    public string? DeviceId { get; set; } = "macbook-pro-16";
    public DeviceFrameMatchMode MatchMode { get; set; } = DeviceFrameMatchMode.Flexible;
    public string ColorVariantId { get; set; } = "space-black";
}

public sealed class FrameStyleConfig
{
    public double BorderRadius { get; set; } = 16;
    public FrameInsetConfig Inset { get; set; } = new();
    public FrameShadowConfig Shadow { get; set; } = new();
    public DeviceMockupConfig DeviceMockup { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class ClickEffectConfig
{
    public ClickEffectStyle VisualStyle { get; set; } = ClickEffectStyle.None;
    public string Color { get; set; } = "#FFFFFF";
    public string? SoundSet { get; set; }
    public double SoundVolume { get; set; } = 0.50;
}

public sealed class CursorConfig : IJsonOnDeserialized
{
    /// <summary>`arrow` no longer exists: its two variants became separate themes (spec/06 ADR-29).</summary>
    void IJsonOnDeserialized.OnDeserialized()
    {
        if (ThemeId == "arrow")
        {
            ThemeId = VariantId == "pointer-2" ? "classic-light" : CursorSpriteName.DefaultThemeId;
            VariantId = null;
        }
    }

    public bool Hidden { get; set; }
    public double Scale { get; set; } = 1.6;
    public string ThemeId { get; set; } = CursorSpriteName.DefaultThemeId;
    public string? VariantId { get; set; }
    public bool AlwaysUsePointer { get; set; }
    public bool SmoothMovementEnabled { get; set; } = true;
    public SpringConfig Spring { get; set; } = SpringConfig.DefaultCursor.Copy();
    public double BaseRotationDegrees { get; set; }
    public CursorRotationMode RotationMode { get; set; } = CursorRotationMode.Tilt;
    public bool VelocityRotationEnabled { get; set; } = true;
    public double VelocityRotationIntensity { get; set; } = 0.5;
    public double? HideWhenIdleAfterMs { get; set; }
    public double? LoopBackToStartMs { get; set; }
    public double StopMovementInLastPartMs { get; set; }
    public double RemoveShakeThresholdPx { get; set; } = 4;
    public bool OptimizeCursorChanges { get; set; } = true;
    public bool KeepInSyncWithHovers { get; set; } = true;
    public ClickEffectConfig ClickEffect { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class CustomCameraColorPreset
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "My preset";
    public double Warmth { get; set; }
    public double BackgroundPop { get; set; } = 0.20;
    public double Contrast { get; set; } = 0.25;
    public double ColorIntensity { get; set; } = 0.20;
}

public sealed class CameraConfig
{
    public bool Enabled { get; set; } = true;
    public CameraLayoutMode LayoutMode { get; set; } = CameraLayoutMode.Overlay;
    public CameraAspectRatioPreset AspectRatioPreset { get; set; } = CameraAspectRatioPreset.Square1x1;
    public bool Mirror { get; set; }
    public Point01 Position01 { get; set; } = new(1, 1);
    public double SizeRatio { get; set; } = 0.56;
    public bool MakeSmallerDuringZoom { get; set; } = true;
    public double ScaleWhenZoomed { get; set; } = 0.66;
    public CameraShape Shape { get; set; } = CameraShape.Squircle;
    public double BorderRadiusRatio { get; set; } = 0.22;
    public double ShadowIntensity { get; set; } = 0.35;
    public double BackgroundBlur { get; set; }
    public bool AiPersonCutout { get; set; }
    public double? HideDuringSilenceMs { get; set; }
    public double SplitScreenRatio01 { get; set; } = 0.50;
    public bool SplitFlip { get; set; }
    public bool SplitEnablePadding { get; set; }
    public double CutoutPositionX01 { get; set; }
    public double CutoutEdgeSoftness { get; set; } = 0.20;
    public double CutoutEdgeInset { get; set; }
    public bool CutoutAvoidEmptyArea { get; set; }
    public CameraColorGradePreset ColorGradePreset { get; set; } = CameraColorGradePreset.Original;
    [JsonPropertyName("customLUTRelativePath")]
    public string? CustomLutRelativePath { get; set; }
    public List<CustomCameraColorPreset> CustomColorPresets { get; set; } = [];
    [JsonPropertyName("selectedCustomColorPresetID")]
    public string? SelectedCustomColorPresetId { get; set; }
    public double ColorGradeIntensity { get; set; } = 1;
    public double Sharpen01 { get; set; }
    public Rect01 CropRect01 { get; set; } = Rect01.Full;
    public bool EnableFaceTracking { get; set; }
    public double DelayAdjustmentMs { get; set; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }

    [JsonIgnore]
    public double AspectValue => AspectRatioPreset switch
    {
        CameraAspectRatioPreset.Widescreen16x9 => 16.0 / 9.0,
        CameraAspectRatioPreset.Classic4x3 => 4.0 / 3.0,
        CameraAspectRatioPreset.Square1x1 => 1,
        CameraAspectRatioPreset.Portrait3x4 => 3.0 / 4.0,
        CameraAspectRatioPreset.Vertical9x16 => 9.0 / 16.0,
        _ => 1
    };
}

public sealed class MotionConfig
{
    public SpringConfig CameraSpring { get; set; } = SpringConfig.DefaultCamera.Copy();
    public double MotionBlurIntensity { get; set; } = 1;
    public bool AvoidEmptyBoundsWhenZooming { get; set; } = true;
}

public sealed class BackgroundMusicConfig
{
    public string? RelativePath { get; set; }
    public double Volume { get; set; } = 0.08;
    public bool Muted { get; set; }
    public bool DuckDuringSpeech { get; set; } = true;
}

public sealed class AudioConfig
{
    public double MasterVolume { get; set; } = 1;
    public double MicrophoneVolume { get; set; } = 1;
    public bool MuteMicrophone { get; set; }
    public MicrophoneAudioPreset MicrophoneAudioPreset { get; set; } = MicrophoneAudioPreset.Standard;
    public bool VoiceEnhancement { get; set; } = true;
    public double SystemAudioVolume { get; set; } = 1;
    public bool MuteSystemAudio { get; set; }
    public BackgroundMusicConfig BackgroundMusic { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}
