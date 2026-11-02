using System.Globalization;

namespace NativeScreen.Core;

/// <summary>Creates and finishes a package on disk. Everything here is the part of a recording that is not capture.</summary>
public static class RecordingPackage
{
    public static string Create(string projectsDirectory, DateTime now)
    {
        var name = "Recording " + now.ToString("yyyy-MM-dd HH.mm.ss", CultureInfo.InvariantCulture);
        var package = ProjectStore.UniquePackagePath(projectsDirectory, name);
        Directory.CreateDirectory(Path.Combine(package, "recording", "telemetry"));
        Directory.CreateDirectory(Path.Combine(package, "assets"));
        return package;
    }

    /// <summary>Writes metadata.json and project.json once capture stopped. recording/ is immutable after this.</summary>
    public static ProjectDocument Finish(
        string package,
        CaptureTargetMetadata target,
        double durationMs,
        bool hasWebcam,
        bool hasMicrophone,
        bool hasSystemAudio,
        bool autoCreateZooms,
        DateTimeOffset now)
    {
        var recording = Path.Combine(package, "recording");
        var duration = Math.Max(1000, durationMs);
        var metadata = new RecordingMetadata
        {
            Platform = "windows",
            CreatedAt = now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            DurationMs = duration,
            CaptureTarget = target,
            Tracks = new RecordingTracksMetadata
            {
                WebcamVideo = hasWebcam ? "webcam.mp4" : null,
                MicrophoneAudio = hasMicrophone ? "microphone.m4a" : null,
                SystemAudio = hasSystemAudio ? "display.mp4" : null
            }
        };
        File.WriteAllText(Path.Combine(recording, "metadata.json"), ProjectJson.Serialize(metadata));

        var clicks = JsonLines.Load<ClickEvent>(Path.Combine(recording, metadata.Tracks.ClicksTelemetry));
        var keys = JsonLines.Load<KeyStrokeEvent>(Path.Combine(recording, metadata.Tracks.KeysTelemetry));
        var document = new ProjectDocument
        {
            Name = target.AppName ?? Path.GetFileNameWithoutExtension(package)
        };
        document.Camera.Enabled = hasWebcam;
        document.Timeline.Slices = [new ClipSlice { Id = EditorSession.NewId(), SourceStartMs = 0, SourceEndMs = duration, Speed = 1 }];
        document.Timeline.Zooms = autoCreateZooms ? AutoZoomClusterGenerator.GenerateZooms(clicks, keys, duration, 1.8) : [];
        ProjectStore.WriteProjectJson(package, ProjectStore.Serialize(document, now));
        return document;
    }
}

/// <summary>Names written to keys.jsonl, the same ones the macOS recorder writes.</summary>
public static class KeyTelemetry
{
    private const int VkBack = 0x08;
    private const int VkTab = 0x09;
    private const int VkReturn = 0x0D;
    private const int VkEscape = 0x1B;
    private const int VkSpace = 0x20;
    private const int VkPrior = 0x21;
    private const int VkNext = 0x22;
    private const int VkEnd = 0x23;
    private const int VkHome = 0x24;
    private const int VkLeft = 0x25;
    private const int VkUp = 0x26;
    private const int VkRight = 0x27;
    private const int VkDown = 0x28;
    private const int VkDelete = 0x2E;
    private const int VkF1 = 0x70;
    private const int VkF12 = 0x7B;

    /// <summary>Shift, Ctrl, Alt, the Windows keys and Caps Lock: pressing one alone is not a keystroke.</summary>
    public static bool IsModifier(int vk) => vk is 0x10 or 0x11 or 0x12 or 0x14 or (>= 0xA0 and <= 0xA5) or 0x5B or 0x5C;

    public static string? KeyName(int vk, char mappedCharacter) => vk switch
    {
        VkReturn => "Enter",
        VkTab => "Tab",
        VkSpace => "Space",
        VkBack => "Delete",
        VkDelete => "ForwardDelete",
        VkEscape => "Escape",
        VkLeft => "ArrowLeft",
        VkRight => "ArrowRight",
        VkDown => "ArrowDown",
        VkUp => "ArrowUp",
        VkHome => "Home",
        VkEnd => "End",
        VkPrior => "PageUp",
        VkNext => "PageDown",
        >= VkF1 and <= VkF12 => "F" + (vk - VkF1 + 1).ToString(CultureInfo.InvariantCulture),
        _ => char.IsControl(mappedCharacter) || mappedCharacter == '\0' ? null : char.ToUpperInvariant(mappedCharacter).ToString()
    };

    public static bool IsSpecialStandalone(string? key) => key is
        "Delete" or "ForwardDelete" or "ArrowLeft" or "ArrowRight" or "ArrowUp" or "ArrowDown" or "Home" or "End" or "PageUp" or "PageDown"
        or "F1" or "F2" or "F3" or "F4" or "F5" or "F6" or "F7" or "F8" or "F9" or "F10" or "F11" or "F12";

    /// <summary>Builds the event in the order the macOS recorder lists modifiers.</summary>
    public static KeyStrokeEvent Stroke(double t, bool capsLock, bool meta, bool shift, bool alt, bool control, string? key)
    {
        var modifiers = new List<string>(5);
        if (capsLock)
        {
            modifiers.Add("CapsLock");
        }

        if (meta)
        {
            modifiers.Add("Meta");
        }

        if (shift)
        {
            modifiers.Add("Shift");
        }

        if (alt)
        {
            modifiers.Add("Alt");
        }

        if (control)
        {
            modifiers.Add("Ctrl");
        }

        var parts = modifiers.Select(ModifierLabel).ToList();
        if (!string.IsNullOrEmpty(key))
        {
            parts.Add(KeyLabel(key));
        }

        var label = string.Join(' ', parts);
        return new KeyStrokeEvent
        {
            T = t,
            Kind = meta || alt || control || IsSpecialStandalone(key) ? "shortcut" : "typing",
            Modifiers = modifiers.Count == 0 ? null : modifiers,
            Key = key,
            Label = label.Length == 0 ? null : label
        };
    }

    private static string ModifierLabel(string modifier) => modifier switch
    {
        "Meta" => "Win",
        "CapsLock" => "Caps",
        _ => modifier
    };

    private static string KeyLabel(string key) => key switch
    {
        "Delete" => "Backspace",
        "ForwardDelete" => "Delete",
        "Escape" => "Esc",
        "ArrowUp" => "↑",
        "ArrowDown" => "↓",
        "ArrowLeft" => "←",
        "ArrowRight" => "→",
        _ => key
    };
}

/// <summary>Stateful sample-rate and channel conversion to 16-bit PCM, for capture devices that do not run at 48 kHz.</summary>
public sealed class PcmConverter(int inputRate, int inputChannels, bool inputIsFloat, int inputBits, int outputRate, int outputChannels)
{
    private readonly float[] previous = new float[outputChannels];
    private double position;
    private short[] output = new short[8192];

    /// <summary>Converts one capture buffer. The result stays valid until the next call.</summary>
    public ReadOnlySpan<short> Convert(ReadOnlySpan<byte> input)
    {
        var frameBytes = inputChannels * inputBits / 8;
        var frames = input.Length / frameBytes;
        var step = inputRate / (double)outputRate;
        var capacity = (int)(frames / step + 2) * outputChannels;
        if (output.Length < capacity)
        {
            output = new short[capacity * 2];
        }

        Span<float> current = stackalloc float[outputChannels];
        var written = 0;
        for (var frame = 0; frame < frames; frame++)
        {
            ReadFrame(input.Slice(frame * frameBytes, frameBytes), current);
            while (position <= 1)
            {
                for (var channel = 0; channel < outputChannels; channel++)
                {
                    var value = previous[channel] + (current[channel] - previous[channel]) * (float)position;
                    output[written++] = (short)Math.Clamp(value * 32767f, short.MinValue, short.MaxValue);
                }

                position += step;
            }

            position -= 1;
            current.CopyTo(previous);
        }

        return output.AsSpan(0, written);
    }

    private void ReadFrame(ReadOnlySpan<byte> frame, Span<float> destination)
    {
        var bytes = inputBits / 8;
        var sum = 0f;
        var first = 0f;
        var second = 0f;
        for (var channel = 0; channel < inputChannels; channel++)
        {
            var value = ReadSample(frame.Slice(channel * bytes, bytes));
            sum += value;
            if (channel == 0)
            {
                first = value;
            }
            else if (channel == 1)
            {
                second = value;
            }
        }

        if (outputChannels == 1)
        {
            destination[0] = sum / inputChannels;
        }
        else
        {
            destination[0] = first;
            destination[1] = inputChannels > 1 ? second : first;
        }
    }

    private float ReadSample(ReadOnlySpan<byte> sample)
    {
        if (inputIsFloat)
        {
            return System.BitConverter.ToSingle(sample);
        }

        return inputBits switch
        {
            16 => System.BitConverter.ToInt16(sample) / 32768f,
            24 => (sample[0] | sample[1] << 8 | (sbyte)sample[2] << 16) / 8388608f,
            32 => System.BitConverter.ToInt32(sample) / 2147483648f,
            _ => 0
        };
    }
}
