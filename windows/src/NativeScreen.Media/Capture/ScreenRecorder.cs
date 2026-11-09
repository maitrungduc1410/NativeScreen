using System.Diagnostics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace NativeScreen.Media;

public sealed record RecordingOptions(
    CaptureTarget Target,
    string PackageDirectory,
    bool SystemAudio,
    string? MicrophoneId,
    string? CameraId,
    int CameraMaxHeight = 1080,
    IReadOnlyCollection<string>? SystemAudioApps = null);

public enum CaptureFailureKind
{
    Stream,
    ScreenWriter,
    WebcamWriter,
    MicrophoneWriter
}

public sealed record CaptureFailure(CaptureFailureKind Kind, string Details);

public readonly record struct RecordingStats(int FramesWritten, int FramesRepeated, int FramesDropped, double ConvertMsAverage);

/// <summary>
/// Windows.Graphics.Capture into a fragmented display.mp4, plus microphone, webcam and telemetry on their own threads. Every
/// track shares one origin (the first video frame) and one pause timeline, the same scheme as the macOS engine.
/// </summary>
public sealed class ScreenRecorder : IDisposable
{
    private const int MaxFps = 60;
    private const int FramePoolSize = 3;
    private const int KeepAliveMs = 250;
    private const int FirstFrameTimeoutMs = 5000;
    private static readonly Guid DxgiInterfaceAccessIid = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");

    private readonly RecordingOptions options;
    private readonly PauseTimeline pause = new();
    private readonly object pauseGate = new();
    private readonly AutoResetEvent frameReady = new(false);
    private readonly ManualResetEventSlim firstFrame = new(false);
    private readonly ID3D11Device device;
    private readonly ID3D11DeviceContext context;
    private readonly IDirect3DDevice captureDevice;
    private readonly GraphicsCaptureItem item;
    private readonly Direct3D11CaptureFramePool framePool;
    private readonly GraphicsCaptureSession session;
    private readonly ID3D11Texture2D frameCopy;
    private readonly ID3D11ShaderResourceView frameView;
    private readonly GpuNv12Converter converter;
    private readonly VideoFileWriter writer;
    private readonly TelemetryRecorder telemetry;
    private readonly IRecordedAudioTrack? systemAudio;
    private readonly AudioTrackRecorder? microphone;
    private readonly WebcamRecorder? webcam;
    private readonly Thread worker;
    private readonly byte[] nv12;
    private readonly int width;
    private readonly int height;
    private readonly int sourceX;
    private readonly int sourceY;
    private SizeInt32 poolSize;
    private double originMs = double.NaN;
    private double lastPtsMs = double.NegativeInfinity;
    private double lastWriteHostMs;
    private volatile bool stopping;
    private bool hasFrame;
    private int framesWritten;
    private int framesRepeated;
    private int framesDropped;
    private double convertTotalMs;
    private int disposed;
    private CaptureFailure? failure;
    private readonly nint recordedWindow;
    private readonly FramePacer pacer = new(1000.0 / MaxFps, 2);

    public ScreenRecorder(RecordingOptions options)
    {
        this.options = options;
        var target = options.Target;
        width = target.OutputWidth;
        height = target.OutputHeight;
        nv12 = new byte[width * height * 3 / 2];
        var recording = Path.Combine(options.PackageDirectory, "recording");
        Directory.CreateDirectory(recording);

        FeatureLevel[] levels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0];
        D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, levels, out ID3D11Device? created, out _, out ID3D11DeviceContext? createdContext).CheckError();
        device = created!;
        context = createdContext!;
        using (var dxgi = device.QueryInterface<IDXGIDevice>())
        {
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out var inspectable));
            captureDevice = MarshalInspectable<IDirect3DDevice>.FromAbi(inspectable);
            Marshal.Release(inspectable);
        }

        // A capture of one window drops the flyouts, menus and tooltips a demo of the editor needs. Those are separate windows of
        // this app, so its own windows capture the monitor and crop to the window.
        var cropsMonitor = target.Mode == CaptureTargetMode.Area || (target.Window is { } own && CaptureTargets.IsOwnWindow(own.Handle));
        recordedWindow = target.Mode == CaptureTargetMode.Window ? target.Window!.Handle : 0;
        item = target.Mode == CaptureTargetMode.Window && !cropsMonitor
            ? CaptureItemInterop.ForWindow(target.Window!.Handle)
            : CaptureItemInterop.ForMonitor(target.Display.Handle);
        poolSize = item.Size;
        (sourceX, sourceY) = cropsMonitor
            ? (Math.Max(0, target.Rect.X - target.Display.Bounds.X), Math.Max(0, target.Rect.Y - target.Display.Bounds.Y))
            : (0, 0);
        frameCopy = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)width,
            Height = (uint)height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource
        });
        frameView = device.CreateShaderResourceView(frameCopy);
        converter = new GpuNv12Converter(device, context, width, height);

        var audioFormat = options.SystemAudio ? new AudioFormat(48000, 2, 192_000) : (AudioFormat?)null;
        writer = new VideoFileWriter(
            Path.Combine(recording, "display.mp4"),
            width,
            height,
            MaxFps,
            RecordingRates.DisplayBitrate(width, height),
            hevc: false,
            fragmented: true,
            audioFormat);
        writer.WriteFailed = details => Report(CaptureFailureKind.ScreenWriter, details);
        telemetry = new TelemetryRecorder(Path.Combine(recording, "telemetry"), target.Rect);
        if (options.SystemAudio)
        {
            systemAudio = options.SystemAudioApps is { } apps
                ? new AppAudioTrackRecorder(AudioApps.RootProcessIds(apps), (data, length, at, duration) => writer.WriteAudio(data.AsSpan(0, length), at, duration), ElapsedForTrack)
                : AudioTrackRecorder.TryLoopback(writer, ElapsedForTrack);
        }

        if (options.MicrophoneId is { } microphoneId)
        {
            microphone = AudioTrackRecorder.TryMicrophone(microphoneId, Path.Combine(recording, "microphone.m4a"), ElapsedForTrack, details => Report(CaptureFailureKind.MicrophoneWriter, details));
        }

        if (options.CameraId is { } cameraId)
        {
            webcam = WebcamRecorder.TryStart(cameraId, Path.Combine(recording, "webcam.mp4"), options.CameraMaxHeight, ElapsedForTrack, details => Report(CaptureFailureKind.WebcamWriter, details));
        }

        framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(captureDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, FramePoolSize, poolSize);
        framePool.FrameArrived += (_, _) => frameReady.Set();
        item.Closed += ItemClosed;
        session = framePool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = CapturePolicy.CaptureCursor;
        TrySetBorderless(session);
        worker = new Thread(Run) { IsBackground = true, Name = "NativeScreen screen capture", Priority = ThreadPriority.AboveNormal };
        worker.Start();
        session.StartCapture();
    }

    public bool HasSystemAudio => systemAudio is not null;

    /// <summary>A chosen app is missing from the system audio track, because it closed or could not be captured.</summary>
    public bool IsMissingAppAudio => systemAudio is AppAudioTrackRecorder { IsComplete: false };

    public bool HasMicrophone => microphone is not null;
    public bool HasWebcam => webcam is not null;

    /// <summary>Camera frames for the floating preview, on the camera's thread. The buffer is reused after the call.</summary>
    public event Action<byte[], int, int>? CameraFrame
    {
        add
        {
            if (webcam is not null)
            {
                webcam.PreviewFrame += value;
            }
        }
        remove
        {
            if (webcam is not null)
            {
                webcam.PreviewFrame -= value;
            }
        }
    }

    public double DurationMs { get; private set; }

    /// <summary>
    /// Raised once, on a capture thread, when the captured window or display goes away or a writer fails. A failed writer
    /// drops every later sample, so the owner ends the recording instead of recording on (spec/06 ADR-54).
    /// </summary>
    public event Action<CaptureFailure>? Failed;

    /// <summary>The first failure, if any.</summary>
    public CaptureFailure? Failure => Volatile.Read(ref failure);

    public RecordingStats Stats => new(framesWritten, framesRepeated, framesDropped, framesWritten == 0 ? 0 : convertTotalMs / framesWritten);

    /// <summary>Blocks until the first frame was written. False means the target never produced one.</summary>
    public bool WaitForFirstFrame() => firstFrame.Wait(FirstFrameTimeoutMs);

    public void SetPaused(bool paused)
    {
        var now = NowMs();
        lock (pauseGate)
        {
            pause.SetPaused(paused, now);
        }

        telemetry.SetPaused(paused, now);
    }

    /// <summary>Finishes every track. Safe to call once; the files are complete afterwards.</summary>
    public void Stop()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        var stopHostMs = NowMs();
        stopping = true;
        item.Closed -= ItemClosed;
        session.Dispose();
        frameReady.Set();
        worker.Join();
        framePool.Dispose();
        if (!double.IsNaN(originMs))
        {
            var offset = PauseOffset(stopHostMs) ?? 0;
            DurationMs = Math.Max(lastPtsMs, stopHostMs - originMs - offset);
            if (hasFrame && DurationMs > lastPtsMs + 1)
            {
                // The last frame stays on screen until the moment Stop was pressed.
                writer.WriteFrame(nv12, DurationMs, 1000.0 / MaxFps);
            }
        }

        telemetry.Dispose();
        systemAudio?.Stop(DurationMs);
        microphone?.Stop(DurationMs);
        webcam?.Stop(DurationMs);
        writer.Dispose();
    }

    public void Dispose()
    {
        Stop();
        systemAudio?.Dispose();
        microphone?.Dispose();
        webcam?.Dispose();
        converter.Dispose();
        frameView.Dispose();
        frameCopy.Dispose();
        (captureDevice as IDisposable)?.Dispose();
        context.Dispose();
        device.Dispose();
        frameReady.Dispose();
        firstFrame.Dispose();
    }

    private static double NowMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    private double? PauseOffset(double hostMs)
    {
        lock (pauseGate)
        {
            return pause.OffsetMs(hostMs);
        }
    }

    /// <summary>Position of a host time on the recording's timeline, or null while paused or before the first frame.</summary>
    private double? ElapsedForTrack(double hostMs)
    {
        var origin = Volatile.Read(ref originMs);
        if (double.IsNaN(origin) || PauseOffset(hostMs) is not { } offset)
        {
            return null;
        }

        return Math.Max(0, hostMs - origin - offset);
    }

    private static void TrySetBorderless(GraphicsCaptureSession session)
    {
        // Windows 11 only, and the property throws on older builds.
        if (Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
        {
            try
            {
                _ = GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
                session.IsBorderRequired = false;
            }
            catch (Exception exception) when (exception is UnauthorizedAccessException or COMException)
            {
                // Recording continues with the system border.
            }
        }
    }

    // GraphicsCaptureItem.Closed did not fire for a closed window here, so the window itself is checked while no frames come.
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint window);

    private void ItemClosed(GraphicsCaptureItem sender, object args) => Report(CaptureFailureKind.Stream, "The capture item closed.");

    private void Report(CaptureFailureKind kind, string details)
    {
        var next = new CaptureFailure(kind, details);
        if (!stopping && Interlocked.CompareExchange(ref failure, next, null) is null)
        {
            Failed?.Invoke(next);
        }
    }

    private void Run()
    {
        try
        {
            while (!stopping)
            {
                frameReady.WaitOne(KeepAliveMs);
                var captured = false;
                while (framePool.TryGetNextFrame() is { } frame)
                {
                    using (frame)
                    {
                        captured = true;
                        HandleFrame(frame);
                    }
                }

                // Checked with frames arriving too: this app's own windows are captured through their monitor.
                if (recordedWindow != 0 && !IsWindow(recordedWindow))
                {
                    Report(CaptureFailureKind.Stream, "The recorded window closed.");
                    return;
                }

                if (!captured)
                {
                    RepeatLastFrame();
                }
            }
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException)
        {
            // A lost GPU device, for example. Nothing more can be recorded.
            Report(CaptureFailureKind.ScreenWriter, $"0x{exception.HResult:X8}");
        }
    }

    private void HandleFrame(Direct3D11CaptureFrame frame)
    {
        var size = frame.ContentSize;
        if (size.Width != poolSize.Width || size.Height != poolSize.Height)
        {
            // A resized window. Output size stays fixed; the frame is clipped or padded (window.jsonl is future work on macOS too).
            poolSize = size;
            framePool.Recreate(captureDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, FramePoolSize, size);
        }

        var host = frame.SystemRelativeTime.TotalMilliseconds;
        if (PauseOffset(host) is not { } offset)
        {
            return;
        }

        if (double.IsNaN(originMs))
        {
            Volatile.Write(ref originMs, host);
            telemetry.MarkFirstVideoFrame(host);
        }

        var pts = Math.Max(0, host - originMs - offset);
        // WGC can run at the display rate; the file is capped like the macOS stream. An encoder that cannot keep up loses frames
        // rather than letting memory grow. A kept-alive repeat can already have written past this frame's time.
        if (pts <= lastPtsMs || !pacer.Accept(pts) || writer.IsVideoBacklogged)
        {
            framesDropped++;
            return;
        }

        var started = Stopwatch.GetTimestamp();
        using (var texture = TextureOf(frame))
        {
            var box = new Box(sourceX, sourceY, 0, Math.Min(sourceX + width, size.Width), Math.Min(sourceY + height, size.Height), 1);
            context.CopySubresourceRegion(frameCopy, 0, 0, 0, 0, texture, 0, box);
        }

        converter.Convert(frameView, nv12);
        convertTotalMs += (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
        WriteCurrent(pts, host);
        framesWritten++;
    }

    private void WriteCurrent(double pts, double host)
    {
        writer.WriteFrame(nv12, pts, 1000.0 / MaxFps);
        lastPtsMs = pts;
        lastWriteHostMs = host;
        if (!hasFrame)
        {
            hasFrame = true;
            firstFrame.Set();
        }
    }

    /// <summary>WGC sends nothing while the screen is static. Writing anyway keeps fragments flowing, so a crash loses at most 2 s.</summary>
    private void RepeatLastFrame()
    {
        if (!hasFrame)
        {
            return;
        }

        var now = NowMs();
        if (now - lastWriteHostMs >= KeepAliveMs && PauseOffset(now) is { } offset)
        {
            WriteCurrent(Math.Max(lastPtsMs + 1, now - originMs - offset), now);
            framesRepeated++;
        }
    }

    private static unsafe ID3D11Texture2D TextureOf(Direct3D11CaptureFrame frame)
    {
        var abi = ((IWinRTObject)frame.Surface).NativeObject.ThisPtr;
        var iid = DxgiInterfaceAccessIid;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(abi, in iid, out var access));
        try
        {
            var textureIid = typeof(ID3D11Texture2D).GUID;
            var getInterface = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)(*(nint**)access)[3];
            nint texture;
            Marshal.ThrowExceptionForHR(getInterface(access, &textureIid, &texture));
            return new ID3D11Texture2D(texture);
        }
        finally
        {
            Marshal.Release(access);
        }
    }

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgiDevice, out nint graphicsDevice);
}
