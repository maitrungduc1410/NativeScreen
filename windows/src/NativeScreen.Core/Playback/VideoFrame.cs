using System.Collections.Concurrent;

namespace NativeScreen.Core;

/// <summary>A decoded frame in tightly packed NV12, in system memory.</summary>
public sealed record VideoFrame(byte[] Nv12, int Width, int Height, double PresentationMs);

/// <summary>Reuses frame buffers, so memory stays flat for any project length.</summary>
public sealed class VideoFramePool
{
    private readonly ConcurrentBag<byte[]> free = [];

    public byte[] Rent(int size)
    {
        while (free.TryTake(out var buffer))
        {
            if (buffer.Length == size)
            {
                return buffer;
            }
        }

        return new byte[size];
    }

    public void Return(byte[] buffer) => free.Add(buffer);
}

/// <summary>What the render thread asks for: the newest decoded frame at or before a source time.</summary>
public interface IVideoFrameSource
{
    VideoFrame? FrameAt(double sourceMs);
}
