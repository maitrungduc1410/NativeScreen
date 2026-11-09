using NativeScreen.Media;

namespace NativeScreen.Media.Tests;

public sealed class WriterBacklogTests
{
    [Fact]
    public void ALiveWriterReportsItsBacklog()
    {
        var directory = Directory.CreateTempSubdirectory("ns-backlog-").FullName;
        try
        {
            const int width = 320;
            const int height = 240;
            var frame = new byte[width * height * 3 / 2];
            using var writer = new VideoFileWriter(Path.Combine(directory, "a.mp4"), width, height, 60, 2_000_000, hevc: false, fragmented: true);
            Assert.NotNull(writer.VideoBacklog);
            for (var index = 0; index < 30; index++)
            {
                writer.WriteFrame(frame, index * 1000.0 / 60, 1000.0 / 60);
                Assert.NotNull(writer.VideoBacklog);
                Assert.InRange(writer.VideoBacklog!.Value, 0, 30);
            }

            writer.Finish();
            Assert.False(writer.IsVideoBacklogged);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(2100, 0, null, false)] // the last frame of the file holds
    [InlineData(2100, 0, 5000d, false)] // a still screen: the next frame is far away
    [InlineData(4999, 0, 5000d, false)]
    [InlineData(2100, 0, 40d, true)] // a cut with frames in between
    [InlineData(100, 500, 516d, true)] // going back
    [InlineData(516, 500, 516d, false)]
    public void ItSeeksOnlyWhenThatGetsSomewhere(double sourceMs, double currentMs, double? nextMs, bool expected) =>
        Assert.Equal(expected, SequentialVideoSource.NeedsSeek(sourceMs, currentMs, nextMs));
}
