using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using NativeScreen.Core;
using NativeScreen.Media;

namespace NativeScreen.Intelligence;

/// <summary>Finds the largest face and its landmarks in the webcam video once, on device (spec/06 ADR-58, ADR-60).</summary>
public static class FaceTrackScanner
{
    /// <summary>Scanning every other frame and interpolating is smooth enough and halves the time.</summary>
    private const int FrameStep = 2;

    /// <summary>Null if the model cannot run. Throws when cancelled.</summary>
    public static StoredFaceTrack? Scan(string webcamPath, IProgress<double>? progress, CancellationToken cancel)
    {
        if (!FaceLandmarkDetector.IsAvailable)
        {
            return null;
        }

        using var detector = new FaceLandmarkDetector();
        using var reader = new VideoFileReader(webcamPath);
        var durationMs = Math.Max(1, reader.DurationMs);
        var pool = new VideoFramePool();
        var samples = new List<double[]>();
        var index = 0;
        while (reader.ReadNext(pool) is { } frame)
        {
            cancel.ThrowIfCancellationRequested();
            if (index % FrameStep == 0 && detector.Detect(frame) is { } sample)
            {
                samples.Add(sample);
            }

            if (index % 30 == 0)
            {
                progress?.Report(Math.Min(1, frame.PresentationMs / durationMs));
            }

            pool.Return(frame.Nv12);
            index++;
        }

        return new StoredFaceTrack { WebcamDurationMs = durationMs, Samples = samples };
    }
}

/// <summary>YuNet: one small network gives the box and five landmarks of every face. Runs on the CPU, so a scan stays off the GPU the preview is using.</summary>
internal sealed class FaceLandmarkDetector : IDisposable
{
    private const int InputSize = 640;
    private const float ScoreThreshold = 0.6f;
    private const double OverlapLimit = 0.3;
    private static readonly int[] Strides = [8, 16, 32];
    private static readonly string[] OutputNames = ["cls_8", "cls_16", "cls_32", "obj_8", "obj_16", "obj_32", "bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"];
    private static readonly string ModelPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Models", "face_detection_yunet_2023mar.onnx");

    private readonly InferenceSession session = OnnxSessions.Cpu(ModelPath);
    private readonly DenseTensor<float> input = new([1, 3, InputSize, InputSize]);
    private readonly string inputName;

    public FaceLandmarkDetector() => inputName = session.InputMetadata.Keys.First();

    public static bool IsAvailable => File.Exists(ModelPath);

    public void Dispose() => session.Dispose();

    /// <summary>A sample in the face-track.json layout for the largest face, or null when there is none.</summary>
    public double[]? Detect(VideoFrame frame)
    {
        // The model takes a fixed square, so the frame is fitted to the top-left and the rest stays black.
        var shrink = (double)InputSize / Math.Max(frame.Width, frame.Height);
        var drawnWidth = Math.Min(InputSize, (int)Math.Round(frame.Width * shrink));
        var drawnHeight = Math.Min(InputSize, (int)Math.Round(frame.Height * shrink));
        FillInput(frame, drawnWidth, drawnHeight);
        using var results = session.Run([NamedOnnxValue.CreateFromTensor(inputName, input)]);
        var byName = results.ToDictionary(result => result.Name, result => result.AsTensor<float>());
        var candidates = new List<Candidate>();
        for (var level = 0; level < Strides.Length; level++)
        {
            Decode(byName, level, candidates);
        }

        var best = LargestAfterSuppression(candidates);
        if (best is null)
        {
            return null;
        }

        double X(float value) => Math.Round(value / drawnWidth * 10000) / 10000;
        double Y(float value) => Math.Round(value / drawnHeight * 10000) / 10000;
        var k = best.Landmarks;
        // Landmarks: right eye, left eye, nose tip, right mouth corner, left mouth corner.
        return
        [
            Math.Round(frame.PresentationMs * 10) / 10,
            X(best.Left), Y(best.Top), X(best.Width), Y(best.Height),
            X(k[0]), Y(k[1]), X(k[2]), Y(k[3]), X(k[4]), Y(k[5]),
            X((k[6] + k[8]) * 0.5f), Y((k[7] + k[9]) * 0.5f)
        ];
    }

    private void FillInput(VideoFrame frame, int drawnWidth, int drawnHeight)
    {
        var span = input.Buffer.Span;
        span.Clear();
        var luma = frame.Nv12;
        var chromaStart = frame.Width * frame.Height;
        for (var y = 0; y < drawnHeight; y++)
        {
            var sourceY = Math.Min(frame.Height - 1, y * frame.Height / drawnHeight);
            for (var x = 0; x < drawnWidth; x++)
            {
                var sourceX = Math.Min(frame.Width - 1, x * frame.Width / drawnWidth);
                var chroma = chromaStart + (sourceY / 2) * frame.Width + (sourceX & ~1);
                var (r, g, b) = Nv12Pixel.Rgb(luma[sourceY * frame.Width + sourceX], luma[chroma], luma[chroma + 1]);
                var at = y * InputSize + x;
                // BGR, 0 to 255.
                span[at] = b * 255;
                span[InputSize * InputSize + at] = g * 255;
                span[InputSize * InputSize * 2 + at] = r * 255;
            }
        }
    }

    private static void Decode(Dictionary<string, Tensor<float>> outputs, int level, List<Candidate> candidates)
    {
        var stride = Strides[level];
        var cells = InputSize / stride;
        var cls = outputs[OutputNames[level]];
        var obj = outputs[OutputNames[level + 3]];
        var box = outputs[OutputNames[level + 6]];
        var kps = outputs[OutputNames[level + 9]];
        for (var row = 0; row < cells; row++)
        {
            for (var col = 0; col < cells; col++)
            {
                var index = row * cells + col;
                var score = MathF.Sqrt(Math.Clamp(cls.GetValue(index), 0, 1) * Math.Clamp(obj.GetValue(index), 0, 1));
                if (score < ScoreThreshold)
                {
                    continue;
                }

                var centerX = (col + box.GetValue(index * 4)) * stride;
                var centerY = (row + box.GetValue(index * 4 + 1)) * stride;
                var width = MathF.Exp(box.GetValue(index * 4 + 2)) * stride;
                var height = MathF.Exp(box.GetValue(index * 4 + 3)) * stride;
                var landmarks = new float[10];
                for (var n = 0; n < 5; n++)
                {
                    landmarks[n * 2] = (kps.GetValue(index * 10 + n * 2) + col) * stride;
                    landmarks[n * 2 + 1] = (kps.GetValue(index * 10 + n * 2 + 1) + row) * stride;
                }

                candidates.Add(new Candidate(centerX - width / 2, centerY - height / 2, width, height, score, landmarks));
            }
        }
    }

    private static Candidate? LargestAfterSuppression(List<Candidate> candidates)
    {
        candidates.Sort((a, b) => b.Score.CompareTo(a.Score));
        var kept = new List<Candidate>();
        foreach (var candidate in candidates)
        {
            if (kept.TrueForAll(other => Overlap(candidate, other) <= OverlapLimit))
            {
                kept.Add(candidate);
            }
        }

        return kept.Count == 0 ? null : kept.MaxBy(item => item.Width * item.Height);
    }

    private static double Overlap(Candidate a, Candidate b)
    {
        var width = Math.Min(a.Left + a.Width, b.Left + b.Width) - Math.Max(a.Left, b.Left);
        var height = Math.Min(a.Top + a.Height, b.Top + b.Height) - Math.Max(a.Top, b.Top);
        if (width <= 0 || height <= 0)
        {
            return 0;
        }

        var shared = width * height;
        return shared / (a.Width * a.Height + b.Width * b.Height - shared);
    }

    private sealed record Candidate(float Left, float Top, float Width, float Height, float Score, float[] Landmarks);
}

/// <summary>The same BT.709 limited-range conversion as the preview's NV12 shader.</summary>
internal static class Nv12Pixel
{
    public static (float R, float G, float B) Rgb(byte luma, byte cb, byte cr)
    {
        var y = (luma - 16) * 1.164384f;
        var u = cb - 128f;
        var v = cr - 128f;
        return (
            Math.Clamp((y + 1.792741f * v) / 255f, 0, 1),
            Math.Clamp((y - 0.213249f * u - 0.532909f * v) / 255f, 0, 1),
            Math.Clamp((y + 2.112402f * u) / 255f, 0, 1));
    }
}
