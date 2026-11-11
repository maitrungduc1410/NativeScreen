using System.Security.Cryptography;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using NativeScreen.Core;

namespace NativeScreen.Intelligence;

/// <summary>The portrait matting network, downloaded once on request (spec/04, spec/06 ADR-60).</summary>
public static class PersonSegmentationModel
{
    private const long Bytes = 25_888_640;
    private const string Sha256 = "07c308cf0fc7e6e8b2065a12ed7fc07e1de8febb7dc7839d7b7f15dd66584df9";
    private static readonly Uri DownloadUrl = new("https://huggingface.co/Xenova/modnet/resolve/fa2fa546052fba4c08921230a26cc69a333fca12/onnx/model.onnx");

    public const string SizeText = "26 MB";

    public static string LocalPath { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NativeScreen", "Models", "modnet.onnx");

    public static bool IsInstalled => File.Exists(LocalPath) && new FileInfo(LocalPath).Length == Bytes;

    /// <summary>Only ever called after the person asked for it. The file is checked against its known hash before it counts as installed.</summary>
    public static async Task DownloadAsync(IProgress<double>? progress, CancellationToken cancel)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(LocalPath)!);
        var partial = LocalPath + ".part";
        try
        {
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            using var response = await client.GetAsync(DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancel);
            response.EnsureSuccessStatusCode();
            await using (var source = await response.Content.ReadAsStreamAsync(cancel))
            await using (var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, FileOptions.Asynchronous))
            {
                var buffer = new byte[1 << 16];
                var written = 0L;
                int read;
                while ((read = await source.ReadAsync(buffer, cancel)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), cancel);
                    written += read;
                    progress?.Report(written / (double)Bytes);
                }
            }

            await using (var check = File.OpenRead(partial))
            {
                if (!Convert.ToHexStringLower(await SHA256.HashDataAsync(check, cancel)).Equals(Sha256, StringComparison.Ordinal))
                {
                    check.Close();
                    File.Delete(partial);
                    throw new IOException("The download was incomplete.");
                }
            }

            File.Move(partial, LocalPath, overwrite: true);
        }
        catch (Exception)
        {
            // A cancelled or failed download leaves nothing behind.
            TryDelete(partial);
            throw;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>Runs the matting network on a camera picture that has been cropped and mirrored like the prepared image.</summary>
public sealed class PersonSegmenter : IDisposable
{
    private readonly InferenceSession session;
    private readonly string inputName;

    public PersonSegmenter()
    {
        session = OnnxSessions.Preferred(PersonSegmentationModel.LocalPath, out var onGpu);
        OnGpu = onGpu;
        inputName = session.InputMetadata.Keys.First();
    }

    public bool OnGpu { get; }

    public void Dispose() => session.Dispose();

    /// <summary>Samples the frame into the network's input, so the frame's buffer can go back to its pool before inference. <paramref name="reuse"/> is filled when it has the right size.</summary>
    public static DenseTensor<float> Prepare(VideoFrame frame, Rect01 crop, bool mirror, int longSide, DenseTensor<float>? reuse = null)
    {
        var cropWidth = Math.Max(0.25, crop.Width) * frame.Width;
        var cropHeight = Math.Max(0.25, crop.Height) * frame.Height;
        var shrink = longSide / Math.Max(cropWidth, cropHeight);
        // The network halves its input five times, so sides must be multiples of 32.
        var width = Math.Max(32, (int)Math.Round(cropWidth * shrink / 32) * 32);
        var height = Math.Max(32, (int)Math.Round(cropHeight * shrink / 32) * 32);
        var input = reuse is not null && reuse.Dimensions[2] == height && reuse.Dimensions[3] == width ? reuse : new DenseTensor<float>([1, 3, height, width]);
        var span = input.Buffer.Span;
        var flip = !mirror;
        var originX = crop.X * frame.Width;
        var originY = crop.Y * frame.Height;
        var stepX = cropWidth / width;
        var stepY = cropHeight / height;
        var chromaStart = frame.Width * frame.Height;
        var pixels = frame.Nv12;
        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var along = flip ? width - 1 - x : x;
                var left = originX + along * stepX;
                var top = originY + y * stepY;
                var centerX = Math.Clamp((int)(left + stepX * 0.5), 0, frame.Width - 1);
                var centerY = Math.Clamp((int)(top + stepY * 0.5), 0, frame.Height - 1);
                // Four luma taps keep thin hair from flickering at this scale.
                var luma = 0;
                for (var tap = 0; tap < 4; tap++)
                {
                    var sampleX = Math.Clamp((int)(left + stepX * ((tap & 1) == 0 ? 0.25 : 0.75)), 0, frame.Width - 1);
                    var sampleY = Math.Clamp((int)(top + stepY * (tap < 2 ? 0.25 : 0.75)), 0, frame.Height - 1);
                    luma += pixels[sampleY * frame.Width + sampleX];
                }

                var chroma = chromaStart + (centerY / 2) * frame.Width + (centerX & ~1);
                var (r, g, b) = Nv12Pixel.Rgb((byte)(luma / 4), pixels[chroma], pixels[chroma + 1]);
                var at = y * width + x;
                span[at] = r * 2 - 1;
                span[width * height + at] = g * 2 - 1;
                span[width * height * 2 + at] = b * 2 - 1;
            }
        }

        return input;
    }

    /// <summary>Thread safe for one caller at a time. <paramref name="reuse"/> is filled when it has the right size.</summary>
    public PersonMask Run(DenseTensor<float> input, byte[]? reuse = null)
    {
        var height = input.Dimensions[2];
        var width = input.Dimensions[3];
        using var results = session.Run([NamedOnnxValue.CreateFromTensor(inputName, input)]);
        var matte = results[0].AsTensor<float>();
        var pixels = reuse is { Length: var length } && length == width * height ? reuse : new byte[width * height];
        for (var index = 0; index < pixels.Length; index++)
        {
            pixels[index] = (byte)(Math.Clamp(matte.GetValue(index), 0, 1) * 255 + 0.5f);
        }

        return new PersonMask(pixels, width, height);
    }
}

/// <summary>An exact mask for each decoded picture, waited for. A 30 fps camera in a 60 fps export shows each picture twice, and it is segmented once (spec/06 ADR-58).</summary>
public sealed class ExportPersonMasks : IPersonMaskSource, IDisposable
{
    private const int LongSide = 672;
    private readonly PersonSegmenter segmenter;
    private VideoFrame? lastFrame;
    private Rect01 lastCrop = Rect01.Full;
    private bool lastMirror;
    private PersonMask? lastMask;
    private DenseTensor<float>? tensor;

    private ExportPersonMasks(PersonSegmenter segmenter) => this.segmenter = segmenter;

    /// <summary>Null when the model is not installed or will not load: the export then shows the plain camera, like macOS without a mask.</summary>
    public static ExportPersonMasks? TryCreate()
    {
        if (!PersonSegmentationModel.IsInstalled)
        {
            return null;
        }

        try
        {
            return new ExportPersonMasks(new PersonSegmenter());
        }
        catch (OnnxRuntimeException)
        {
            return null;
        }
    }

    public PersonMask? MaskFor(VideoFrame frame, Rect01 crop, bool mirror)
    {
        if (ReferenceEquals(frame, lastFrame) && crop == lastCrop && mirror == lastMirror)
        {
            return lastMask;
        }

        lastFrame = frame;
        lastCrop = crop;
        lastMirror = mirror;
        tensor = PersonSegmenter.Prepare(frame, crop, mirror, LongSide, tensor);
        lastMask = segmenter.Run(tensor, lastMask?.Pixels);
        return lastMask;
    }

    public void Dispose() => segmenter.Dispose();
}

/// <summary>Never makes the render thread wait: it gets the newest finished mask, and the next picture is segmented on another thread.</summary>
public sealed class PreviewPersonMasks : IPersonMaskSource, IDisposable
{
    private const int LongSide = 320;
    private const long ModelCheckIntervalMs = 2000;
    private readonly object gate = new();
    private PersonSegmenter? segmenter;
    private PersonMask? mask;
    private VideoFrame? lastFrame;
    private Rect01 lastCrop = Rect01.Full;
    private bool lastMirror;
    private bool busy;
    private bool failed;
    private bool disposed;
    private long modelCheckedAt = -ModelCheckIntervalMs;
    private bool modelInstalled;

    // One job runs at a time, so these are only touched by it. Two masks take turns: a new job starts from a render call, after
    // the last frame that could still be reading the one it fills has finished.
    private byte[] picture = [];
    private DenseTensor<float>? tensor;
    private byte[]? spareMask;

    /// <summary>A new mask is ready, on a background thread. A paused preview redraws only on demand.</summary>
    public event Action? MaskUpdated;

    public PersonMask? MaskFor(VideoFrame frame, Rect01 crop, bool mirror)
    {
        PersonMask? current;
        lock (gate)
        {
            current = mask;
            if (busy || failed || disposed || (ReferenceEquals(frame, lastFrame) && crop == lastCrop && mirror == lastMirror) || !ModelReady())
            {
                return current;
            }

            busy = true;
            lastFrame = frame;
            lastCrop = crop;
            lastMirror = mirror;
        }

        // Copied here because the frame's buffer goes back to its pool once the decoder moves on. Sampling it takes
        // milliseconds per picture, so that part stays off this thread (spec/06 ADR-66).
        if (picture.Length != frame.Nv12.Length)
        {
            picture = new byte[frame.Nv12.Length];
        }

        Buffer.BlockCopy(frame.Nv12, 0, picture, 0, picture.Length);
        var job = frame with { Nv12 = picture };
        _ = Task.Run(() => Segment(job, crop, mirror));
        return current;
    }

    public void Dispose()
    {
        lock (gate)
        {
            disposed = true;
            MaskUpdated = null;
            if (!busy)
            {
                segmenter?.Dispose();
                segmenter = null;
            }
        }
    }

    private bool ModelReady()
    {
        var now = Environment.TickCount64;
        if (!modelInstalled && now - modelCheckedAt >= ModelCheckIntervalMs)
        {
            modelCheckedAt = now;
            modelInstalled = PersonSegmentationModel.IsInstalled;
        }

        return modelInstalled;
    }

    private void Segment(VideoFrame job, Rect01 crop, bool mirror)
    {
        PersonMask? result = null;
        try
        {
            segmenter ??= new PersonSegmenter();
            tensor = PersonSegmenter.Prepare(job, crop, mirror, LongSide, tensor);
            result = segmenter.Run(tensor, spareMask);
        }
        catch (OnnxRuntimeException)
        {
            lock (gate)
            {
                failed = true;
            }
        }

        Action? notify;
        lock (gate)
        {
            busy = false;
            if (disposed)
            {
                segmenter?.Dispose();
                segmenter = null;
                return;
            }

            if (result is not null)
            {
                spareMask = mask?.Pixels;
                mask = result;
            }

            notify = result is null ? null : MaskUpdated;
        }

        notify?.Invoke();
    }
}
