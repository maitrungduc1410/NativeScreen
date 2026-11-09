using System.Text;
using NativeScreen.Core;
using NativeScreen.Export;

namespace NativeScreen.Rendering.Tests;

/// <summary>A file with a low tone then a high tone, cut in two and moved apart: each half has to play its own tone and stop on time.</summary>
public sealed class VoiceoverCutMixTests : IDisposable
{
    private const int Rate = 48000;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-vo-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    private void WriteTones()
    {
        Directory.CreateDirectory(Path.Combine(directory, "assets"));
        const int frames = Rate * 2;
        using var writer = new BinaryWriter(File.Create(Path.Combine(directory, "assets", "vo.wav")), Encoding.ASCII);
        writer.Write("RIFF"u8);
        writer.Write(36 + frames * 2);
        writer.Write("WAVEfmt "u8);
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(Rate);
        writer.Write(Rate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(frames * 2);
        for (var frame = 0; frame < frames; frame++)
        {
            var hertz = frame < Rate ? 300.0 : 1200.0;
            writer.Write((short)(Math.Sin(2 * Math.PI * hertz * frame / Rate) * 12000));
        }
    }

    private static int ZeroCrossings(byte[] pcm, int fromMs, int toMs)
    {
        short Left(int frame) => BitConverter.ToInt16(pcm, frame * 4);
        var count = 0;
        var end = toMs * Rate / 1000;
        for (var frame = fromMs * Rate / 1000 + 1; frame < end; frame++)
        {
            if (Left(frame) >= 0 != Left(frame - 1) >= 0)
            {
                count++;
            }
        }

        return count;
    }

    private static double Peak(byte[] pcm, int fromMs, int toMs)
    {
        var peak = 0.0;
        var end = toMs * Rate / 1000;
        for (var frame = fromMs * Rate / 1000; frame < end; frame++)
        {
            peak = Math.Max(peak, Math.Abs((int)BitConverter.ToInt16(pcm, frame * 4)));
        }

        return peak;
    }

    [Fact]
    public void EachHalfPlaysItsOwnPartAndStopsOnTime()
    {
        WriteTones();
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 6000 }];
        document.Timeline.Voiceovers =
        [
            new VoiceoverSegment { Id = "a", SourceStartMs = 0, DurationMs = 1000, RelativePath = "assets/vo.wav" },
            new VoiceoverSegment { Id = "b", SourceStartMs = 3000, DurationMs = 1000, RelativePath = "assets/vo.wav", FileOffsetMs = 1000 }
        ];
        using var mixer = new AudioMixer(document, directory, new RecordingTracksMetadata(), new NLETimeMapper(document.Timeline.Slices));
        Assert.Equal(Rate, AudioMixer.OutputFormat.SampleRate);
        var pcm = new byte[Rate * 6 * 4];
        var chunk = new byte[480 * 4];
        for (var done = 0; done < Rate * 6; done += 480)
        {
            mixer.Render(chunk, 480);
            chunk.CopyTo(pcm, done * 4);
        }

        // 300 Hz crosses zero 60 times in 100 ms, and 1200 Hz 240 times.
        Assert.InRange(ZeroCrossings(pcm, 400, 500), 55, 65);
        Assert.InRange(ZeroCrossings(pcm, 3400, 3500), 235, 245);
        Assert.True(Peak(pcm, 1100, 2900) < 50, "the first half played past its end");
        Assert.True(Peak(pcm, 4100, 5900) < 50, "the second half played past its end");
    }
}
