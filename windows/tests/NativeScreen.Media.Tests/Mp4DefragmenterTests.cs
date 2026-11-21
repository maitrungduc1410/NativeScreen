using System.Buffers.Binary;
using System.Text;
using NativeScreen.Media;

namespace NativeScreen.Media.Tests;

/// <summary>A finished recording becomes a plain MP4 that other players read, with the same frames at the same times.</summary>
public sealed class Mp4DefragmenterTests : IDisposable
{
    private const int Width = 640;
    private const int Height = 360;
    private readonly string directory = Directory.CreateTempSubdirectory("ns-defragment-").FullName;

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public void AFragmentedRecordingBecomesPlainWithTheSameFramesAndTimes()
    {
        var (path, written) = WriteClip(fragmented: true);
        Assert.Contains("moof", TopLevelBoxes(path));

        Assert.True(Mp4Defragmenter.TryRewrite(path));

        var boxes = TopLevelBoxes(path);
        Assert.Equal(["ftyp", "moov", "mdat"], boxes);
        var read = ReadTimes(path);
        Assert.Equal(written.Count, read.Count);
        for (var index = 0; index < written.Count; index++)
        {
            Assert.True(Math.Abs(read[index] - written[index]) < 2, $"frame {index}: read {read[index]}, written {written[index]}");
        }

        Assert.False(File.Exists(path + ".plain.tmp"));
    }

    [Fact]
    public void APlainFileIsLeftAlone()
    {
        var (path, _) = WriteClip(fragmented: false);
        var before = File.ReadAllBytes(path);

        Assert.False(Mp4Defragmenter.TryRewrite(path));
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    [Fact]
    public void ARecordingCutByACrashKeepsItsCompleteFragments()
    {
        var (path, written) = WriteClip(fragmented: true);
        using (var file = new FileStream(path, FileMode.Open))
        {
            file.SetLength(file.Length * 6 / 10);
        }

        Assert.True(Mp4Defragmenter.TryRewrite(path));

        var read = ReadTimes(path);
        Assert.InRange(read.Count, 30, written.Count - 1);
        for (var index = 0; index < read.Count; index++)
        {
            Assert.True(Math.Abs(read[index] - written[index]) < 2, $"frame {index}: read {read[index]}, written {written[index]}");
        }
    }

    private (string Path, List<double> Written) WriteClip(bool fragmented)
    {
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".mp4");
        var written = new List<double>();
        var nv12 = new byte[Width * Height * 3 / 2];
        var time = 0.0;
        using (var writer = new VideoFileWriter(path, Width, Height, 60, 4_000_000, hevc: false, fragmented: fragmented))
        {
            for (var index = 0; index < 240; index++)
            {
                Array.Fill(nv12, (byte)(30 + index % 60 * 3), 0, Width * Height);
                Array.Fill(nv12, (byte)128, Width * Height, Width * Height / 2);
                writer.WriteFrame(nv12, time, 1000.0 / 60);
                written.Add(time);
                // Still moments between bursts, like a real screen.
                time += index % 25 == 24 ? 250 : 1000.0 / 60;
            }
        }

        return (path, written);
    }

    private static List<double> ReadTimes(string path)
    {
        var times = new List<double>();
        using var reader = new VideoFileReader(path);
        while (reader.ReadNext() is { } frame)
        {
            times.Add(frame.PresentationMs);
        }

        return times;
    }

    private static List<string> TopLevelBoxes(string path)
    {
        var boxes = new List<string>();
        using var file = File.OpenRead(path);
        var header = new byte[16];
        var position = 0L;
        while (position + 8 <= file.Length)
        {
            file.Position = position;
            file.ReadExactly(header, 0, 8);
            var size = (long)BinaryPrimitives.ReadUInt32BigEndian(header);
            if (size == 1)
            {
                file.ReadExactly(header, 8, 8);
                size = BinaryPrimitives.ReadInt64BigEndian(header.AsSpan(8));
            }

            boxes.Add(Encoding.ASCII.GetString(header, 4, 4));
            if (size < 8)
            {
                break;
            }

            position += size;
        }

        return boxes;
    }
}
