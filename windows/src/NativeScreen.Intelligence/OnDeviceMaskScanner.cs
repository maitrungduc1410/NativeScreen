using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.RegularExpressions;
using NativeScreen.Core;
using NativeScreen.Media;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using Windows.Media.Ocr;

namespace NativeScreen.Intelligence;

/// <summary>Finds sensitive text and faces on sampled frames with the OS engines, on device. Nothing leaves the machine.</summary>
public static class OnDeviceMaskScanner
{
    /// <summary>Null when Windows has no OCR language installed.</summary>
    public static async Task<List<MaskItem>?> DetectSensitiveAsync(string videoPath, double durationMs, IReadOnlyList<string> customPhrases, IProgress<double>? progress, CancellationToken cancel)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null)
        {
            return null;
        }

        var phrases = customPhrases.Select(phrase => phrase.Trim().ToLowerInvariant()).Where(phrase => phrase.Length > 0).ToList();
        var total = Math.Max(1000, durationMs);
        var step = AutoMaskBuilder.SensitiveStepMs(durationMs);
        var times = AutoMaskBuilder.SensitiveSampleTimes(durationMs);
        var masks = new List<MaskItem>();
        using var reader = new VideoFileReader(videoPath);
        for (var index = 0; index < times.Count; index++)
        {
            cancel.ThrowIfCancellationRequested();
            if (await Task.Run(() => MediaAssets.FrameAt(reader, times[index]), cancel) is { } frame)
            {
                foreach (var rect in await RecognizeAsync(engine, frame, phrases))
                {
                    AutoMaskBuilder.AddSensitiveHit(masks, times[index], step, total, rect);
                }
            }

            progress?.Report((index + 1.0) / times.Count);
        }

        return masks;
    }

    public static async Task<List<MaskItem>> DetectFacesAsync(string videoPath, double durationMs, IProgress<double>? progress, CancellationToken cancel)
    {
        var total = Math.Max(1000, durationMs);
        var step = AutoMaskBuilder.FaceStepMs(durationMs);
        var times = AutoMaskBuilder.FaceSampleTimes(durationMs);
        var masks = new List<MaskItem>();
        var detector = await FaceDetector.CreateAsync();
        using var reader = new VideoFileReader(videoPath);
        for (var index = 0; index < times.Count; index++)
        {
            cancel.ThrowIfCancellationRequested();
            if (await Task.Run(() => MediaAssets.FrameAt(reader, times[index]), cancel) is { } frame)
            {
                using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(frame.Nv12.AsBuffer(), BitmapPixelFormat.Nv12, frame.Width, frame.Height);
                foreach (var face in await detector.DetectFacesAsync(bitmap))
                {
                    var box = face.FaceBox;
                    var rect = AutoMaskBuilder.PadFace((double)box.X / frame.Width, (double)box.Y / frame.Height, (double)box.Width / frame.Width, (double)box.Height / frame.Height);
                    AutoMaskBuilder.AddFaceHit(masks, times[index], step, total, rect);
                }
            }

            progress?.Report((index + 1.0) / times.Count);
        }

        return masks;
    }

    private static async Task<List<Rect01>> RecognizeAsync(OcrEngine engine, VideoFrame frame, List<string> phrases)
    {
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(MediaAssets.ToBgra(frame).AsBuffer(), BitmapPixelFormat.Bgra8, frame.Width, frame.Height, BitmapAlphaMode.Ignore);
        var result = await engine.RecognizeAsync(bitmap);
        var hits = new List<Rect01>();
        foreach (var line in result.Lines)
        {
            // OCR returns boxes per word, so a match in the line text maps back through each word's offset.
            var text = new StringBuilder();
            var words = new List<(int Start, int End, Windows.Foundation.Rect Box)>();
            foreach (var word in line.Words)
            {
                if (text.Length > 0)
                {
                    text.Append(' ');
                }

                words.Add((text.Length, text.Length + word.Text.Length, word.BoundingRect));
                text.Append(word.Text);
            }

            var raw = text.ToString();
            var lower = raw.ToLowerInvariant();
            var ranges = new List<(int Start, int End)>();
            foreach (var phrase in phrases)
            {
                for (var at = lower.IndexOf(phrase, StringComparison.Ordinal); at >= 0; at = lower.IndexOf(phrase, at + phrase.Length, StringComparison.Ordinal))
                {
                    ranges.Add((at, at + phrase.Length));
                }
            }

            foreach (var pattern in AutoMaskBuilder.SensitivePatterns)
            {
                foreach (Match match in Regex.Matches(raw, pattern, RegexOptions.IgnoreCase))
                {
                    ranges.Add((match.Index, match.Index + match.Length));
                }
            }

            foreach (var (start, end) in ranges)
            {
                var covered = words.Where(word => word.Start < end && word.End > start).Select(word => word.Box).ToList();
                if (covered.Count == 0)
                {
                    continue;
                }

                var left = covered.Min(box => box.X);
                var top = covered.Min(box => box.Y);
                var right = covered.Max(box => box.X + box.Width);
                var bottom = covered.Max(box => box.Y + box.Height);
                if (AutoMaskBuilder.PadSensitive(left / frame.Width, top / frame.Height, (right - left) / frame.Width, (bottom - top) / frame.Height) is { } rect)
                {
                    hits.Add(rect);
                }
            }
        }

        return hits;
    }
}
