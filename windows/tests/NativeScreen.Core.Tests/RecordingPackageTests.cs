using NativeScreen.Core;

namespace NativeScreen.Core.Tests;

public sealed class RecordingPackageTests
{
    [Fact]
    public void KeyStrokesUseTheNamesOfTheMacRecorder()
    {
        Assert.Equal("Delete", KeyTelemetry.KeyName(0x08, '\b'));
        Assert.Equal("ForwardDelete", KeyTelemetry.KeyName(0x2E, '\0'));
        Assert.Equal("F5", KeyTelemetry.KeyName(0x74, '\0'));
        Assert.Equal("A", KeyTelemetry.KeyName(0x41, 'a'));
        Assert.Null(KeyTelemetry.KeyName(0xFF, '\0'));

        var shortcut = KeyTelemetry.Stroke(5, false, false, true, false, true, "P");
        Assert.Equal("shortcut", shortcut.Kind);
        Assert.Equal(["Shift", "Ctrl"], shortcut.Modifiers);
        Assert.Equal("typing", KeyTelemetry.Stroke(5, false, false, true, false, false, "P").Kind);
        Assert.Equal("shortcut", KeyTelemetry.Stroke(5, false, false, false, false, false, "ArrowUp").Kind);
        Assert.Null(KeyTelemetry.Stroke(5, false, false, false, false, false, "Q").Modifiers);
    }

    [Theory]
    [InlineData(44100, 2)]
    [InlineData(48000, 1)]
    [InlineData(96000, 8)]
    public void ConverterKeepsDurationAndPitch(int rate, int channels)
    {
        const double hertz = 440;
        var converter = new PcmConverter(rate, channels, true, 32, 48000, 2);
        var buffer = new byte[rate / 10 * channels * 4];
        var result = new List<short>();
        var frame = 0;
        for (var block = 0; block < 10; block++)
        {
            for (var i = 0; i < rate / 10; i++, frame++)
            {
                var value = (float)(Math.Sin(frame * 2 * Math.PI * hertz / rate) * 0.5);
                for (var channel = 0; channel < channels; channel++)
                {
                    BitConverter.TryWriteBytes(buffer.AsSpan((i * channels + channel) * 4), value);
                }
            }

            result.AddRange(converter.Convert(buffer).ToArray());
        }

        Assert.InRange(result.Count / 2, 47800, 48200);
        var crossings = 0;
        for (var i = 2; i < result.Count; i += 2)
        {
            if (result[i - 2] < 0 && result[i] >= 0)
            {
                crossings++;
            }
        }

        Assert.InRange(crossings, 438, 442);
    }

    [Fact]
    public void FinishWritesAProjectThatLoads()
    {
        var root = Directory.CreateTempSubdirectory("ns-package-").FullName;
        try
        {
            var package = RecordingPackage.Create(root, new DateTime(2026, 11, 2, 9, 30, 0));
            Assert.EndsWith("Recording 2026-11-02 09.30.00.nativescreen", package);
            ProjectStore.WriteLines(Path.Combine(package, "recording", "telemetry", "clicks.jsonl"), new[] { new ClickEvent { T = 1000, Type = "down", Button = "left", X = 0.5, Y = 0.5, Count = 1 } });
            var target = new CaptureTargetMetadata { AppName = "Notepad", PixelSize = new PixelDimensions { Width = 100, Height = 100 } };
            RecordingPackage.Finish(package, target, 6000, false, true, false, true, DateTimeOffset.UtcNow);
            var loaded = new LoadedProject(package);
            Assert.Equal("Notepad", loaded.Document.Name);
            Assert.Equal("windows", loaded.Metadata.Platform);
            Assert.Equal("microphone.m4a", loaded.Metadata.Tracks.MicrophoneAudio);
            Assert.Null(loaded.Metadata.Tracks.SystemAudio);
            Assert.Single(loaded.Document.Timeline.Zooms);
            Assert.Equal(6000, loaded.Document.Timeline.Slices[0].SourceEndMs);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
