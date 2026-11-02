using System.Buffers.Binary;
using System.Text;

namespace NativeScreen.Media;

/// <summary>
/// True presentation times of one track of a fragmented MP4, read from its boxes. Media Foundation writes fragments without
/// tfdt, and its own reader then estimates each fragment's start, wrong by up to hundreds of ms until the next keyframe
/// (spec/06 ADR-22). The durations in the file are exact, so a reader uses this table instead of the times MF reports.
/// </summary>
internal sealed class Mp4FragmentIndex
{
    private const uint NonSyncSampleFlag = 0x00010000;
    private const int MaximumBoxInMemory = 64 * 1024 * 1024;

    private Mp4FragmentIndex(double[] timesMs, int[] keyframes)
    {
        TimesMs = timesMs;
        Keyframes = keyframes;
    }

    /// <summary>Milliseconds from the first sample, ascending. Index i is the i-th frame in presentation order.</summary>
    public double[] TimesMs { get; }

    /// <summary>Indices into TimesMs of samples a decoder can start at, ascending.</summary>
    public int[] Keyframes { get; }

    /// <summary>Null for a plain MP4, where Media Foundation's times are right, or a file this parser does not understand.</summary>
    public static Mp4FragmentIndex? TryRead(string path, string handler)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return Read(file, handler);
        }
        catch (Exception exception) when (exception is IOException or ArgumentOutOfRangeException or EndOfStreamException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The last keyframe at or before a time.</summary>
    public int KeyframeAtOrBefore(double ms)
    {
        var low = 0;
        var high = Keyframes.Length - 1;
        var best = 0;
        while (low <= high)
        {
            var middle = (low + high) / 2;
            if (TimesMs[Keyframes[middle]] <= ms)
            {
                best = middle;
                low = middle + 1;
            }
            else
            {
                high = middle - 1;
            }
        }

        return Keyframes.Length == 0 ? 0 : Keyframes[best];
    }

    /// <summary>The keyframe closest to a time, to recover the position when a seek landed somewhere else.</summary>
    public int NearestKeyframe(double ms)
    {
        var best = 0;
        var distance = double.MaxValue;
        foreach (var keyframe in Keyframes)
        {
            var current = Math.Abs(TimesMs[keyframe] - ms);
            if (current < distance)
            {
                distance = current;
                best = keyframe;
            }
        }

        return best;
    }

    private static Mp4FragmentIndex? Read(FileStream file, string handler)
    {
        var track = new TrackInfo();
        var samples = new List<(long Time, bool Sync)>();
        var nextTime = 0L;
        var header = new byte[16];
        var position = 0L;
        var sawFragment = false;
        while (position + 8 <= file.Length)
        {
            file.Position = position;
            file.ReadExactly(header, 0, 8);
            var size = (long)BinaryPrimitives.ReadUInt32BigEndian(header);
            var type = Encoding.ASCII.GetString(header, 4, 4);
            var bodyOffset = 8;
            if (size == 1)
            {
                file.ReadExactly(header, 8, 8);
                size = BinaryPrimitives.ReadInt64BigEndian(header.AsSpan(8));
                bodyOffset = 16;
            }
            else if (size == 0)
            {
                size = file.Length - position;
            }

            if (size < bodyOffset || size > file.Length - position && type != "mdat")
            {
                // A file cut by a crash ends in a partial box; everything before it is still good.
                break;
            }

            if (type is "moov" or "moof")
            {
                if (size > MaximumBoxInMemory)
                {
                    return null;
                }

                var body = new byte[size - bodyOffset];
                file.ReadExactly(body);
                if (type == "moov")
                {
                    if (!track.ReadMovie(body, handler))
                    {
                        return null;
                    }
                }
                else
                {
                    sawFragment = true;
                    ReadFragment(body, track, samples, ref nextTime);
                }
            }

            position += size;
        }

        if (!sawFragment || samples.Count == 0 || track.Timescale == 0)
        {
            return null;
        }

        samples.Sort((a, b) => a.Time.CompareTo(b.Time));
        var origin = samples[0].Time;
        var times = new double[samples.Count];
        var keyframes = new List<int>();
        for (var index = 0; index < samples.Count; index++)
        {
            times[index] = (samples[index].Time - origin) * 1000.0 / track.Timescale;
            if (samples[index].Sync)
            {
                keyframes.Add(index);
            }
        }

        return new Mp4FragmentIndex(times, keyframes.ToArray());
    }

    private static void ReadFragment(ReadOnlySpan<byte> moof, TrackInfo track, List<(long Time, bool Sync)> samples, ref long nextTime)
    {
        foreach (var (type, traf) in Boxes(moof))
        {
            if (type != "traf")
            {
                continue;
            }

            var bytes = moof.Slice(traf.Offset, traf.Length);
            var defaultDuration = track.DefaultDuration;
            var defaultFlags = track.DefaultFlags;
            var mine = false;
            foreach (var (childType, child) in Boxes(bytes))
            {
                var body = bytes.Slice(child.Offset, child.Length);
                switch (childType)
                {
                    case "tfhd":
                    {
                        var flags = BinaryPrimitives.ReadUInt32BigEndian(body) & 0xFFFFFF;
                        mine = BinaryPrimitives.ReadUInt32BigEndian(body[4..]) == track.Id;
                        var cursor = 8;
                        cursor += (flags & 0x1) != 0 ? 8 : 0;
                        cursor += (flags & 0x2) != 0 ? 4 : 0;
                        if ((flags & 0x8) != 0)
                        {
                            defaultDuration = BinaryPrimitives.ReadUInt32BigEndian(body[cursor..]);
                            cursor += 4;
                        }

                        cursor += (flags & 0x10) != 0 ? 4 : 0;
                        if ((flags & 0x20) != 0)
                        {
                            defaultFlags = BinaryPrimitives.ReadUInt32BigEndian(body[cursor..]);
                        }

                        break;
                    }

                    case "tfdt" when mine:
                        nextTime = body[0] == 1
                            ? BinaryPrimitives.ReadInt64BigEndian(body[4..])
                            : BinaryPrimitives.ReadUInt32BigEndian(body[4..]);
                        break;
                    case "trun" when mine:
                        ReadRun(body, defaultDuration, defaultFlags, samples, ref nextTime);
                        break;
                }
            }
        }
    }

    private static void ReadRun(ReadOnlySpan<byte> run, uint defaultDuration, uint defaultFlags, List<(long Time, bool Sync)> samples, ref long nextTime)
    {
        var flags = BinaryPrimitives.ReadUInt32BigEndian(run) & 0xFFFFFF;
        var version = run[0];
        var count = BinaryPrimitives.ReadUInt32BigEndian(run[4..]);
        var cursor = 8;
        cursor += (flags & 0x1) != 0 ? 4 : 0;
        uint? firstFlags = null;
        if ((flags & 0x4) != 0)
        {
            firstFlags = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
            cursor += 4;
        }

        for (var index = 0; index < count; index++)
        {
            var duration = defaultDuration;
            var sampleFlags = index == 0 && firstFlags is { } first ? first : defaultFlags;
            var compositionOffset = 0L;
            if ((flags & 0x100) != 0)
            {
                duration = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            cursor += (flags & 0x200) != 0 ? 4 : 0;
            if ((flags & 0x400) != 0)
            {
                sampleFlags = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            if ((flags & 0x800) != 0)
            {
                compositionOffset = version == 0
                    ? BinaryPrimitives.ReadUInt32BigEndian(run[cursor..])
                    : BinaryPrimitives.ReadInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            samples.Add((nextTime + compositionOffset, (sampleFlags & NonSyncSampleFlag) == 0));
            nextTime += duration;
        }
    }

    private static List<(string Type, (int Offset, int Length) Body)> Boxes(ReadOnlySpan<byte> data)
    {
        var results = new List<(string, (int, int))>();
        var position = 0;
        while (position + 8 <= data.Length)
        {
            var size = (int)BinaryPrimitives.ReadUInt32BigEndian(data[position..]);
            if (size < 8 || position + size > data.Length)
            {
                break;
            }

            results.Add((Encoding.ASCII.GetString(data.Slice(position + 4, 4)), (position + 8, size - 8)));
            position += size;
        }

        return results;
    }

    private sealed class TrackInfo
    {
        public uint Id { get; private set; }
        public uint Timescale { get; private set; }
        public uint DefaultDuration { get; private set; }
        public uint DefaultFlags { get; private set; }

        public bool ReadMovie(ReadOnlySpan<byte> moov, string handler)
        {
            foreach (var (type, box) in Boxes(moov))
            {
                if (type == "trak")
                {
                    ReadTrack(moov.Slice(box.Offset, box.Length), handler);
                }
            }

            if (Id == 0)
            {
                return false;
            }

            foreach (var (type, box) in Boxes(moov))
            {
                if (type != "mvex")
                {
                    continue;
                }

                var mvex = moov.Slice(box.Offset, box.Length);
                foreach (var (childType, child) in Boxes(mvex))
                {
                    var body = mvex.Slice(child.Offset, child.Length);
                    if (childType == "trex" && BinaryPrimitives.ReadUInt32BigEndian(body[4..]) == Id)
                    {
                        DefaultDuration = BinaryPrimitives.ReadUInt32BigEndian(body[12..]);
                        DefaultFlags = BinaryPrimitives.ReadUInt32BigEndian(body[20..]);
                    }
                }
            }

            return true;
        }

        private void ReadTrack(ReadOnlySpan<byte> trak, string handler)
        {
            uint id = 0;
            uint timescale = 0;
            var matches = false;
            foreach (var (type, box) in Boxes(trak))
            {
                var body = trak.Slice(box.Offset, box.Length);
                if (type == "tkhd")
                {
                    id = BinaryPrimitives.ReadUInt32BigEndian(body[(body[0] == 1 ? 20 : 12)..]);
                }
                else if (type == "mdia")
                {
                    foreach (var (childType, child) in Boxes(body))
                    {
                        var part = body.Slice(child.Offset, child.Length);
                        if (childType == "mdhd")
                        {
                            timescale = BinaryPrimitives.ReadUInt32BigEndian(part[(part[0] == 1 ? 20 : 12)..]);
                        }
                        else if (childType == "hdlr")
                        {
                            matches = Encoding.ASCII.GetString(part.Slice(8, 4)) == handler;
                        }
                    }
                }
            }

            if (matches && Id == 0)
            {
                Id = id;
                Timescale = timescale;
            }
        }
    }
}
