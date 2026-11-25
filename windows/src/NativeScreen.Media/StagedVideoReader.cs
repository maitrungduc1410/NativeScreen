using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

/// <summary>
/// Sequential decode for analysis (hover highlights, spec/06 ADR-108) that does not wait on the GPU for each frame. Reading a
/// decoded frame back with the source reader's own copy stalls until the GPU is done with it; here the decoder's texture is
/// copied into a ring of staging textures and each one is read two frames later, when the copy has long finished. Frames a
/// caller turns down are decoded and dropped with no copy at all. A 12 s 4K60 recording: 14 s scanned the old way, 7.7 s.
/// </summary>
public sealed class StagedVideoReader : IDisposable
{
    private const int Lag = 2;

    private readonly ID3D11Device device;
    private readonly ID3D11DeviceContext context;
    private readonly IMFDXGIDeviceManager manager;
    private readonly IMFSourceReader reader;
    private readonly Staging?[] ring = new Staging?[Lag + 1];

    private StagedVideoReader(string path, ID3D11Device device)
    {
        this.device = device;
        context = device.ImmediateContext;
        manager = MediaFactory.MFCreateDXGIDeviceManager();
        manager.ResetDevice(device);
        using (var attributes = MediaFactory.MFCreateAttributes(3))
        {
            attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, false);
            attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, true);
            attributes.Set(SourceReaderAttributeKeys.D3DManager, manager);
            reader = MediaFactory.MFCreateSourceReaderFromURL(path, attributes);
        }

        reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);
        using (var requested = MediaFactory.MFCreateMediaType())
        {
            requested.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            requested.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
            reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, requested);
        }

        using (var actual = reader.GetCurrentMediaType(SourceReaderIndex.FirstVideoStream))
        {
            var size = actual.GetUInt64(MediaTypeAttributeKeys.FrameSize);
            Width = (int)(size >> 32) & ~1;
            Height = (int)(size & 0xFFFFFFFF) & ~1;
        }

        DurationMs = reader.GetPresentationAttribute(SourceReaderIndex.MediaSource, PresentationDescriptionAttributeKeys.Duration) is var ticks ? Convert.ToInt64(ticks.Value) / 10_000.0 : 0;

        // A software decoder hands out frames in system memory: that file is read the usual way.
        using (var first = reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out _, out _))
        {
            using var buffer = first?.GetBufferByIndex(0);
            using var surface = buffer?.QueryInterfaceOrNull<IMFDXGIBuffer>();
            if (surface is null)
            {
                throw new COMException("Decoded frames are not textures.");
            }
        }

        reader.SetCurrentPosition(0);
    }

    public int Width { get; }

    public int Height { get; }

    public double DurationMs { get; }

    /// <summary>
    /// A reader for this file, or null when it needs <see cref="VideoFileReader"/>: no hardware video device, decoded frames that
    /// are not GPU textures, or a fragmented file whose times need the box index.
    /// </summary>
    public static StagedVideoReader? TryOpen(string path)
    {
        MediaFoundationRuntime.EnsureStarted();
        if (Mp4FragmentIndex.TryRead(path, "vide") is not null)
        {
            return null;
        }

        var result = D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.VideoSupport | DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device? device, out _, out ID3D11DeviceContext? created);
        created?.Dispose();
        if (result.Failure || device is null)
        {
            return null;
        }

        using (var protection = device.QueryInterface<ID3D11Multithread>())
        {
            protection.SetMultithreadProtected(true);
        }

        try
        {
            return new StagedVideoReader(path, device);
        }
        catch (Exception exception) when (exception is SharpGen.Runtime.SharpGenException or COMException)
        {
            device.Dispose();
            return null;
        }
    }

    /// <summary>
    /// Every frame in order, timed from the first frame like the recording. A frame <paramref name="wanted"/> turns down comes
    /// with no pixels. Pixels are packed NV12 (<see cref="Width"/> luma bytes per row, then the CbCr rows) in pool buffers.

    /// </summary>
    public IEnumerable<VideoFrame> Read(VideoFramePool pool, Func<double, bool> wanted)
    {
        var pending = new Queue<(int Slot, double TimeMs)>(ring.Length);
        var next = 0;
        double? startMs = null;
        while (true)
        {
            using var sample = reader.ReadSample(SourceReaderIndex.FirstVideoStream, SourceReaderControlFlag.None, out _, out var flags, out _);
            if (flags.HasFlag(SourceReaderFlag.EndOfStream))
            {
                break;
            }

            if (sample is null)
            {
                continue;
            }

            var reportedMs = sample.SampleTime / 10_000.0;
            startMs ??= reportedMs;
            var t = reportedMs - startMs.Value;
            if (!wanted(t))
            {
                // Frames come out in order, so the ones still on their way go first.
                while (pending.Count > 0)
                {
                    yield return Collect(pending.Dequeue(), pool);
                }

                yield return new VideoFrame([], Width, Height, t);
                continue;
            }

            Copy(sample, next);
            pending.Enqueue((next, t));
            next = (next + 1) % ring.Length;
            if (pending.Count > Lag)
            {
                yield return Collect(pending.Dequeue(), pool);
            }
        }

        while (pending.Count > 0)
        {
            yield return Collect(pending.Dequeue(), pool);
        }
    }

    private void Copy(IMFSample sample, int slot)
    {
        using var buffer = sample.GetBufferByIndex(0);
        using var surface = buffer.QueryInterface<IMFDXGIBuffer>();
        var slice = surface.SubresourceIndex;
        using var texture = new ID3D11Texture2D(surface.GetResource(typeof(ID3D11Texture2D).GUID));
        // The decoder pads its textures to whole macroblocks, so the staging copy takes their size and the rows past the
        // picture are skipped when reading.
        if (ring[slot] is null)
        {
            var description = texture.Description;
            ring[slot] = new Staging(
                device.CreateTexture2D(new Texture2DDescription(Format.NV12, description.Width, description.Height, 1, 1, BindFlags.None, ResourceUsage.Staging, CpuAccessFlags.Read)),
                (int)description.Height);
        }

        context.CopySubresourceRegion(ring[slot]!.Texture, 0, 0, 0, 0, texture, slice);
    }

    private unsafe VideoFrame Collect((int Slot, double TimeMs) item, VideoFramePool pool)
    {
        var staging = ring[item.Slot]!;
        var data = pool.Rent(Width * Height * 3 / 2);
        var mapped = context.Map(staging.Texture, 0, MapMode.Read);
        try
        {
            var source = (byte*)mapped.DataPointer;
            var pitch = (int)mapped.RowPitch;
            fixed (byte* target = data)
            {
                for (var y = 0; y < Height; y++)
                {
                    Buffer.MemoryCopy(source + y * pitch, target + y * Width, Width, Width);
                }

                // The chroma plane of a mapped NV12 texture follows all the luma rows, padding included, at the same pitch.
                var chroma = source + pitch * staging.PlaneHeight;
                for (var y = 0; y < Height / 2; y++)
                {
                    Buffer.MemoryCopy(chroma + y * pitch, target + Width * Height + y * Width, Width, Width);
                }
            }
        }
        finally
        {
            context.Unmap(staging.Texture, 0);
        }

        return new VideoFrame(data, Width, Height, item.TimeMs);
    }

    public void Dispose()
    {
        foreach (var staging in ring)
        {
            staging?.Texture.Dispose();
        }

        reader.Dispose();
        manager.Dispose();
        context.Dispose();
        device.Dispose();
    }

    /// <param name="PlaneHeight">Rows of the luma plane, padding included; the chroma plane starts after them.</param>
    private sealed record Staging(ID3D11Texture2D Texture, int PlaneHeight);
}
