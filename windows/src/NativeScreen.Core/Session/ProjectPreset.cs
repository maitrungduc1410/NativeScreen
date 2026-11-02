using System.Text.Json;

namespace NativeScreen.Core;

/// <summary>A reusable style. The file format is the macOS preset .json, so presets move between platforms.</summary>
public sealed class ProjectPreset
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Name { get; set; } = "";
    public CanvasConfig Canvas { get; set; } = new();
    public BackgroundConfig Background { get; set; } = new();
    public FrameStyleConfig FrameStyle { get; set; } = new();
    public CursorConfig Cursor { get; set; } = new();
    public CameraConfig Camera { get; set; } = new();
    public MotionConfig Motion { get; set; } = new();
    public AudioConfig Audio { get; set; } = new();

    public static ProjectPreset From(string name, ProjectDocument document) => new()
    {
        Name = name,
        Canvas = ProjectJson.Clone(document.Canvas),
        Background = ProjectJson.Clone(document.Background),
        FrameStyle = ProjectJson.Clone(document.FrameStyle),
        Cursor = ProjectJson.Clone(document.Cursor),
        Camera = ProjectJson.Clone(document.Camera),
        Motion = ProjectJson.Clone(document.Motion),
        Audio = ProjectJson.Clone(document.Audio)
    };

    /// <summary>What belongs to the recording stays: canvas crop, whether the camera shows, and its crop.</summary>
    public void Apply(ProjectDocument document)
    {
        var crop = document.Canvas.CropRect01;
        var cameraEnabled = document.Camera.Enabled;
        var cameraCrop = document.Camera.CropRect01;
        document.Canvas = ProjectJson.Clone(Canvas);
        document.Canvas.CropRect01 = crop;
        document.Background = ProjectJson.Clone(Background);
        document.FrameStyle = ProjectJson.Clone(FrameStyle);
        document.Cursor = ProjectJson.Clone(Cursor);
        document.Camera = ProjectJson.Clone(Camera);
        document.Camera.Enabled = cameraEnabled;
        document.Camera.CropRect01 = cameraCrop;
        document.Motion = ProjectJson.Clone(Motion);
        document.Audio = ProjectJson.Clone(Audio);
    }
}

public sealed class ProjectPresetStore(string directory)
{
    public string Directory { get; } = directory;

    public List<ProjectPreset> Load()
    {
        System.IO.Directory.CreateDirectory(Directory);
        var presets = new List<ProjectPreset>();
        foreach (var path in System.IO.Directory.GetFiles(Directory, "*.json"))
        {
            if (TryRead(path) is { } preset)
            {
                presets.Add(preset);
            }
        }

        if (presets.Count == 0)
        {
            foreach (var preset in BuiltIn())
            {
                Save(preset);
                presets.Add(preset);
            }
        }

        presets.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        return presets;
    }

    public void Save(ProjectPreset preset)
    {
        System.IO.Directory.CreateDirectory(Directory);
        File.WriteAllText(PathOf(preset), ProjectJson.Serialize(preset));
    }

    public void Delete(ProjectPreset preset)
    {
        var path = PathOf(preset);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }

    /// <summary>An imported preset gets a fresh id, so it never overwrites an existing one. Null when the file is not a preset.</summary>
    public ProjectPreset? Import(string path)
    {
        if (TryRead(path) is not { } preset)
        {
            return null;
        }

        preset.Id = Guid.NewGuid().ToString().ToUpperInvariant();
        Save(preset);
        return preset;
    }

    public static IReadOnlyList<ProjectPreset> BuiltIn() =>
    [
        new()
        {
            Id = "preset-default-studio",
            Name = "Default Studio",
            Canvas = new CanvasConfig { AspectRatioMode = AspectRatioMode.Preset, AspectRatioPreset = AspectRatioPreset.Widescreen16x9, PaddingRatio = 0.10 },
            Background = new BackgroundConfig { Type = BackgroundType.Mesh, MeshPresetId = "spring-aurora" },
            FrameStyle = new FrameStyleConfig { BorderRadius = 16, Shadow = new FrameShadowConfig { Enabled = true, IsDirectional = true, Intensity = 0.42 } },
            Cursor = new CursorConfig { Scale = 1.6 },
            Camera = new CameraConfig { LayoutMode = CameraLayoutMode.Overlay, ColorGradePreset = CameraColorGradePreset.Studio },
            Motion = new MotionConfig { MotionBlurIntensity = 1 }
        },
        new()
        {
            Id = "preset-social-vertical",
            Name = "Social Vertical 9:16",
            Canvas = new CanvasConfig { AspectRatioMode = AspectRatioMode.Preset, AspectRatioPreset = AspectRatioPreset.Vertical9x16, PaddingRatio = 0.08 },
            Background = new BackgroundConfig { Type = BackgroundType.Gradient, Gradient = Gradient("#4776E6", "#8E54E9") },
            FrameStyle = new FrameStyleConfig { BorderRadius = 18, Shadow = new FrameShadowConfig { Enabled = true, IsDirectional = true, Intensity = 0.48 } },
            Cursor = new CursorConfig { Scale = 1.9 },
            Camera = new CameraConfig { LayoutMode = CameraLayoutMode.SplitScreen, SplitScreenRatio01 = 0.5, ColorGradePreset = CameraColorGradePreset.Punch },
            Motion = new MotionConfig { CameraSpring = new SpringConfig(250, 40, 2.25), MotionBlurIntensity = 1 }
        },
        new()
        {
            Id = "preset-macos-dark-cinema",
            Name = "Dark Cinema",
            Canvas = new CanvasConfig { AspectRatioMode = AspectRatioMode.Preset, AspectRatioPreset = AspectRatioPreset.Widescreen16x9, PaddingRatio = 0.12 },
            Background = new BackgroundConfig { Type = BackgroundType.Gradient, Gradient = Gradient("#0F172A", "#1E1B4B") },
            FrameStyle = new FrameStyleConfig
            {
                BorderRadius = 20,
                Inset = new FrameInsetConfig { Enabled = true, Size = 1.5, Opacity = 0.22 },
                Shadow = new FrameShadowConfig { Enabled = true, IsDirectional = true, Intensity = 0.58, Blur = 44, Distance = 26 }
            },
            Cursor = new CursorConfig { Scale = 1.8 },
            Camera = new CameraConfig { LayoutMode = CameraLayoutMode.Overlay, ColorGradePreset = CameraColorGradePreset.Cinema },
            Motion = new MotionConfig { CameraSpring = new SpringConfig(250, 40, 2.25), MotionBlurIntensity = 1 }
        }
    ];

    private static GradientConfig Gradient(string from, string to) => new()
    {
        Stops = [new GradientStopConfig { Color = from, Location = 0 }, new GradientStopConfig { Color = to, Location = 1 }]
    };

    private static ProjectPreset? TryRead(string path)
    {
        try
        {
            var preset = ProjectJson.Deserialize<ProjectPreset>(File.ReadAllText(path));
            return string.IsNullOrWhiteSpace(preset.Name) ? null : preset;
        }
        catch (Exception exception) when (exception is JsonException or IOException or NotSupportedException)
        {
            return null;
        }
    }

    private string PathOf(ProjectPreset preset)
    {
        var safe = new string(preset.Name.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '-' : character).ToArray());
        var suffix = preset.Id.Length >= 8 ? preset.Id[..8] : preset.Id;
        return Path.Combine(Directory, $"{safe}-{suffix}.json");
    }
}
