using NativeScreen.Core;
using Vortice.Direct3D11;

namespace NativeScreen.Rendering;

/// <summary>Camera-only recordings: the camera movie is the screen, styled as the camera (spec/07 Pass 2, spec/06 ADR-77).</summary>
public sealed partial class FrameCompositor
{
    /// <summary>The zoom camera at `sourceMs`; in a camera-only recording with face tracking, a zoom centers on the face.</summary>
    private static SpringTrajectorySolver.CameraFrameState CameraAt(ComposeRequest request, double sourceMs, SpringTrajectorySolver.CameraFrameState solved) =>
        request.CameraOnly
            ? CameraOnlyLayout.FaceCentered(solved, CameraOnlyLayout.FaceCenter01(request.Document, request.FaceTrack, sourceMs))
            : solved;

    /// <summary>
    /// The main picture through the camera preparation (mirror, background, grade, sharpen; no camera crop or sticker), the
    /// person alone for the Cutout framing. The masked-screen caches are skipped: the picture's styling is not in their key.
    /// </summary>
    private ComposeRequest WithCameraOnlyPicture(ComposeRequest request, ID3D11ShaderResourceView main)
    {
        var cutout = request.Document.Camera.CameraOnlyFraming == CameraOnlyFraming.Cutout;
        var picture = PreparedPicture(main, request.ScreenWidth, request.ScreenHeight, request.ScreenFrame, request, cutout, cameraOnly: true, out var width, out var height, out _);
        return new ComposeRequest
        {
            Document = request.Document,
            Trajectory = request.Trajectory,
            SourceMs = request.SourceMs,
            HasCamera = false,
            ExportQuality = request.ExportQuality,
            PackageDirectory = request.PackageDirectory,
            Shortcuts = request.Shortcuts,
            FaceTrack = request.FaceTrack,
            PersonMasks = request.PersonMasks,
            HiddenAnnotationId = request.HiddenAnnotationId,
            CameraOnly = true,
            Screen = picture,
            ScreenWidth = width,
            ScreenHeight = height
        };
    }
}
