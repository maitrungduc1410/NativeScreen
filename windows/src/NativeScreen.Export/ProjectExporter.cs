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
    IReadOnlyList<ShortcutCluster> Shortcuts,
    Task<FaceTrack?>? FaceTrack = null,
    Func<IPersonMaskSource?>? PersonMasks = null,
    bool CameraOnly = false,
    MotionPointSize? PointSize = null);

/// <summary>
/// Sequential decode, compose, encode on its own thread and its own compositor, so a running export never touches the
/// preview's resources. Back pressure comes from the sink writer: one frame is composed for each one written.
/// </summary>
public sealed class ProjectExporter(ExportSource source)
{
    public Task RunAsync(string path, ExportSettings settings, IProgress<ExportProgress>? progress, CancellationToken cancel) =>
        Task.Factory.StartNew(() => Run(path, settings, progress, cancel), cancel, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    /// <summary>
    /// One composed frame as PNG or JPEG, on its own compositor like a video export. <paramref name="timelineMs"/> picks the
    /// occurrence of a reused source range (ADR-86); without it the first one is used.
    /// </summary>
    public Task ExportStillAsync(string path, double sourceMs, int resolutionHeight, bool jpeg, double? timelineMs = null) => Task.Run(() =>
    {
        var document = source.Document;
        var aspect = document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var (width, height) = new ExportSettings { ResolutionHeight = resolutionHeight }.OutputSize(aspect);
        using var compositor = new FrameCompositor();
        using var screen = OpenSequential(source.Tracks.DisplayVideo);
        using var webcam = OpenSequential(source.Tracks.WebcamVideo);
        var faceTrack = WaitForFaceTrack();
        var masks = source.PersonMasks?.Invoke();
        using var ownedMasks = masks as IDisposable;
        var layer = compositor.Compose(
            new ComposeRequest
            {
                Document = document,
                Trajectory = Solve(document),
                SourceMs = sourceMs,
                TimelineMs = timelineMs,
                ScreenSource = screen,
                WebcamSource = webcam,
                ScreenWidth = (int)source.SourceWidth,
                ScreenHeight = (int)source.SourceHeight,
                HasCamera = source.HasCamera,
                ExportQuality = true,
                PackageDirectory = source.PackageDirectory,
                Shortcuts = source.Shortcuts,
                FaceTrack = faceTrack,
                PersonMasks = masks,
                CameraOnly = source.CameraOnly
            },
            width,
            height);
        ImageTexture.Save(ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height), width, height, path, jpeg);
    });

    // Motion runs on edited time: every exported frame passes its timeline time (ADR-86).
    private PlaybackTrajectorySolver Solve(ProjectDocument document) =>
        new(source.SourceDurationMs, source.CursorEvents, source.ClickEvents, document, source.PointSize);

    private void Run(string path, ExportSettings settings, IProgress<ExportProgress>? progress, CancellationToken cancel)
    {
        var document = source.Document;
        var mapper = new NLETimeMapper(document.Timeline.Slices);
        var aspect = document.Canvas.EffectiveAspectRatio(source.SourceWidth, source.SourceHeight);
        var (width, height) = settings.OutputSize(aspect);
        var total = ExportPlan.FrameCount(mapper.TotalTimelineDurationMs, settings.Fps);
        var frameMs = 1000.0 / settings.Fps;
        var trajectory = Solve(document);

        using var compositor = new FrameCompositor();
        using var screen = OpenSequential(source.Tracks.DisplayVideo);
        using var webcam = OpenSequential(source.Tracks.WebcamVideo);
        var faceTrack = WaitForFaceTrack();
        var masks = source.PersonMasks?.Invoke();
        using var ownedMasks = masks as IDisposable;
        var audio = settings.Format == ExportFormat.Gif ? null : OpenAudio(mapper);
        var bitrate = ExportEstimator.TargetMp4Bitrate(settings.Compression, settings.Mp4Codec, width, height, settings.Fps);
        var writer = settings.Format == ExportFormat.Gif
            ? null
            : new VideoFileWriter(path, width, height, settings.Fps, bitrate, settings.Mp4Codec == Mp4CodecOption.H265, fragmented: false, audio is null ? null : AudioMixer.OutputFormat);
        var gif = settings.Format == ExportFormat.Gif ? new GifFileWriter(path, width, height, !settings.GifDisableLoop) : null;
        var nv12 = new byte[width * height * 3 / 2];
        using var converter = writer is null ? null : new GpuNv12Converter(compositor.Device, compositor.Context, width, height);
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
                        TimelineMs = timelineMs,
                        ScreenSource = screen,
                        WebcamSource = webcam,
                        ScreenWidth = (int)source.SourceWidth,
                        ScreenHeight = (int)source.SourceHeight,
                        HasCamera = source.HasCamera,
                        ExportQuality = true,
                        PackageDirectory = source.PackageDirectory,
                        Shortcuts = source.Shortcuts,
                        FaceTrack = faceTrack,
                        PersonMasks = masks,
                        CameraOnly = source.CameraOnly
                    },
                    width,
                    height);
                if (gif is not null)
                {
                    gif.WriteFrame(ImageTexture.ReadBack(compositor.Device, compositor.Context, layer.Texture, width, height), frameMs);
                }
                else
                {
                    converter!.Convert(layer.View, nv12);
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

    // Exports wait for the scan, so a sticker is not missing from the start of the video.
    private FaceTrack? WaitForFaceTrack() => source.FaceTrack?.GetAwaiter().GetResult();

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
