namespace NativeScreen.Media.Tests;

public sealed class UnalignedWidthRoundTripTests
{
    [Fact]
    public void AWidthThatIsNotAMultipleOfSixteenDecodesWithoutShear()
    {
        const int width = 1900;
        const int height = 1190;
        var path = Path.Combine(Path.GetTempPath(), $"ns-unaligned-{Guid.NewGuid():N}.mp4");
        try
        {
            var frame = new byte[width * height * 3 / 2];
            for (var y = 0; y < height; y++)
            {
                for (var x = 0; x < width; x++)
                {
                    frame[y * width + x] = (byte)(x / 200 % 2 == 0 ? 40 : 200);
                }
            }

            Array.Fill(frame, (byte)128, width * height, width * height / 2);
            using (var writer = new VideoFileWriter(path, width, height, 30, 12_000_000, hevc: false, fragmented: true))
            {
                for (var index = 0; index < 8; index++)
                {
                    writer.WriteFrame(frame, index * 1000.0 / 30, 1000.0 / 30);
                }
            }

            using var reader = new VideoFileReader(path);
            Assert.Equal(width, reader.Width);
            var decoded = reader.ReadNext();
            Assert.NotNull(decoded);
            foreach (var y in new[] { 10, height / 2, height - 10 })
            {
                Assert.InRange(decoded!.Nv12[y * width + 100], 20, 70);
                Assert.InRange(decoded.Nv12[y * width + 300], 170, 225);
                Assert.InRange(decoded.Nv12[y * width + 500], 20, 70);
            }
        }
        finally
        {
            File.Delete(path);
        }
    }
}
