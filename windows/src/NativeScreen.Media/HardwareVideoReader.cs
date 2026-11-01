using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

public sealed class HardwareVideoReader : IDisposable
{
    private readonly IMFSourceReader reader;
    private bool started;

    public HardwareVideoReader(string path, IUnknown deviceManager)
    {
        if (!started)
        {
            MediaFactory.MFStartup();
            started = true;
        }

        var attributes = MediaFactory.MFCreateAttributes(4);
        attributes.Set(SourceReaderAttributeKeys.D3DManager, deviceManager);
        attributes.Set(SourceReaderAttributeKeys.EnableAdvancedVideoProcessing, false);
        attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, true);
        reader = MediaFactory.MFCreateSourceReaderFromURL(path, attributes);
        reader.SetStreamSelection(SourceReaderIndex.AllStreams, false);
        reader.SetStreamSelection(SourceReaderIndex.FirstVideoStream, true);

        var output = MediaFactory.MFCreateMediaType();
        output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        output.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
        reader.SetCurrentMediaType(SourceReaderIndex.FirstVideoStream, output);
        // VERIFY: samples arrive as IMFDXGIBuffer on the compositor device. Convert with Nv12ToRgb.hlsl.
    }

    public double? ReadNextPresentationMs()
    {
        var sample = reader.ReadSample(
            SourceReaderIndex.FirstVideoStream,
            SourceReaderControlFlag.None,
            out _,
            out var flags,
            out _);
        if (flags.HasFlag(SourceReaderFlag.EndOfStream) || sample is null)
        {
            return null;
        }

        var pts = sample.SampleTime;
        sample.Dispose();
        return pts / 10_000.0;
    }

    public void Dispose() => reader.Dispose();
}
