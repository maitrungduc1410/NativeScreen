using System.Buffers.Binary;
using System.Text;

namespace NativeScreen.Media;

/// <summary>
/// Rewrites a fragmented MP4 that Media Foundation recorded as a plain one: one moov with full sample tables, then one mdat
/// with the same samples. Nothing is decoded or encoded. Other readers (AVFoundation, QuickTime) see a fragmented file
/// without tfdt as a track of zero length, so a Windows recording played as black with no sound on a Mac (spec/06 ADR-22).
/// The recording stays fragmented while it runs, so a crash still leaves a file this app can read.
/// </summary>
public static class Mp4Defragmenter
{
    private const uint NonSyncSampleFlag = 0x00010000;
    private const int MaximumBoxInMemory = 64 * 1024 * 1024;
    private const int CopyBufferBytes = 4 * 1024 * 1024;

    /// <summary>
    /// Replaces <paramref name="path"/> with a plain MP4 of the same samples. Returns false and leaves the file as it was when
    /// it is not fragmented, has nothing to rewrite, or anything fails (the fragmented file stays readable here).
    /// </summary>
    public static bool TryRewrite(string path)
    {
        var temporary = path + ".plain.tmp";
        try
        {
            Movie? movie;
            using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                movie = Read(source);
                if (movie is null)
                {
                    return false;
                }

                using var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, CopyBufferBytes);
                Write(movie, source, output);
                output.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentOutOfRangeException or InvalidDataException or OverflowException)
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
            {
                // A stray temporary file is harmless; the recording itself is untouched.
            }

            return false;
        }
    }

    // MARK: Reading

    private sealed class Track
    {
        public required uint Id { get; init; }
        public required byte[] Trak { get; init; }
        public required uint Timescale { get; init; }
        public required bool IsVideo { get; init; }
        public uint DefaultDuration { get; set; }
        public uint DefaultSize { get; set; }
        public uint DefaultFlags { get; set; }
        public List<uint> Durations { get; } = [];
        public List<uint> Sizes { get; } = [];
        public List<int> CompositionOffsets { get; } = [];
        public List<int> SyncSamples { get; } = [];
        public List<(long Offset, long Bytes, int Samples)> Chunks { get; } = [];
    }

    private sealed class Movie
    {
        public required byte[] Moov { get; init; }
        public required List<Track> Tracks { get; init; }
        public required uint MovieTimescale { get; init; }
    }

    private static Movie? Read(FileStream file)
    {
        byte[]? moov = null;
        List<Track>? tracks = null;
        var sawFragment = false;
        var header = new byte[16];
        var position = 0L;
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

            if (size < bodyOffset || size > file.Length - position)
            {
                // A file cut by a crash ends in a partial box; the complete fragments before it are kept.
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
                    moov = body;
                    tracks = ReadTracks(body);
                }
                else if (tracks is not null)
                {
                    sawFragment = true;
                    ReadFragment(body, position, tracks, file.Length);
                }
            }

            position += size;
        }

        if (!sawFragment || moov is null || tracks is null || tracks.Count == 0 || tracks.All(track => track.Sizes.Count == 0))
        {
            return null;
        }

        var mvhd = Child(moov, "mvhd") ?? throw new InvalidDataException("no mvhd");
        var movieTimescale = BinaryPrimitives.ReadUInt32BigEndian(mvhd.AsSpan(mvhd[0] == 1 ? 20 : 12));
        return new Movie { Moov = moov, Tracks = tracks, MovieTimescale = movieTimescale == 0 ? 1000 : movieTimescale };
    }

    private static List<Track> ReadTracks(byte[] moov)
    {
        var tracks = new List<Track>();
        foreach (var (type, offset, length) in Boxes(moov))
        {
            if (type != "trak")
            {
                continue;
            }

            var trak = moov.AsSpan(offset, length).ToArray();
            var tkhd = Child(trak, "tkhd") ?? throw new InvalidDataException("no tkhd");
            var mdia = Child(trak, "mdia") ?? throw new InvalidDataException("no mdia");
            var mdhd = Child(mdia, "mdhd") ?? throw new InvalidDataException("no mdhd");
            var hdlr = Child(mdia, "hdlr") ?? throw new InvalidDataException("no hdlr");
            tracks.Add(new Track
            {
                Id = BinaryPrimitives.ReadUInt32BigEndian(tkhd.AsSpan(tkhd[0] == 1 ? 20 : 12)),
                Trak = trak,
                Timescale = BinaryPrimitives.ReadUInt32BigEndian(mdhd.AsSpan(mdhd[0] == 1 ? 20 : 12)),
                IsVideo = Encoding.ASCII.GetString(hdlr, 8, 4) == "vide"
            });
        }

        if (Child(moov, "mvex") is { } mvex)
        {
            foreach (var (type, offset, length) in Boxes(mvex))
            {
                var trex = mvex.AsSpan(offset, length);
                var id = type == "trex" ? BinaryPrimitives.ReadUInt32BigEndian(trex[4..]) : 0;
                if (id != 0 && tracks.Find(track => track.Id == id) is { } track)
                {
                    track.DefaultDuration = BinaryPrimitives.ReadUInt32BigEndian(trex[12..]);
                    track.DefaultSize = BinaryPrimitives.ReadUInt32BigEndian(trex[16..]);
                    track.DefaultFlags = BinaryPrimitives.ReadUInt32BigEndian(trex[20..]);
                }
            }
        }

        return tracks;
    }

    private static void ReadFragment(byte[] moof, long moofStart, List<Track> tracks, long fileLength)
    {
        // Without an explicit base, the first track fragment starts at the moof and each next one where the previous data ended.
        var implicitBase = moofStart;
        foreach (var (type, offset, length) in Boxes(moof))
        {
            if (type != "traf")
            {
                continue;
            }

            var traf = moof.AsSpan(offset, length);
            Track? track = null;
            var baseOffset = implicitBase;
            uint duration = 0, size = 0, flags = 0;
            var dataEnd = implicitBase;
            var first = true;
            foreach (var (childType, childOffset, childLength) in Boxes(traf))
            {
                var body = traf.Slice(childOffset, childLength);
                if (childType == "tfhd")
                {
                    var tfhdFlags = BinaryPrimitives.ReadUInt32BigEndian(body) & 0xFFFFFF;
                    var id = BinaryPrimitives.ReadUInt32BigEndian(body[4..]);
                    track = tracks.Find(item => item.Id == id);
                    if (track is null)
                    {
                        break;
                    }

                    (duration, size, flags) = (track.DefaultDuration, track.DefaultSize, track.DefaultFlags);
                    var cursor = 8;
                    if ((tfhdFlags & 0x1) != 0)
                    {
                        baseOffset = BinaryPrimitives.ReadInt64BigEndian(body[cursor..]);
                        cursor += 8;
                    }
                    else if ((tfhdFlags & 0x20000) != 0)
                    {
                        baseOffset = moofStart;
                    }

                    cursor += (tfhdFlags & 0x2) != 0 ? 4 : 0;
                    if ((tfhdFlags & 0x8) != 0)
                    {
                        duration = BinaryPrimitives.ReadUInt32BigEndian(body[cursor..]);
                        cursor += 4;
                    }

                    if ((tfhdFlags & 0x10) != 0)
                    {
                        size = BinaryPrimitives.ReadUInt32BigEndian(body[cursor..]);
                        cursor += 4;
                    }

                    if ((tfhdFlags & 0x20) != 0)
                    {
                        flags = BinaryPrimitives.ReadUInt32BigEndian(body[cursor..]);
                    }

                    dataEnd = baseOffset;
                }
                else if (childType == "trun" && track is not null)
                {
                    dataEnd = ReadRun(body, track, first ? baseOffset : dataEnd, baseOffset, duration, size, flags, fileLength);
                    first = false;
                }
            }

            implicitBase = dataEnd;
        }
    }

    /// <summary>Adds one run's samples as one chunk. Returns where its data ends.</summary>
    private static long ReadRun(ReadOnlySpan<byte> run, Track track, long continueAt, long baseOffset, uint defaultDuration, uint defaultSize, uint defaultFlags, long fileLength)
    {
        var flags = BinaryPrimitives.ReadUInt32BigEndian(run) & 0xFFFFFF;
        var version = run[0];
        var count = (int)BinaryPrimitives.ReadUInt32BigEndian(run[4..]);
        var cursor = 8;
        var start = continueAt;
        if ((flags & 0x1) != 0)
        {
            start = baseOffset + BinaryPrimitives.ReadInt32BigEndian(run[cursor..]);
            cursor += 4;
        }

        uint? firstFlags = null;
        if ((flags & 0x4) != 0)
        {
            firstFlags = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
            cursor += 4;
        }

        var durations = new uint[count];
        var sizes = new uint[count];
        var offsets = new int[count];
        var sync = new bool[count];
        var bytes = 0L;
        for (var index = 0; index < count; index++)
        {
            var duration = defaultDuration;
            var size = defaultSize;
            var sampleFlags = index == 0 && firstFlags is { } firstSample ? firstSample : defaultFlags;
            if ((flags & 0x100) != 0)
            {
                duration = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            if ((flags & 0x200) != 0)
            {
                size = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            if ((flags & 0x400) != 0)
            {
                sampleFlags = BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            if ((flags & 0x800) != 0)
            {
                offsets[index] = version == 0
                    ? checked((int)BinaryPrimitives.ReadUInt32BigEndian(run[cursor..]))
                    : BinaryPrimitives.ReadInt32BigEndian(run[cursor..]);
                cursor += 4;
            }

            durations[index] = duration;
            sizes[index] = size;
            sync[index] = (sampleFlags & NonSyncSampleFlag) == 0;
            bytes += size;
        }

        // The data of a run cut by a crash is not all there; that run and anything after it are left out.
        if (start < 0 || start + bytes > fileLength)
        {
            return start + bytes;
        }

        for (var index = 0; index < count; index++)
        {
            if (sync[index])
            {
                track.SyncSamples.Add(track.Sizes.Count + 1);
            }

            track.Durations.Add(durations[index]);
            track.Sizes.Add(sizes[index]);
            track.CompositionOffsets.Add(offsets[index]);
        }

        if (count > 0)
        {
            track.Chunks.Add((start, bytes, count));
        }

        return start + bytes;
    }

    // MARK: Writing

    private static void Write(Movie movie, FileStream source, FileStream output)
    {
        // Chunks keep their order in the file, so the copy reads the source front to back.
        var chunks = movie.Tracks
            .SelectMany(track => track.Chunks.Select((chunk, index) => (Track: track, Index: index, chunk.Offset, chunk.Bytes)))
            .OrderBy(chunk => chunk.Offset)
            .ToList();
        var dataBytes = chunks.Sum(chunk => chunk.Bytes);
        var ftyp = FileType(movie.Tracks.Any(track => track.IsVideo));
        var large = dataBytes + 16 > uint.MaxValue;
        var mdatHeader = large ? 16 : 8;
        // The sample tables have the same size whatever the offsets are, so measure once, then write with the real offsets.
        var useLargeOffsets = ftyp.Length + 1024L * 1024 + dataBytes > uint.MaxValue;
        var sized = MovieBox(movie, new Dictionary<Track, long[]>(), useLargeOffsets);
        var dataStart = ftyp.Length + sized.Length + mdatHeader;
        var chunkOffsets = movie.Tracks.ToDictionary(track => track, track => new long[track.Chunks.Count]);
        var at = (long)dataStart;
        foreach (var chunk in chunks)
        {
            chunkOffsets[chunk.Track][chunk.Index] = at;
            at += chunk.Bytes;
        }

        var moov = MovieBox(movie, chunkOffsets, useLargeOffsets);
        if (moov.Length != sized.Length)
        {
            throw new InvalidDataException("moov size changed");
        }

        output.Write(ftyp);
        output.Write(moov);
        var header = new byte[mdatHeader];
        if (large)
        {
            BinaryPrimitives.WriteUInt32BigEndian(header, 1);
            Encoding.ASCII.GetBytes("mdat", header.AsSpan(4));
            BinaryPrimitives.WriteInt64BigEndian(header.AsSpan(8), dataBytes + 16);
        }
        else
        {
            BinaryPrimitives.WriteUInt32BigEndian(header, (uint)(dataBytes + 8));
            Encoding.ASCII.GetBytes("mdat", header.AsSpan(4));
        }

        output.Write(header);
        var buffer = new byte[CopyBufferBytes];
        foreach (var chunk in chunks)
        {
            source.Position = chunk.Offset;
            var left = chunk.Bytes;
            while (left > 0)
            {
                var read = source.Read(buffer, 0, (int)Math.Min(buffer.Length, left));
                if (read <= 0)
                {
                    throw new EndOfStreamException();
                }

                output.Write(buffer, 0, read);
                left -= read;
            }
        }
    }

    private static byte[] FileType(bool video)
    {
        var brands = video ? new[] { "isom", "iso2", "avc1", "mp41" } : new[] { "M4A ", "isom", "iso2", "mp41" };
        var body = new byte[8 + brands.Length * 4];
        Encoding.ASCII.GetBytes(video ? "isom" : "M4A ", body);
        BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(4), 512);
        for (var index = 0; index < brands.Length; index++)
        {
            Encoding.ASCII.GetBytes(brands[index], body.AsSpan(8 + index * 4));
        }

        return Box("ftyp", body);
    }

    private static byte[] MovieBox(Movie movie, Dictionary<Track, long[]> chunkOffsets, bool largeOffsets)
    {
        var children = new List<byte[]>();
        var longest = 0UL;
        var tracks = new List<byte[]>();
        foreach (var track in movie.Tracks)
        {
            var mediaDuration = track.Durations.Aggregate(0UL, (sum, duration) => sum + duration);
            var movieDuration = track.Timescale == 0 ? 0 : (ulong)Math.Round(mediaDuration * (double)movie.MovieTimescale / track.Timescale);
            longest = Math.Max(longest, movieDuration);
            var offsets = chunkOffsets.TryGetValue(track, out var known) ? known : new long[track.Chunks.Count];
            tracks.Add(TrackBox(track, mediaDuration, movieDuration, offsets, largeOffsets));
        }

        foreach (var (type, offset, length) in Boxes(movie.Moov))
        {
            switch (type)
            {
                case "mvhd":
                    children.Add(Box("mvhd", WithDuration(movie.Moov.AsSpan(offset, length), longest, timescaleField: true)));
                    children.AddRange(tracks);
                    break;
                case "trak" or "mvex":
                    break;
                default:
                    children.Add(movie.Moov.AsSpan(offset - 8, length + 8).ToArray());
                    break;
            }
        }

        return Box("moov", Concat(children));
    }

    private static byte[] TrackBox(Track track, ulong mediaDuration, ulong movieDuration, long[] chunkOffsets, bool largeOffsets)
    {
        var children = new List<byte[]>();
        var firstPresentation = track.CompositionOffsets.Count > 0 ? track.CompositionOffsets.Min() : 0;
        foreach (var (type, offset, length) in Boxes(track.Trak))
        {
            var body = track.Trak.AsSpan(offset, length);
            switch (type)
            {
                case "tkhd":
                    children.Add(Box("tkhd", WithDuration(body, movieDuration, timescaleField: false)));
                    if (firstPresentation != 0)
                    {
                        // The first frame shows at its composition time; the edit list starts the track there, as encoders do.
                        children.Add(EditList(movieDuration, firstPresentation));
                    }

                    break;
                case "edts":
                    break;
                case "mdia":
                    children.Add(Box("mdia", MediaBox(body.ToArray(), track, mediaDuration, chunkOffsets, largeOffsets)));
                    break;
                default:
                    children.Add(track.Trak.AsSpan(offset - 8, length + 8).ToArray());
                    break;
            }
        }

        return Box("trak", Concat(children));
    }

    private static byte[] MediaBox(byte[] mdia, Track track, ulong mediaDuration, long[] chunkOffsets, bool largeOffsets)
    {
        var children = new List<byte[]>();
        foreach (var (type, offset, length) in Boxes(mdia))
        {
            var body = mdia.AsSpan(offset, length);
            children.Add(type switch
            {
                "mdhd" => Box("mdhd", WithDuration(body, mediaDuration, timescaleField: true)),
                "minf" => Box("minf", Rebuild(body.ToArray(), "stbl", stbl => SampleTable(stbl, track, chunkOffsets, largeOffsets))),
                _ => mdia.AsSpan(offset - 8, length + 8).ToArray()
            });
        }

        return Concat(children);
    }

    private static byte[] SampleTable(byte[] stbl, Track track, long[] chunkOffsets, bool largeOffsets)
    {
        var stsd = Boxes(stbl).Where(box => box.Type == "stsd").Select(box => stbl.AsSpan(box.Offset - 8, box.Length + 8).ToArray()).FirstOrDefault()
            ?? throw new InvalidDataException("no stsd");
        var children = new List<byte[]> { stsd, TimeToSample(track.Durations) };
        if (track.CompositionOffsets.Any(offset => offset != 0))
        {
            children.Add(CompositionOffsets(track.CompositionOffsets));
        }

        if (track.SyncSamples.Count < track.Sizes.Count)
        {
            children.Add(FullBox("stss", 0, track.SyncSamples.Count, track.SyncSamples.Select(index => (long)index), 4));
        }

        children.Add(SampleSizes(track.Sizes));
        children.Add(SampleToChunk(track.Chunks));
        children.Add(largeOffsets
            ? FullBox("co64", 0, chunkOffsets.Length, chunkOffsets, 8)
            : FullBox("stco", 0, chunkOffsets.Length, chunkOffsets.Select(offset => checked((long)(uint)offset)), 4));
        return Concat(children);
    }

    private static byte[] TimeToSample(List<uint> durations)
    {
        var runs = new List<long>();
        for (var index = 0; index < durations.Count;)
        {
            var end = index;
            while (end < durations.Count && durations[end] == durations[index])
            {
                end++;
            }

            runs.Add(end - index);
            runs.Add(durations[index]);
            index = end;
        }

        return FullBox("stts", 0, runs.Count / 2, runs, 4);
    }

    private static byte[] CompositionOffsets(List<int> offsets)
    {
        var runs = new List<long>();
        for (var index = 0; index < offsets.Count;)
        {
            var end = index;
            while (end < offsets.Count && offsets[end] == offsets[index])
            {
                end++;
            }

            runs.Add(end - index);
            runs.Add(unchecked((uint)offsets[index]));
            index = end;
        }

        // Version 1: signed offsets.
        return FullBox("ctts", 1, runs.Count / 2, runs, 4);
    }

    private static byte[] SampleSizes(List<uint> sizes)
    {
        var body = new byte[12 + sizes.Count * 4];
        BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(8), (uint)sizes.Count);
        for (var index = 0; index < sizes.Count; index++)
        {
            BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(12 + index * 4), sizes[index]);
        }

        return Box("stsz", body);
    }

    private static byte[] SampleToChunk(List<(long Offset, long Bytes, int Samples)> chunks)
    {
        var entries = new List<long>();
        for (var index = 0; index < chunks.Count; index++)
        {
            if (index == 0 || chunks[index].Samples != chunks[index - 1].Samples)
            {
                entries.Add(index + 1);
                entries.Add(chunks[index].Samples);
                entries.Add(1);
            }
        }

        return FullBox("stsc", 0, entries.Count / 3, entries, 4);
    }

    private static byte[] EditList(ulong movieDuration, int mediaTime)
    {
        var body = new byte[8 + 20];
        body[0] = 1;
        BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt64BigEndian(body.AsSpan(8), movieDuration);
        BinaryPrimitives.WriteInt64BigEndian(body.AsSpan(16), mediaTime);
        BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(24), 0x00010000);
        return Box("edts", Box("elst", body));
    }

    /// <summary>mvhd, tkhd or mdhd as version 1 with a new duration; MF's 100 ns timescales overflow version 0 within minutes.</summary>
    private static byte[] WithDuration(ReadOnlySpan<byte> body, ulong duration, bool timescaleField)
    {
        // Version 0: created 4, modified 4, then (timescale 4 | track id 4, reserved 4), duration 4. Version 1 widens the times.
        var version = body[0];
        var times = version == 1 ? 16 : 8;
        var middle = timescaleField ? 4 : 8;
        var durationSize = version == 1 ? 8 : 4;
        var rest = body[(4 + times + middle + durationSize)..];
        var result = new byte[4 + 16 + middle + 8 + rest.Length];
        result[0] = 1;
        body.Slice(1, 3).CopyTo(result.AsSpan(1));
        if (version == 1)
        {
            body.Slice(4, 16).CopyTo(result.AsSpan(4));
        }
        else
        {
            BinaryPrimitives.WriteUInt64BigEndian(result.AsSpan(4), BinaryPrimitives.ReadUInt32BigEndian(body[4..]));
            BinaryPrimitives.WriteUInt64BigEndian(result.AsSpan(12), BinaryPrimitives.ReadUInt32BigEndian(body[8..]));
        }

        body.Slice(4 + times, middle).CopyTo(result.AsSpan(20));
        BinaryPrimitives.WriteUInt64BigEndian(result.AsSpan(20 + middle), duration);
        rest.CopyTo(result.AsSpan(28 + middle));
        return result;
    }

    // MARK: Boxes

    private static byte[] Rebuild(byte[] container, string type, Func<byte[], byte[]> body)
    {
        var children = new List<byte[]>();
        foreach (var (childType, offset, length) in Boxes(container))
        {
            children.Add(childType == type
                ? Box(type, body(container.AsSpan(offset, length).ToArray()))
                : container.AsSpan(offset - 8, length + 8).ToArray());
        }

        return Concat(children);
    }

    private static byte[] FullBox(string type, byte version, int count, IEnumerable<long> values, int width)
    {
        var list = values as IList<long> ?? values.ToList();
        var body = new byte[8 + list.Count * width];
        body[0] = version;
        BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(4), (uint)count);
        for (var index = 0; index < list.Count; index++)
        {
            if (width == 8)
            {
                BinaryPrimitives.WriteInt64BigEndian(body.AsSpan(8 + index * 8), list[index]);
            }
            else
            {
                BinaryPrimitives.WriteUInt32BigEndian(body.AsSpan(8 + index * 4), checked((uint)list[index]));
            }
        }

        return Box(type, body);
    }

    private static byte[] Box(string type, byte[] body)
    {
        var box = new byte[8 + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(box, checked((uint)box.Length));
        Encoding.ASCII.GetBytes(type, box.AsSpan(4));
        body.CopyTo(box.AsSpan(8));
        return box;
    }

    private static byte[] Concat(List<byte[]> parts)
    {
        var result = new byte[parts.Sum(part => part.Length)];
        var at = 0;
        foreach (var part in parts)
        {
            part.CopyTo(result.AsSpan(at));
            at += part.Length;
        }

        return result;
    }

    private static byte[]? Child(byte[] container, string type)
    {
        foreach (var (childType, offset, length) in Boxes(container))
        {
            if (childType == type)
            {
                return container.AsSpan(offset, length).ToArray();
            }
        }

        return null;
    }

    /// <summary>Child boxes as (type, body offset, body length). Stops at a box that does not fit.</summary>
    private static List<(string Type, int Offset, int Length)> Boxes(ReadOnlySpan<byte> data)
    {
        var results = new List<(string, int, int)>();
        var position = 0;
        while (position + 8 <= data.Length)
        {
            var size = (int)BinaryPrimitives.ReadUInt32BigEndian(data[position..]);
            if (size < 8 || position + size > data.Length)
            {
                break;
            }

            results.Add((Encoding.ASCII.GetString(data.Slice(position + 4, 4)), position + 8, size - 8));
            position += size;
        }

        return results;
    }
}
