using NativeScreen.Core;

namespace NativeScreen.Media;

/// <summary>Single frames and audio overviews read outside the playback path.</summary>
public static class MediaAssets
{
    /// <summary>Top-down opaque BGRA from NV12, for stills on a screen. Same BT.709 limited matrix as the compositor.</summary>
    public static byte[] ToBgra(VideoFrame frame)
    {
        var (width, height, nv12) = (frame.Width, frame.Height, frame.Nv12);
        var bgra = new byte[width * height * 4];
        var chromaStart = width * height;
        for (var y = 0; y < height; y++)
        {
            var chromaRow = chromaStart + y / 2 * width;
            for (var x = 0; x < width; x++)
            {
                var c = 298 * (nv12[y * width + x] - 16);
                var u = nv12[chromaRow + (x & ~1)] - 128;
                var v = nv12[chromaRow + (x & ~1) + 1] - 128;
                var o = (y * width + x) * 4;
                bgra[o] = (byte)Math.Clamp((c + 541 * u + 128) >> 8, 0, 255);
                bgra[o + 1] = (byte)Math.Clamp((c - 55 * u - 136 * v + 128) >> 8, 0, 255);
                bgra[o + 2] = (byte)Math.Clamp((c + 459 * v + 128) >> 8, 0, 255);
                bgra[o + 3] = 255;
            }
        }

        return bgra;
    }

    /// <summary>The frame at or just before a time, or null for an unreadable file.</summary>
    public static VideoFrame? FrameAt(VideoFileReader reader, double sourceMs)
    {
        reader.Seek(Math.Max(0, sourceMs));
        VideoFrame? best = null;
        while (reader.ReadNext() is { } frame)
        {
            if (frame.PresentationMs > sourceMs + 0.5 && best is not null)
            {
                break;
            }

            best = frame;
        }

        return best;
    }

    /// <summary>The levels the timeline draws. Null when the file is silent or has no audio this machine can decode.</summary>
    public static float[]? ReadWaveform(string path, int binCount, CancellationToken cancel)
    {
        using var reader = AudioFileReader.TryOpen(path);
        if (reader is null)
        {
            return null;
        }

        var peaks = new List<float>(8192);
        while (reader.ReadBlock() is { } block)
        {
            cancel.ThrowIfCancellationRequested();
            for (var offset = 0; offset < block.Samples.Length; offset += Waveform.PeakChunkSamples)
            {
                var end = Math.Min(block.Samples.Length, offset + Waveform.PeakChunkSamples);
                var loudest = 0f;
                for (var index = offset; index < end; index++)
                {
                    loudest = Math.Max(loudest, Math.Abs(block.Samples[index] / 32768f));
                }

                peaks.Add(loudest);
            }
        }

        return Waveform.BinsFromPeaks(peaks, binCount);
    }

    /// <summary>16 kHz mono floats, the input of the speech model.</summary>
    public static float[] ReadSpeechAudio(string path, CancellationToken cancel)
    {
        using var reader = new AudioFileReader(path);
        var converter = new PcmConverter(reader.SampleRate, reader.Channels, false, 16, 16000, 1);
        var samples = new List<float>();
        while (reader.ReadBlock() is { } block)
        {
            cancel.ThrowIfCancellationRequested();
            var bytes = new byte[block.Samples.Length * 2];
            Buffer.BlockCopy(block.Samples, 0, bytes, 0, bytes.Length);
            foreach (var sample in converter.Convert(bytes))
            {
                samples.Add(sample / 32768f);
            }
        }

        return samples.ToArray();
    }
}

/// <summary>Create Project from Video: copies a movie into a new package with no telemetry. Same layout as macOS.</summary>
public static class VideoProjectImporter
{
    public static string BuildPackage(string videoPath, string projectsDirectory, DateTimeOffset now)
    {
        int width, height;
        double durationMs = 0;
        using (var reader = new VideoFileReader(videoPath))
        {
            (width, height) = (reader.Width, reader.Height);
            durationMs = reader.DurationMs;
        }

        if (durationMs <= 100)
        {
            throw new InvalidDataException("The video is empty or too short.");
        }

        bool hasAudio;
        using (var audio = AudioFileReader.TryOpen(videoPath))
        {
            hasAudio = audio is not null;
        }

        var name = Path.GetFileNameWithoutExtension(videoPath);
        var package = ProjectStore.UniquePackagePath(projectsDirectory, name);
        var recording = Path.Combine(package, "recording");
        var telemetry = Path.Combine(recording, "telemetry");
        Directory.CreateDirectory(telemetry);
        Directory.CreateDirectory(Path.Combine(package, "assets"));
        var extension = Path.GetExtension(videoPath);
        var displayName = "display" + (extension.Length == 0 ? ".mp4" : extension.ToLowerInvariant());
        try
        {
            File.Copy(videoPath, Path.Combine(recording, displayName));
        }
        catch
        {
            Directory.Delete(package, recursive: true);
            throw;
        }

        var tracks = new RecordingTracksMetadata { DisplayVideo = displayName, SystemAudio = hasAudio ? displayName : null, WindowTelemetry = null };
        foreach (var file in new[] { tracks.CursorTelemetry, tracks.ClicksTelemetry, tracks.KeysTelemetry })
        {
            File.WriteAllText(Path.Combine(recording, file), "");
        }

        var metadata = new RecordingMetadata
        {
            Platform = "windows",
            CreatedAt = now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture),
            DurationMs = durationMs,
            Tracks = tracks,
            CaptureTarget = new CaptureTargetMetadata
            {
                Mode = CaptureTargetMode.Display,
                WindowTitle = Path.GetFileName(videoPath),
                LogicalBounds = new LogicalBounds { Width = width, Height = height },
                PixelSize = new PixelDimensions { Width = width, Height = height },
                ScaleFactor = 1,
                WindowBorderRadius = 0
            }
        };
        File.WriteAllText(Path.Combine(recording, "metadata.json"), ProjectJson.Serialize(metadata));
        var document = new ProjectDocument { Name = name };
        document.Camera.Enabled = false;
        document.Timeline.Slices = [new ClipSlice { Id = EditorSession.NewId(), SourceStartMs = 0, SourceEndMs = durationMs, Speed = 1 }];
        ProjectStore.WriteProjectJson(package, ProjectStore.Serialize(document, now));
        return package;
    }
}
