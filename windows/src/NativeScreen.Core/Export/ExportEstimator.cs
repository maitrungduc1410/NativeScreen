using System.Globalization;

namespace NativeScreen.Core;

public sealed class ExportSettings
{
    public ExportFormat Format { get; set; } = ExportFormat.Mp4;
    public int Fps { get; set; } = 60;
    public int ResolutionHeight { get; set; } = 2160;
    public ExportCompression Compression { get; set; } = ExportCompression.Studio;
    public Mp4CodecOption Mp4Codec { get; set; } = Mp4CodecOption.H264;
    public ProResProfileOption ProResProfile { get; set; } = ProResProfileOption.Hq422;
    public bool GifHighQuality { get; set; }
    public bool GifDisableLoop { get; set; }

    public void Normalize()
    {
        var allowed = AllowedFps(Format);
        if (!allowed.Contains(Fps))
        {
            Fps = allowed.FirstOrDefault(fps => fps <= Fps);
            if (Fps == 0)
            {
                Fps = allowed.Count == 0 ? 30 : allowed[0];
            }
        }

        var enabled = EnabledHeights();
        if (!enabled.Contains(ResolutionHeight))
        {
            var lower = enabled.OrderByDescending(height => height).FirstOrDefault(height => height <= ResolutionHeight);
            ResolutionHeight = lower != 0 ? lower : enabled.Count == 0 ? 1080 : enabled[0];
        }
    }

    public (int Width, int Height) OutputSize(double aspect)
    {
        var safe = Math.Max(0.2, aspect);
        var height = Math.Max(2, ResolutionHeight & ~1);
        var width = Math.Max(2, (int)Math.Round(height * safe, MidpointRounding.AwayFromZero) & ~1);
        return (width, height);
    }

    public List<int> EnabledHeights()
    {
        var all = Heights(Format);
        if (Format == ExportFormat.Mp4 && (Compression == ExportCompression.Web || Compression == ExportCompression.WebLow))
        {
            return all.Where(height => height <= 1080).ToList();
        }

        return all;
    }

    public static List<int> AllowedFps(ExportFormat format) => format == ExportFormat.Gif
        ? [50, 30, 25, 20, 15, 10]
        : [60, 50, 30, 25, 24, 20, 10];

    public static List<int> Heights(ExportFormat format) => format == ExportFormat.Gif
        ? [480, 720, 1080]
        : [720, 1080, 2160];
}

public sealed class ExportEstimate
{
    public string Format { get; init; } = "";
    public int Fps { get; init; }
    public int Height { get; init; }
    public string Compression { get; init; } = "";
    public string Codec { get; init; } = "";
    public string Size { get; init; } = "";
    public string Duration { get; init; } = "";
    public int VideoBitrate { get; init; }
}

public static class ExportEstimator
{
    public static int TargetMp4Bitrate(ExportCompression compression, Mp4CodecOption codec, int width, int height, int fps)
    {
        const double refPixels = 1920.0 * 1080.0;
        var bpp = compression switch
        {
            ExportCompression.SocialMedia => 0.0221,
            ExportCompression.Web => 0.0110,
            ExportCompression.WebLow => 0.0038,
            _ => 0.0816
        };
        var pixelScale = Math.Pow(Math.Max(1, (double)width * height) / refPixels, 0.78);
        var fpsScale = Math.Pow(Math.Max(1, fps) / 60.0, 0.57);
        var codecFactor = codec == Mp4CodecOption.H265 ? 0.72 : 1.0;
        return Math.Max(600_000, (int)Math.Round(bpp * refPixels * 60.0 * pixelScale * fpsScale * codecFactor, MidpointRounding.AwayFromZero));
    }

    public static string SizeString(ExportSettings config, double aspect, double durationMs, bool hasAudio = false)
    {
        var (width, height) = config.OutputSize(aspect);
        var seconds = Math.Max(0.5, durationMs / 1000.0);
        if (config.Format == ExportFormat.Mp4)
        {
            var bitrate = TargetMp4Bitrate(config.Compression, config.Mp4Codec == Mp4CodecOption.Both ? Mp4CodecOption.H264 : config.Mp4Codec, width, height, config.Fps);
            var bytes = ((bitrate + (hasAudio ? 165_000.0 : 0)) / 8.0) * seconds;
            return FormatRange(bytes * 0.65, bytes * 1.50);
        }

        if (config.Format == ExportFormat.ProRes)
        {
            var reference = config.ProResProfile switch
            {
                ProResProfileOption.Lt422 => 102_000_000.0,
                ProResProfileOption.Standard422 => 147_000_000.0,
                ProResProfileOption.P4444 => 330_000_000.0,
                _ => 220_000_000.0
            };
            var bps = reference * ((double)width * height / (1920.0 * 1080.0)) * (config.Fps / 30.0);
            var bytes = ((bps + (hasAudio ? 48_000.0 * 24 * 2 : 0)) / 8.0) * seconds;
            return FormatRange(bytes * 0.80, bytes * 1.10);
        }

        var quality = config.GifHighQuality ? 1.8 : 1.0;
        var perFrame = 75_000.0 * Math.Pow((double)width * height / (1920.0 * 1080.0), 0.80) * quality;
        var typical = perFrame * seconds * config.Fps;
        return FormatRange(typical * 0.35, typical * 1.60);
    }

    public static string DurationString(ExportSettings config, double aspect, double durationMs)
    {
        var (width, height) = config.OutputSize(aspect);
        var seconds = Math.Max(0.5, durationMs / 1000.0);
        var frames = seconds * config.Fps;
        var ratio = Math.Clamp((double)width * height / (3840.0 * 2160.0), 0, 1);
        var encoding = 60.0 - 28.5 * ratio;
        var estimate = Math.Max(1, (int)Math.Round(frames / encoding, MidpointRounding.AwayFromZero));
        if (config.Format == ExportFormat.Gif)
        {
            estimate = Math.Max(1, (int)Math.Round(estimate * 1.2, MidpointRounding.AwayFromZero));
        }

        if (estimate < 60)
        {
            return estimate == 1 ? "1 second" : $"{estimate} seconds";
        }

        var minutes = (int)Math.Round(estimate / 60.0, MidpointRounding.AwayFromZero);
        return minutes == 1 ? "1 minute" : $"{minutes} minutes";
    }

    public static List<ExportEstimate> Rows(ProjectDocument document, int sourceWidth, int sourceHeight, double durationMs)
    {
        var aspect = document.Canvas.EffectiveAspectRatio(sourceWidth, sourceHeight);
        var rows = new List<ExportEstimate>();
        foreach (var format in new[] { ExportFormat.Mp4, ExportFormat.ProRes, ExportFormat.Gif })
        {
            foreach (var fps in ExportSettings.AllowedFps(format))
            {
                foreach (var height in ExportSettings.Heights(format))
                {
                    var config = new ExportSettings { Format = format, Fps = fps, ResolutionHeight = height };
                    config.Normalize();
                    if (format == ExportFormat.Mp4)
                    {
                        foreach (var compression in new[] { ExportCompression.Studio, ExportCompression.SocialMedia, ExportCompression.Web, ExportCompression.WebLow })
                        {
                            var row = new ExportSettings
                            {
                                Format = format,
                                Fps = config.Fps,
                                ResolutionHeight = config.ResolutionHeight,
                                Compression = compression,
                                Mp4Codec = Mp4CodecOption.H264
                            };
                            row.Normalize();
                            if (row.ResolutionHeight != height || row.Fps != fps)
                            {
                                continue;
                            }

                            var size = row.OutputSize(aspect);
                            rows.Add(new ExportEstimate
                            {
                                Format = "mp4",
                                Fps = fps,
                                Height = height,
                                Compression = Name(compression),
                                Codec = "h264",
                                Size = SizeString(row, aspect, durationMs),
                                Duration = DurationString(row, aspect, durationMs),
                                VideoBitrate = TargetMp4Bitrate(compression, Mp4CodecOption.H264, size.Width, size.Height, fps)
                            });
                        }
                    }
                    else
                    {
                        if (config.ResolutionHeight != height || config.Fps != fps)
                        {
                            continue;
                        }

                        rows.Add(new ExportEstimate
                        {
                            Format = format == ExportFormat.Gif ? "gif" : "prores",
                            Fps = fps,
                            Height = height,
                            Compression = format == ExportFormat.Gif ? "standard" : "422-hq",
                            Codec = format == ExportFormat.Gif ? "gif" : "prores",
                            Size = SizeString(config, aspect, durationMs),
                            Duration = DurationString(config, aspect, durationMs),
                            VideoBitrate = 0
                        });
                    }
                }
            }
        }

        return rows;
    }

    public static string FormatRange(double lowBytes, double highBytes)
    {
        var low = Unit(lowBytes);
        var high = Unit(highBytes);
        if (low.Unit == high.Unit)
        {
            return low.Amount == high.Amount ? $"{high.Amount}{high.Unit}" : $"{low.Amount}\u2013{high.Amount}{high.Unit}";
        }

        return $"{low.Amount}{low.Unit}\u2013{high.Amount}{high.Unit}";
    }

    private static (string Amount, string Unit) Unit(double bytes)
    {
        var kb = bytes / 1000.0;
        if (kb < 100)
        {
            return ($"{Math.Max(1, (int)Math.Round(kb, MidpointRounding.AwayFromZero))}", "KB");
        }

        if (kb < 995)
        {
            return ($"{(int)Math.Round(kb / 10.0, MidpointRounding.AwayFromZero) * 10}", "KB");
        }

        var mb = bytes / 1_000_000.0;
        if (mb < 25)
        {
            return (OneDecimal(mb), "MB");
        }

        var step = mb < 100 ? 5.0 : 10.0;
        var stepped = (int)Math.Round(mb / step, MidpointRounding.AwayFromZero) * step;
        if (stepped < 1000)
        {
            return ($"{stepped}", "MB");
        }

        return (OneDecimal(mb / 1000.0), "GB");
    }

    /// <summary>
    /// Matches Darwin <c>printf("%.1f")</c>. Multiplying by ten first turns values such as
    /// 3.1499999999999999 into an exact midpoint, which then prints 3.2 instead of 3.1.
    /// </summary>
    private static string OneDecimal(double value)
    {
        var negative = value < 0;
        var text = Math.Abs(value).ToString("G17", CultureInfo.InvariantCulture);
        var dot = text.IndexOf('.');
        var whole = dot < 0 ? text : text[..dot];
        var frac = dot < 0 ? "" : text[(dot + 1)..];
        if (frac.Length == 0)
        {
            return (negative ? "-" : "") + whole + ".0";
        }

        var digit = frac[0] - '0';
        var roundUp = frac.Length > 1 && frac[1] >= '5';
        if (roundUp)
        {
            digit++;
        }

        if (digit == 10)
        {
            whole = (long.Parse(whole, CultureInfo.InvariantCulture) + 1).ToString(CultureInfo.InvariantCulture);
            digit = 0;
        }

        return $"{(negative ? "-" : "")}{whole}.{digit}";
    }

    private static string Name(ExportCompression compression) => compression switch
    {
        ExportCompression.SocialMedia => "social-media",
        ExportCompression.Web => "web-high",
        ExportCompression.WebLow => "web-low",
        _ => "studio"
    };
}
