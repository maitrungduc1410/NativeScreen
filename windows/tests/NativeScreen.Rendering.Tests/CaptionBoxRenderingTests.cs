using NativeScreen.Core;

namespace NativeScreen.Rendering.Tests;

/// <summary>Caption boxes that the line spring takes past zero width must not stop the compositor.</summary>
public sealed class CaptionBoxRenderingTests
{
    private sealed class OneFrame(VideoFrame frame) : IVideoFrameSource
    {
        public VideoFrame? FrameAt(double sourceMs) => frame;
    }

    [Fact]
    public void ABoxThatOvershootsPastZeroWidthIsSkipped()
    {
        // A block that starts 186 ms after the previous one ends: while it fades in, its expanding box springs from the old line
        // and reaches a negative width (about -127 px at 5060 ms on a 1600 x 900 canvas). Its blur patch used to ask for a
        // texture of negative size, which threw and stopped the preview for good.
        var document = new ProjectDocument();
        document.Timeline.Slices = [new ClipSlice { Id = "s", SourceStartMs = 0, SourceEndMs = 20000 }];
        document.Captions.Enabled = true;
        document.Captions.CaptionTracks = [new CaptionTrack { Id = "t" }];
        document.Captions.CaptionBlocks =
        [
            new CaptionBlock { Id = "a", TrackId = "t", SourceStartMs = 500, SourceEndMs = 4800, CustomText = "Find any release in a second" },
            new CaptionBlock { Id = "b", TrackId = "t", SourceStartMs = 4986, SourceEndMs = 9600, CustomText = "Switch the chart from weeks to months" }
        ];
        var pixels = new byte[1920 * 1080 * 3 / 2];
        pixels.AsSpan(1920 * 1080).Fill(128);
        using var compositor = new FrameCompositor();
        var trajectory = new PlaybackTrajectorySolver(20000, [], [], document);
        for (var t = 4990.0; t <= 5200; t += 10)
        {
            compositor.Compose(new ComposeRequest { Document = document, Trajectory = trajectory, SourceMs = t, TimelineMs = t, ScreenSource = new OneFrame(new VideoFrame(pixels, 1920, 1080, 0)), ScreenWidth = 1920, ScreenHeight = 1080 }, 1600, 900);
        }
    }
}
