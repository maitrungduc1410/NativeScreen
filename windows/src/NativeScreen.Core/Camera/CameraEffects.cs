using System.Text.Json;

namespace NativeScreen.Core;

/// <summary>Sticker artwork and how it sits on a face, from <c>stickers.json</c>. Sizes and offsets are in face units (about the distance between the eyes).</summary>
public sealed record CameraSticker(string Id, string Name, string File, string Anchor, double Width, double? Height, double OffsetX, double OffsetY);

public readonly record struct StickerPlacement(FacePoint Center, double Width, double Height, double Angle);

public sealed record CameraBackgroundItem(string Id, string FullImagePath, string ThumbnailPath);

public static class CameraStickerCatalog
{
    private sealed record CatalogFile(List<CameraSticker> Stickers);

    private static readonly Lazy<IReadOnlyList<CameraSticker>> Loaded = new(Load);

    public static string Directory { get; } = Path.Combine(AppContext.BaseDirectory, "Assets", "Stickers");

    public static IReadOnlyList<CameraSticker> All => Loaded.Value;

    public static CameraSticker? Find(string id)
    {
        foreach (var sticker in All)
        {
            if (sticker.Id == id)
            {
                return sticker;
            }
        }

        return null;
    }

    public static string ImagePath(CameraSticker sticker) => Path.Combine(Directory, sticker.File);

    public static IReadOnlyList<CameraSticker> Parse(string json) =>
        JsonSerializer.Deserialize<CatalogFile>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web))?.Stickers ?? [];

    private static IReadOnlyList<CameraSticker> Load()
    {
        var path = Path.Combine(Directory, "stickers.json");
        return System.IO.File.Exists(path) ? Parse(System.IO.File.ReadAllText(path)) : [];
    }
}

public static class CameraBackgroundCatalog
{
    public static IReadOnlyList<CameraBackgroundItem> Items { get; } = Enumerable.Range(1, 9)
        .Select(index =>
        {
            var root = Path.Combine(AppContext.BaseDirectory, "Assets", "CameraBackgrounds");
            return new CameraBackgroundItem($"background-{index}", Path.Combine(root, $"{index}.jpg"), Path.Combine(root, "thumbs", $"{index}.jpg"));
        })
        .ToList();
}

public static class CameraEffects
{
    private const double EyesToMouthRatio = 1.2;

    /// <summary>Places a sticker on a face given in pixels, y down. The face's own axes make it tilt with the head, and the larger of the two face scales keeps it from shrinking when the head turns.</summary>
    public static StickerPlacement? Place(CameraSticker sticker, FacePoints face, double aspect)
    {
        var eyes = new FacePoint((face.EyeA.X + face.EyeB.X) * 0.5, (face.EyeA.Y + face.EyeB.Y) * 0.5);
        var rough = new FacePoint(eyes.X - face.Mouth.X, eyes.Y - face.Mouth.Y);
        var towardsRight = new FacePoint(-rough.Y, rough.X);
        var eyeAToB = (face.EyeB.X - face.EyeA.X) * towardsRight.X + (face.EyeB.Y - face.EyeA.Y) * towardsRight.Y >= 0;
        var (left, right) = eyeAToB ? (face.EyeA, face.EyeB) : (face.EyeB, face.EyeA);

        var axis = new FacePoint(right.X - left.X, right.Y - left.Y);
        var eyeDistance = Math.Sqrt(axis.X * axis.X + axis.Y * axis.Y);
        if (eyeDistance < 1)
        {
            return null;
        }

        var ux = new FacePoint(axis.X / eyeDistance, axis.Y / eyeDistance);
        var uy = new FacePoint(ux.Y, -ux.X);
        var unit = Math.Max(eyeDistance, Math.Sqrt(rough.X * rough.X + rough.Y * rough.Y) / EyesToMouthRatio);
        var anchor = sticker.Anchor == "nose" ? face.Nose : sticker.Anchor == "mouth" ? face.Mouth : eyes;
        var width = sticker.Width * unit;
        return new StickerPlacement(
            new FacePoint(
                anchor.X + unit * (sticker.OffsetX * ux.X + sticker.OffsetY * uy.X),
                anchor.Y + unit * (sticker.OffsetX * ux.Y + sticker.OffsetY * uy.Y)),
            width,
            sticker.Height is { } height ? height * unit : width * aspect,
            Math.Atan2(ux.Y, ux.X));
    }

    /// <summary>Maps a normalized point of the raw webcam frame into the prepared camera image (crop, then mirror), still normalized.</summary>
    public static FacePoint Mapped(FacePoint point, Rect01 crop, bool isFlipped)
    {
        var x = (point.X - crop.X) / Math.Max(0.25, crop.Width);
        var y = (point.Y - crop.Y) / Math.Max(0.25, crop.Height);
        return new FacePoint(isFlipped ? 1 - x : x, y);
    }

    /// <summary>The name of a chosen background inside the package: the first 8 bytes of the SHA-256 of the source file, so picking it again reuses the file.</summary>
    public static string BackgroundFileName(ReadOnlySpan<byte> sha256) => $"camera-bg-{Convert.ToHexStringLower(sha256[..8])}.jpg";
}

/// <summary>A person mask for the prepared camera image (cropped and mirrored): 8 bits per pixel, top-down, 255 on the person.</summary>
public sealed record PersonMask(byte[] Pixels, int Width, int Height);

/// <summary>Gives the compositor a person mask for a decoded camera picture. Implementations decide whether that waits (export) or returns the newest one available (preview).</summary>
public interface IPersonMaskSource
{
    PersonMask? MaskFor(VideoFrame frame, Rect01 crop, bool mirror);
}
