using SharpGen.Runtime;
using Vortice.MediaFoundation;

namespace NativeScreen.Media;

public sealed class FragmentedMp4Writer : IDisposable
{
    private readonly IMFSinkWriter writer;
    private readonly int videoStream;
    private bool cancelled;

    private readonly string path;
    private bool disposed;

    public FragmentedMp4Writer(string path, int width, int height, int fps, int bitrate, bool hevc, IUnknown deviceManager)
    {
        this.path = path;
        MediaFactory.MFStartup();
        var attributes = MediaFactory.MFCreateAttributes(3);
        attributes.Set(SinkWriterAttributeKeys.ReadwriteEnableHardwareTransforms, true);
        attributes.Set(SinkWriterAttributeKeys.D3DManager, deviceManager);
        attributes.Set(TranscodeAttributeKeys.TranscodeContainertype, TranscodeContainerTypeGuids.Fmpeg4);
        writer = MediaFactory.MFCreateSinkWriterFromURL(path, null, attributes);

        var output = MediaFactory.MFCreateMediaType();
        output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        output.Set(MediaTypeAttributeKeys.Subtype, hevc ? VideoFormats.Hevc : VideoFormats.H264);
        output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrate);
        output.Set(MediaTypeAttributeKeys.FrameSize, ((ulong)width << 32) | (uint)height);
        output.Set(MediaTypeAttributeKeys.FrameRate, ((ulong)fps << 32) | 1ul);
        output.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
        output.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, (uint)(fps * ExportPlanSeconds));
        videoStream = writer.AddStream(output);

        var input = MediaFactory.MFCreateMediaType();
        input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        input.Set(MediaTypeAttributeKeys.Subtype, VideoFormats.Nv12);
        input.Set(MediaTypeAttributeKeys.FrameSize, ((ulong)width << 32) | (uint)height);
        input.Set(MediaTypeAttributeKeys.FrameRate, ((ulong)fps << 32) | 1ul);
        writer.SetInputMediaType(videoStream, input, null);
        writer.BeginWriting();
        // VERIFY: ICodecAPI quality 87/72/58/42 via GetServiceForStream. If Quality mode is rejected, use the bitrate above.
        // VERIFY: the active MFT is hardware. BT.709 limited tags are written on the output type.
        // VERIFY: recording uses MFCreateFMPEG4MediaSink with 2 second fragments instead of this URL writer.
    }

    private const int ExportPlanSeconds = 2;

    public void Cancel() => cancelled = true;

    public void Finish(bool deletePartial)
    {
        if (!disposed && !cancelled && !deletePartial)
        {
            writer.Finalize();
        }

        Dispose();
        if ((cancelled || deletePartial) && File.Exists(path))
        {
            File.Delete(path);
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        writer.Dispose();
    }
}
