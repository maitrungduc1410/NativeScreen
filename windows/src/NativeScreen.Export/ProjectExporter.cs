using NativeScreen.Core;
using NativeScreen.Media;
using NativeScreen.Rendering;

namespace NativeScreen.Export;

public readonly record struct ExportProgress(int Encoded, int Total);

/// <summary>What an export reads. The document is a frozen copy, so editing can continue during the export.</summary>
public sealed record ExportSource(
    ProjectDocument Document,
    string? PackageDirectory,
    RecordingTracksMetadata Tracks,
    double SourceDurationMs,
    double SourceWidth,
    double SourceHeight,
    bool HasCamera,
    IReadOnlyList<CursorSampleEvent> CursorEvents,
    IReadOnlyList<ClickEvent> ClickEvents,
    IReadOnlyList<ShortcutCluster> Shortcuts);

/// <summary>
/// Sequential decode, compose, encode on its own thread and its own compositor, so a running export never touches the
/// preview's resources. Back pressure comes from the sink writer: one frame is composed for each one written.
/// </summary>
public sealed class ProjectExporter(ExportSource source)
{
    public Task RunAsync(string path, ExportSettings settings, IProgress<ExportProgress>? progress, CancellationToken cancel) =>
        Task.Factory.StartNew(() => Run(path, settings, progress, cancel), cancel, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    private void Run(string path, ExportSettings settings, IProgress<ExportProgress>? progress, CancellationToken cancel)
    {
        var document = source.Document;
        var mapper = new NLETimeMapper(document.Timeline.Slices);
        var aspect = document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var (width, height) = settings.OutputSize(aspect);
        var total = ExportPlan.FrameCount(mapper.TotalTimelineDurationMs, settings.Fps);
        var frameMs = 1000.0 / settings.Fps;
        var trajectory = new SpringTrajectorySolver(source.SourceDurationMs, source.CursorEvents, source.ClickEvents, document);

        using var compositor = new FrameCompositor();
        using var screen = OpenSequential(source.Tracks.DisplayVideo);
        using var webcam = OpenSequential(source.Tracks.WebcamVideo);
        var audio = settings.Format == ExportFormat.Gif ? null : OpenAudio(mapper);
        var bitrate = ExportEstimator.TargetMp4Bitrate(settings.Compression, settings.Mp4Codec, width, height, settings.Fps);
        var writer = settings.Format == ExportFormat.Gif
            ? null
            : new VideoFileWriter(path, width, height, settings.Fps, bitrate, settings.Mp4Codec == Mp4CodecOption.H265, fragmented: false, audio is null ? null : AudioMixer.OutputFormat);
        var gif = settings.Format == ExportFormat.Gif ? new GifFileWriter(path, width, height) : null;
        var nv12 = new byte[width * height * 3 / 2];
        try
        {
            for (var index = 0; index < total; index++)
            {
                cancel.ThrowIfCancellationRequested();
                var timelineMs = index * frameMs;
                var layer = compositor.Compose(
                    new ComposeRequest
                    {
                        Document = document,
                        Trajectory = trajectory,
                        SourceMs = mapper.SourceTime(timelineMs).SourceMs,
                        ScreenSource = screen,
                        WebcamSource = webcam,
                        ScreenWidth = (int)source.SourceWidth,
                        ScreenHeight = (int)source.SourceHeight,
                        HasCamera = source.HasCamera,
                        ExportQuality = true,
                        PackageDirectory = source.PackageDirectory,
                        Shortcuts = source.Shortcuts
                    },
                    width,
                    height);
                var pixels = ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height);
                if (gif is not null)
                {
                    gif.WriteFrame(pixels, frameMs);
                }
                else
                {
                    Nv12Converter.FromBgra(pixels, nv12, width, height);
                    writer!.WriteFrame(nv12, timelineMs, frameMs);
                    audio?.WriteUpTo(writer, timelineMs + frameMs);
                }

                progress?.Report(new ExportProgress(index + 1, total));
            }

            writer?.Finish();
            gif?.Finish();
            writer?.Dispose();
            gif?.Dispose();
        }
        catch
        {
            writer?.Cancel();
            gif?.Cancel();
            throw;
        }
        finally
        {
            audio?.Dispose();
        }
    }

    private AudioMixer? OpenAudio(NLETimeMapper mapper)
    {
        if (source.PackageDirectory is null)
        {
            return null;
        }

        var mixer = new AudioMixer(source.Document, source.PackageDirectory, source.Tracks, mapper);
        if (mixer.HasAudio)
        {
            return mixer;
        }

        mixer.Dispose();
        return null;
    }

    private SequentialVideoSource? OpenSequential(string? track)
    {
        if (track is null || source.PackageDirectory is null)
        {
            return null;
        }

        var path = Path.Combine(source.PackageDirectory, "recording", track);
        return File.Exists(path) ? new SequentialVideoSource(path) : null;
    }
}
