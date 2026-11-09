using System.Numerics;
using System.Runtime.InteropServices;
using NativeScreen.Core;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace NativeScreen.Rendering;

/// <summary>Background behind the person, and the sticker on the face (spec/07 §7.2b, §7.3).</summary>
public sealed partial class FrameCompositor
{
    private const int KeepPerson = 0;
    private const int RemovePerson = 1;
    private const int RaiseAlpha = 2;
    private const int Morphology = 3;
    private const float BackgroundDownscale = 0.25f;

    private readonly Dictionary<string, (ID3D11ShaderResourceView View, int Width, int Height)> stickerArt = [];
    private (string Path, ID3D11ShaderResourceView View, int Width, int Height)? cameraBackground;
    private ID3D11Buffer? compositeConstants;
    private ID3D11Texture2D? personMaskTexture;
    private ID3D11ShaderResourceView? personMaskView;
    private (int Width, int Height) personMaskSize;

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct CompositeConstants(Vector2 TargetSize, Vector2 TexelStep, int Mode, int Radius, int Dilate, int Pad);

    /// <summary>The graded camera with its background and sticker. <paramref name="isCutOut"/> tells whether it now has transparent parts.</summary>
    private ID3D11ShaderResourceView PreparedCamera(ID3D11ShaderResourceView webcam, ComposeRequest request, bool cutoutLayout, out int width, out int height, out bool isCutOut)
    {
        var view = GradedCamera(webcam, request, out width, out height);
        var config = request.Document.Camera;
        isCutOut = false;
        var wantsBackground = !cutoutLayout && config.BackgroundMode != CameraBackgroundMode.Original;
        var mask = (cutoutLayout || wantsBackground) && request.WebcamFrame is { } frame
            ? request.PersonMasks?.MaskFor(frame, config.CropRect01, config.Mirror)
            : null;
        if (mask is not null)
        {
            var soft = SoftPersonMask(mask, config, width, height);
            if (cutoutLayout)
            {
                var cut = Layer("camera-final", width, height);
                DrawComposite(cut, view, soft.View, KeepPerson);
                view = cut.View;
                isCutOut = true;
            }
            else if (BackgroundBehindPerson(view, soft, config, request.PackageDirectory, width, height) is { } behind)
            {
                _graphics.Context.OMSetBlendState(_sourceOver);
                DrawComposite(behind, view, soft.View, KeepPerson, blend: true);
                view = behind.View;
            }
        }

        return DrawnSticker(view, request, width, height);
    }

    private RenderLayer SoftPersonMask(PersonMask mask, CameraConfig config, int width, int height)
    {
        UploadPersonMask(mask);
        var context = _graphics.Context;
        var soft = Layer("camera-mask", width, height);
        BindTarget(soft);
        context.OMSetBlendState(null);
        DrawQuad(personMaskView!, Identity(width, height), default, 0, 1);
        if (config.CutoutEdgeInset > 0.01)
        {
            Morph(soft, (int)Math.Round(Math.Clamp(config.CutoutEdgeInset * 10, 1, 12)), dilate: false);
        }

        if (config.CutoutEdgeSoftness > 0.01)
        {
            Blur(soft, Math.Clamp(config.CutoutEdgeSoftness * 10, 0.5, 14));
        }

        return soft;
    }

    private void UploadPersonMask(PersonMask mask)
    {
        var context = _graphics.Context;
        if (personMaskTexture is null || personMaskSize != (mask.Width, mask.Height))
        {
            personMaskView?.Dispose();
            personMaskTexture?.Dispose();
            personMaskTexture = _graphics.Device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)mask.Width,
                Height = (uint)mask.Height,
                MipLevels = 1,
                ArraySize = 1,
                Format = Format.R8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Dynamic,
                BindFlags = BindFlags.ShaderResource,
                CPUAccessFlags = CpuAccessFlags.Write
            });
            personMaskView = _graphics.Device.CreateShaderResourceView(personMaskTexture);
            personMaskSize = (mask.Width, mask.Height);
        }

        var mapped = context.Map(personMaskTexture, 0, MapMode.WriteDiscard);
        try
        {
            for (var y = 0; y < mask.Height; y++)
            {
                Marshal.Copy(mask.Pixels, y * mask.Width, mapped.DataPointer + (nint)(y * mapped.RowPitch), mask.Width);
            }
        }
        finally
        {
            context.Unmap(personMaskTexture, 0);
        }
    }

    /// <summary>What goes behind the person, drawn into the layer the person is then placed on. Null when the chosen image is missing.</summary>
    private RenderLayer? BackgroundBehindPerson(ID3D11ShaderResourceView image, RenderLayer soft, CameraConfig config, string? packageDirectory, int width, int height)
    {
        var target = Layer("camera-final", width, height);
        if (config.BackgroundMode == CameraBackgroundMode.Image)
        {
            if (CameraBackgroundImage(config, packageDirectory) is not { } picture)
            {
                return null;
            }

            var scale = Math.Max((double)width / Math.Max(1, picture.Width), (double)height / Math.Max(1, picture.Height));
            var drawnWidth = picture.Width * scale;
            var drawnHeight = picture.Height * scale;
            BindTarget(target);
            _graphics.Context.OMSetBlendState(null);
            DrawQuad(picture.View, PlacedAt((width - drawnWidth) * 0.5, (height - drawnHeight) * 0.5, drawnWidth, drawnHeight), default, 0, 1);
            return target;
        }

        BlurredBackground(target, image, soft, config.BackgroundBlur, width, height);
        return target;
    }

    /// <summary>The person is removed before blurring and the hole filled from around it, so no halo of their colors surrounds them.</summary>
    private void BlurredBackground(RenderLayer target, ID3D11ShaderResourceView image, RenderLayer soft, double amount, int width, int height)
    {
        var context = _graphics.Context;
        var sigma = height * 0.06 * Math.Max(0.05, amount) * BackgroundDownscale;
        var smallWidth = Math.Max(4, (int)(width * BackgroundDownscale));
        var smallHeight = Math.Max(4, (int)(height * BackgroundDownscale));

        var wide = Layer("camera-mask-wide", width, height);
        BindTarget(wide);
        context.OMSetBlendState(null);
        DrawQuad(soft.View, Identity(width, height), default, 0, 1);
        Morph(wide, (int)Math.Ceiling(Math.Max(2, height * 0.008)), dilate: true);

        var hole = Layer("camera-bg-hole", smallWidth, smallHeight);
        DrawComposite(hole, image, wide.View, RemovePerson);
        Blur(hole, sigma);
        var filled = Layer("camera-bg-filled", smallWidth, smallHeight);
        DrawComposite(filled, hole.View, null, RaiseAlpha);

        var plain = Layer("camera-bg-plain", smallWidth, smallHeight);
        BindTarget(plain);
        context.OMSetBlendState(null);
        DrawQuad(image, Identity(smallWidth, smallHeight), default, 0, 1);
        Blur(plain, sigma);

        BindTarget(target);
        context.OMSetBlendState(null);
        DrawQuad(plain.View, Identity(width, height), default, 0, 1);
        context.OMSetBlendState(_sourceOver);
        DrawQuad(filled.View, Identity(width, height), default, 0, 1);
    }

    private void Morph(RenderLayer layer, int radius, bool dilate)
    {
        var scratch = Layer($"blur{layer.Width}x{layer.Height}", layer.Width, layer.Height);
        var size = new Vector2(layer.Width, layer.Height);
        _graphics.Context.OMSetBlendState(null);
        DrawFullTarget(scratch, layer.View, null, new CompositeConstants(size, new Vector2(1f / layer.Width, 0), Morphology, radius, dilate ? 1 : 0, 0));
        DrawFullTarget(layer, scratch.View, null, new CompositeConstants(size, new Vector2(0, 1f / layer.Height), Morphology, radius, dilate ? 1 : 0, 0));
    }

    private void DrawComposite(RenderLayer target, ID3D11ShaderResourceView image, ID3D11ShaderResourceView? mask, int mode, bool blend = false)
    {
        if (!blend)
        {
            _graphics.Context.OMSetBlendState(null);
        }

        DrawFullTarget(target, image, mask, new CompositeConstants(new Vector2(target.Width, target.Height), Vector2.Zero, mode, 0, 0, 0));
    }

    private void DrawFullTarget(RenderLayer target, ID3D11ShaderResourceView image, ID3D11ShaderResourceView? mask, CompositeConstants constants)
    {
        var context = _graphics.Context;
        compositeConstants ??= CreateConstants(Marshal.SizeOf<CompositeConstants>());
        BindTarget(target);
        context.PSSetShader(_personComposite);
        context.PSSetShaderResource(0, image);
        context.PSSetShaderResource(1, mask!);
        context.UpdateSubresource(constants, compositeConstants);
        context.PSSetConstantBuffer(0, compositeConstants);
        context.Draw(3, 0);
        context.PSSetShaderResource(0, null!);
        context.PSSetShaderResource(1, null!);
    }

    private (ID3D11ShaderResourceView View, int Width, int Height)? CameraBackgroundImage(CameraConfig config, string? packageDirectory)
    {
        if (config.BackgroundImagePath is not { Length: > 0 } relative || packageDirectory is null)
        {
            return null;
        }

        var path = Path.Combine(packageDirectory, relative);
        if (cameraBackground is { } known && known.Path == path)
        {
            return (known.View, known.Width, known.Height);
        }

        if (!File.Exists(path))
        {
            return null;
        }

        var image = ImageTexture.Load(path, 2560);
        var view = image.CreateView(_graphics.Device);
        cameraBackground?.View.Dispose();
        cameraBackground = (path, view, image.Width, image.Height);
        return (view, image.Width, image.Height);
    }

    private ID3D11ShaderResourceView DrawnSticker(ID3D11ShaderResourceView view, ComposeRequest request, int width, int height)
    {
        var config = request.Document.Camera;
        if (config.StickerId is not { } id || CameraStickerCatalog.Find(id) is not { } sticker || request.FaceTrack is not { } track)
        {
            return view;
        }

        if (track.PointsAt(Math.Max(0, request.SourceMs + config.DelayAdjustmentMs)) is not { } face || StickerArt(sticker) is not { } art)
        {
            return view;
        }

        var flipped = !config.Mirror;
        FacePoint InImage(FacePoint point)
        {
            var mapped = CameraEffects.Mapped(point, config.CropRect01, flipped);
            return new FacePoint(mapped.X * width, mapped.Y * height);
        }

        var points = new FacePoints(InImage(face.Points.EyeA), InImage(face.Points.EyeB), InImage(face.Points.Nose), InImage(face.Points.Mouth));
        if (CameraEffects.Place(sticker, points, (double)art.Height / Math.Max(1, art.Width)) is not { } placement)
        {
            return view;
        }

        var context = _graphics.Context;
        var output = Layer("camera-sticker", width, height);
        BindTarget(output);
        context.OMSetBlendState(null);
        context.ClearRenderTargetView(output.Target, new Color4(0, 0, 0, 0));
        DrawQuad(view, Identity(width, height), default, 0, 1);
        context.OMSetBlendState(_sourceOver);
        var cos = Math.Cos(placement.Angle);
        var sin = Math.Sin(placement.Angle);
        var center = placement.Center;
        DrawQuad(
            art.View,
            new QuadMap(
                new Vector4((float)(cos / placement.Width), (float)(sin / placement.Width), (float)(-(center.X * cos + center.Y * sin) / placement.Width + 0.5), 0),
                new Vector4((float)(-sin / placement.Height), (float)(cos / placement.Height), (float)((center.X * sin - center.Y * cos) / placement.Height + 0.5), 0)),
            default,
            0,
            (float)face.Opacity);
        return output.View;
    }

    private (ID3D11ShaderResourceView View, int Width, int Height)? StickerArt(CameraSticker sticker)
    {
        if (stickerArt.TryGetValue(sticker.Id, out var known))
        {
            return known;
        }

        var path = CameraStickerCatalog.ImagePath(sticker);
        if (!File.Exists(path))
        {
            return null;
        }

        var image = ImageTexture.Load(path);
        var loaded = (image.CreateView(_graphics.Device), image.Width, image.Height);
        stickerArt[sticker.Id] = loaded;
        return loaded;
    }

    private void DisposeCameraEffects()
    {
        foreach (var art in stickerArt.Values)
        {
            art.View.Dispose();
        }

        cameraBackground?.View.Dispose();
        personMaskView?.Dispose();
        personMaskTexture?.Dispose();
        compositeConstants?.Dispose();
    }
}
