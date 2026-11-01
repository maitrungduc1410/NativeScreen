using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public enum AspectRatioMode
{
    [JsonStringEnumMemberName("auto")] Auto,
    [JsonStringEnumMemberName("preset")] Preset,
    [JsonStringEnumMemberName("custom")] Custom
}

public enum AspectRatioPreset
{
    [JsonStringEnumMemberName("16:9")] Widescreen16x9,
    [JsonStringEnumMemberName("1:1")] Square1x1,
    [JsonStringEnumMemberName("4:3")] Classic4x3,
    [JsonStringEnumMemberName("9:16")] Vertical9x16,
    [JsonStringEnumMemberName("3:4")] Tall3x4,
    [JsonStringEnumMemberName("4:5")] Portrait4x5,
    [JsonStringEnumMemberName("16:10")] Mac16x10
}

public enum BackgroundType
{
    [JsonStringEnumMemberName("mesh")] Mesh,
    [JsonStringEnumMemberName("wallpaper")] Wallpaper,
    [JsonStringEnumMemberName("gradient")] Gradient,
    [JsonStringEnumMemberName("solid")] Solid,
    [JsonStringEnumMemberName("image")] Image
}

public enum GradientType
{
    [JsonStringEnumMemberName("linear")] Linear,
    [JsonStringEnumMemberName("radial")] Radial
}

public enum DeviceFrameMatchMode
{
    [JsonStringEnumMemberName("perfect")] Perfect,
    [JsonStringEnumMemberName("flexible")] Flexible
}

public enum ClickEffectStyle
{
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("circle")] Circle,
    [JsonStringEnumMemberName("ripple")] Ripple,
    [JsonStringEnumMemberName("pulse")] Pulse,
    [JsonStringEnumMemberName("ring")] Ring
}

public enum CursorRotationMode
{
    [JsonStringEnumMemberName("velocity")] Tilt,
    [JsonStringEnumMemberName("directional")] Follow
}

public enum CameraLayoutMode
{
    [JsonStringEnumMemberName("overlay")] Overlay,
    [JsonStringEnumMemberName("split-screen")] SplitScreen,
    [JsonStringEnumMemberName("cutout")] Cutout
}

public enum CameraAspectRatioPreset
{
    [JsonStringEnumMemberName("16:9")] Widescreen16x9,
    [JsonStringEnumMemberName("4:3")] Classic4x3,
    [JsonStringEnumMemberName("1:1")] Square1x1,
    [JsonStringEnumMemberName("3:4")] Portrait3x4,
    [JsonStringEnumMemberName("9:16")] Vertical9x16
}

public enum CameraColorGradePreset
{
    Original, Studio, Cinema, Film, Golden, Cream, Terra, Moody, Arctic, Neon, Punch, Fade, Mono
}

public enum CameraShape
{
    [JsonStringEnumMemberName("circle")] Circle,
    [JsonStringEnumMemberName("squircle")] Squircle,
    [JsonStringEnumMemberName("rectangle")] Rectangle
}

public enum CaptionFontStyle
{
    [JsonStringEnumMemberName("sans-serif")] SansSerif,
    [JsonStringEnumMemberName("serif")] Serif,
    [JsonStringEnumMemberName("mono")] Mono
}

public enum CaptionWordsReveal
{
    [JsonStringEnumMemberName("line-by-line")] LineByLine,
    [JsonStringEnumMemberName("word-by-word")] WordByWord
}

public enum CaptionLineGrowth
{
    [JsonStringEnumMemberName("entire-line")] FullLine,
    [JsonStringEnumMemberName("left-anchored")] Expanding,
    [JsonStringEnumMemberName("centered")] Centered
}

public enum CaptionWordAnimation
{
    [JsonStringEnumMemberName("appear")] Appear,
    [JsonStringEnumMemberName("fade-in")] FadeIn,
    [JsonStringEnumMemberName("slide-in")] SlideIn
}

public enum CaptionColorTheme
{
    [JsonStringEnumMemberName("dark")] Dark,
    [JsonStringEnumMemberName("light")] Light
}

public enum ShortcutDockPosition
{
    [JsonStringEnumMemberName("bottom")] Bottom,
    [JsonStringEnumMemberName("top")] Top,
    [JsonStringEnumMemberName("left")] Left,
    [JsonStringEnumMemberName("right")] Right
}

public enum ShortcutColorMode
{
    [JsonStringEnumMemberName("default")] DefaultDark,
    [JsonStringEnumMemberName("solid")] Solid,
    [JsonStringEnumMemberName("gradient")] Gradient
}

public enum ZoomMode
{
    [JsonStringEnumMemberName("follow-cursor")] FollowCursor,
    [JsonStringEnumMemberName("manual")] Manual
}

public enum ZoomPresentation
{
    [JsonStringEnumMemberName("screen")] Screen,
    [JsonStringEnumMemberName("loupe")] Loupe
}

public enum MaskType
{
    [JsonStringEnumMemberName("blur")] Blur,
    [JsonStringEnumMemberName("spotlight")] Spotlight
}

public enum MaskStyle
{
    [JsonStringEnumMemberName("gaussian")] Gaussian,
    [JsonStringEnumMemberName("pixelate")] Pixelate,
    [JsonStringEnumMemberName("solid")] Solid,
    [JsonStringEnumMemberName("dim")] Dim
}

public enum CameraTimelineLayoutType
{
    [JsonStringEnumMemberName("camera-overlay")] CameraOverlay,
    [JsonStringEnumMemberName("split-screen")] SplitScreen,
    [JsonStringEnumMemberName("cutout-camera")] CutoutCamera,
    [JsonStringEnumMemberName("fullscreen-camera")] FullscreenCamera,
    [JsonStringEnumMemberName("screen-only")] ScreenOnly
}

public enum VoiceoverAttachMode
{
    [JsonStringEnumMemberName("first-frame")] Independent,
    [JsonStringEnumMemberName("all-frames")] Synchronized
}

public enum MicrophoneAudioPreset
{
    [JsonStringEnumMemberName("channel-fix")] Off,
    [JsonStringEnumMemberName("voice")] Standard,
    [JsonStringEnumMemberName("loud")] Loud,
    [JsonStringEnumMemberName("noise-reduction")] NoiseReduction,
    [JsonStringEnumMemberName("podcast")] Podcast
}

public enum CaptureTargetMode
{
    [JsonStringEnumMemberName("display")] Display,
    [JsonStringEnumMemberName("window")] Window,
    [JsonStringEnumMemberName("area")] Area,
    [JsonStringEnumMemberName("device")] Device
}

public enum ExportFormat
{
    [JsonStringEnumMemberName("mp4")] Mp4,
    [JsonStringEnumMemberName("prores")] ProRes,
    [JsonStringEnumMemberName("gif")] Gif
}

public enum ExportCompression
{
    [JsonStringEnumMemberName("studio")] Studio,
    [JsonStringEnumMemberName("social-media")] SocialMedia,
    [JsonStringEnumMemberName("web-high")] Web,
    [JsonStringEnumMemberName("web-low")] WebLow
}

public enum Mp4CodecOption
{
    [JsonStringEnumMemberName("h264")] H264,
    [JsonStringEnumMemberName("h265")] H265,
    [JsonStringEnumMemberName("both")] Both
}

public enum ProResProfileOption
{
    [JsonStringEnumMemberName("422-lt")] Lt422,
    [JsonStringEnumMemberName("422")] Standard422,
    [JsonStringEnumMemberName("422-hq")] Hq422,
    [JsonStringEnumMemberName("4444")] P4444
}

public enum ExportTarget
{
    [JsonStringEnumMemberName("file")] File,
    [JsonStringEnumMemberName("clipboard")] Clipboard
}
