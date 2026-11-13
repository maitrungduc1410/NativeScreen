namespace NativeScreen.Core;

/// <summary>
/// Camera-only recordings (spec/06 ADR-77, spec/07 Pass 2): the face keeps the picture framed when it fills the canvas and
/// when it zooms. Port of `ProjectSession+CameraOnly.swift` and `cameraOnlyFillRect`.
/// </summary>
public static class CameraOnlyLayout
{
    public static bool FillsCanvas(this CameraOnlyFraming framing) => framing != CameraOnlyFraming.Framed;

    /// <summary>
    /// Where the face sits at `sourceMs` in the main picture after mirroring and the canvas crop (top-left, 0...1). Null unless
    /// face tracking is on and a face was found.
    /// </summary>
    public static Point01? FaceCenter01(ProjectDocument document, FaceTrack? track, double sourceMs)
    {
        if (!document.Camera.EnableFaceTracking || track?.FramingCenterAt(sourceMs) is not { } center)
        {
            return null;
        }

        // The picture is flipped unless `mirror` is on.
        var x = document.Camera.Mirror ? center.X : 1 - center.X;
        var crop = document.Canvas.CropRect01;
        return new Point01((x - crop.X) / Math.Max(0.01, crop.Width), (center.Y - crop.Y) / Math.Max(0.01, crop.Height));
    }

    /// <summary>
    /// The picture covering the canvas (top-down). With a face, the picture is enlarged by the face tracking zoom (1...2) and
    /// the face's framing center, which sits below the eyes, goes to the middle, as in the camera layer; the picture never
    /// uncovers the canvas edges (spec/07 Pass 2).
    /// </summary>
    public static PixelRect FillRect(double canvasWidth, double canvasHeight, double sourceWidth, double sourceHeight, Point01? face, double faceZoom = 1)
    {
        var zoom = face is null ? 1 : Math.Clamp(faceZoom, 1, 2);
        var scale = zoom * Math.Max(canvasWidth / Math.Max(1, sourceWidth), canvasHeight / Math.Max(1, sourceHeight));
        var width = sourceWidth * scale;
        var height = sourceHeight * scale;
        var x = canvasWidth * 0.5 - width * 0.5;
        var y = canvasHeight * 0.5 - height * 0.5;
        if (face is { } f)
        {
            x = canvasWidth * 0.5 - f.X * width;
            y = canvasHeight * 0.5 - f.Y * height;
        }

        x = Math.Min(0, Math.Max(canvasWidth - width, x));
        y = Math.Min(0, Math.Max(canvasHeight - height, y));
        return new PixelRect(x, y, width, height);
    }

    /// <summary>
    /// A zoom centered on the face: the center moves from the solver's toward the face as the zoom grows in (fully at +0.25
    /// scale), clamped so the zoomed picture still covers its frame.
    /// </summary>
    public static SpringTrajectorySolver.CameraFrameState FaceCentered(SpringTrajectorySolver.CameraFrameState camera, Point01? face)
    {
        // The screen camera keeps its own transform while a lens is visible (ADR-86), so the face applies to it too.
        if (camera.Scale <= 1.0005 || face is not { } f)
        {
            return camera;
        }

        var progress = Math.Min(1, (camera.Scale - 1) / 0.25);
        var half = 0.5 / camera.Scale;
        var fx = Math.Min(1 - half, Math.Max(half, f.X));
        var fy = Math.Min(1 - half, Math.Max(half, f.Y));
        return new SpringTrajectorySolver.CameraFrameState
        {
            Center01 = new Point01(camera.Center01.X + (fx - camera.Center01.X) * progress, camera.Center01.Y + (fy - camera.Center01.Y) * progress),
            Scale = camera.Scale,
            Velocity01PerSec = camera.Velocity01PerSec,
            ScaleVelocityPerSec = camera.ScaleVelocityPerSec,
            IsLoupeMode = camera.IsLoupeMode,
            LoupePresence01 = camera.LoupePresence01,
            LoupeScale = camera.LoupeScale,
            LoupeConfig = camera.LoupeConfig,
            LoupeCenter01 = camera.LoupeCenter01
        };
    }
}
