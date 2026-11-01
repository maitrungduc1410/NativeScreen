using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public sealed class ProjectDocument
{
    public string SchemaVersion { get; set; } = "1.0.0";
    public string Id { get; set; } = "";
    public string Name { get; set; } = "Untitled Recording";
    public string CreatedAt { get; set; } = "";
    public string UpdatedAt { get; set; } = "";
    public CanvasConfig Canvas { get; set; } = new();
    public BackgroundConfig Background { get; set; } = new();
    public FrameStyleConfig FrameStyle { get; set; } = new();
    public CursorConfig Cursor { get; set; } = new();
    public CameraConfig Camera { get; set; } = new();
    public MotionConfig Motion { get; set; } = new();
    public AudioConfig Audio { get; set; } = new();
    public CaptionsConfig Captions { get; set; } = new();
    public TimelineConfig Timeline { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }
}
