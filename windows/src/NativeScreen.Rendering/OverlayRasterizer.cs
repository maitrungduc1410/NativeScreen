using System.Runtime.InteropServices;
using NativeScreen.Core;
using SharpGen.Runtime.Win32;
using Vortice.DCommon;
using Vortice.Direct2D1;
using Vortice.Direct3D11;
using Vortice.DirectWrite;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace NativeScreen.Rendering;

/// <summary>Direct2D and DirectWrite drawing for what has no shader: SVG cursors, captions and keycaps.</summary>
public sealed class OverlayRasterizer : IDisposable
{
    private readonly ID3D11Device device;
    private readonly ID2D1Factory1 factory;
    private readonly ID2D1Device d2dDevice;
    private readonly ID2D1DeviceContext5 context;
    private readonly IDWriteFactory writeFactory;
    private readonly Dictionary<string, (RenderLayer Layer, double HotspotX, double HotspotY)> sprites = [];
    private readonly string cursorRoot = Path.Combine(AppContext.BaseDirectory, "Assets", "Cursors", "sets");

    public OverlayRasterizer(ID3D11Device device)
    {
        this.device = device;
        factory = D2D1.D2D1CreateFactory<ID2D1Factory1>();
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        d2dDevice = factory.CreateDevice(dxgi);
        using var plain = d2dDevice.CreateDeviceContext(DeviceContextOptions.None);
        context = plain.QueryInterface<ID2D1DeviceContext5>();
        writeFactory = DWrite.DWriteCreateFactory<IDWriteFactory>();
    }

    public ID2D1DeviceContext5 Context => context;

    public IDWriteFactory WriteFactory => writeFactory;

    public ID2D1Factory1 Factory => factory;

    /// <summary>Same mapping as the macOS sprite provider: telemetry kind to file kind, falling back to the pointer.</summary>
    public (RenderLayer Layer, double HotspotX, double HotspotY)? CursorSprite(CursorConfig config, string cursorType)
    {
        var theme = CursorSpriteName.NormalizeThemeId(config.ThemeId);
        var type = config.AlwaysUsePointer ? "arrow" : cursorType;
        var key = $"{theme}|{config.VariantId}|{type}";
        if (sprites.TryGetValue(key, out var cached))
        {
            return cached;
        }

        var directory = Path.Combine(cursorRoot, theme);
        if (!Directory.Exists(directory))
        {
            return null;
        }

        var files = Directory.GetFiles(directory, "*.svg")
            .Select(path => (Path: path, Name: CursorSpriteName.Parse(Path.GetFileName(path), theme)))
            .OrderBy(item => item.Name.Kind == "pointer" ? 0 : 1)
            .ThenBy(item => item.Name.Kind, StringComparer.Ordinal)
            .ThenBy(item => item.Name.Variant)
            .ToList();
        if (files.Count == 0)
        {
            return null;
        }

        var kind = MapKind(type);
        // Hands and bars follow the selected pointer variant when the theme draws them per variant (spec/06 ADR-29).
        var pointer = config.VariantId is { } variant
            ? files.Find(item => Path.GetFileName(item.Path).StartsWith(variant + "__", StringComparison.Ordinal))
            : default;
        var chosen = kind == "pointer" && pointer.Path is not null
            ? pointer
            : files.Find(item => item.Name.Kind == kind && pointer.Path is not null && item.Name.Variant == pointer.Name.Variant);
        if (chosen.Path is null)
        {
            chosen = files.Find(item => item.Name.Kind == kind);
        }
        if (chosen.Path is null)
        {
            chosen = pointer.Path is not null ? pointer : files.Find(item => item.Name.Kind == "pointer");
        }

        if (chosen.Path is null)
        {
            chosen = files[0];
        }

        const int size = 256;
        var layer = new RenderLayer(device, size, size);
        Draw(layer, () =>
        {
            using var stream = MemoryStream(File.ReadAllBytes(chosen.Path));
            using var svg = context.CreateSvgDocument(stream, new Size(100, 100));
            // The files are authored on a 100×100 view box and Direct2D honors their width and height attributes.
            context.Transform = System.Numerics.Matrix3x2.CreateScale(size / 100f);
            context.DrawSvgDocument(svg);
            context.Transform = System.Numerics.Matrix3x2.Identity;
        });
        AddSvgDropShadow(layer, size);
        var result = (layer, chosen.Name.HotspotX, chosen.Name.HotspotY);
        sprites[key] = result;
        return result;
    }


    private readonly HashSet<string> unusableCustomCursors = [];
    private readonly Dictionary<string, string> customCursorKeys = [];

    /// <summary>
    /// The user's picture for this cursor kind (spec/07 Pass 4): the arrow (every kind with `alwaysUsePointer`) or the hand,
    /// drawn into a 256 px square at 72% with its hotspot on the same fraction of the square. Null uses the theme.
    /// </summary>
    public (RenderLayer Layer, double HotspotX, double HotspotY)? CustomCursorSprite(CursorConfig config, string cursorType, string? packageDirectory)
    {
        var custom = config.AlwaysUsePointer ? config.CustomPointer : MapKind(cursorType) switch
        {
            "pointer" => config.CustomPointer,
            "pointinghand" => config.CustomHand,
            _ => null
        };
        if (custom is null || packageDirectory is null || custom.ImagePath.Length == 0)
        {
            return null;
        }

        var key = FormattableString.Invariant($"custom|{packageDirectory}|{custom.ImagePath}|{custom.Hotspot01.X}|{custom.Hotspot01.Y}");
        if (sprites.TryGetValue(key, out var cached))
        {
            return cached;
        }

        // A missing or unreadable picture is remembered: otherwise every frame would look for it and decode it again.
        if (unusableCustomCursors.Contains(key))
        {
            return null;
        }

        var path = Path.Combine(packageDirectory, custom.ImagePath);
        ImageTexture? loaded = null;
        try
        {
            loaded = File.Exists(path) ? ImageTexture.Load(path, 1024, orient: true) : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SharpGen.Runtime.SharpGenException)
        {
            loaded = null;
        }

        if (loaded is not { Width: > 0, Height: > 0 } picture)
        {
            unusableCustomCursors.Add(key);
            return null;
        }

        // One sprite per slot: moving the tip makes a new one, and the old one goes.
        var slot = (ReferenceEquals(custom, config.CustomHand) ? "hand|" : "pointer|") + packageDirectory;
        if (customCursorKeys.TryGetValue(slot, out var previous) && previous != key && sprites.Remove(previous, out var old))
        {
            old.Layer.Dispose();
        }

        customCursorKeys[slot] = key;

        const int size = 256;
        var scale = (float)(size / (double)Math.Max(picture.Width, picture.Height) * 0.72);
        var drawnWidth = picture.Width * scale;
        var drawnHeight = picture.Height * scale;
        var hx = (float)custom.Hotspot01.X;
        var hy = (float)custom.Hotspot01.Y;
        var left = hx * (size - drawnWidth);
        var top = hy * (size - drawnHeight);
        var layer = new RenderLayer(device, size, size);
        Draw(layer, () =>
        {
            var pinned = GCHandle.Alloc(picture.Pixels, GCHandleType.Pinned);
            try
            {
                using var bitmap = context.CreateBitmap(
                    new SizeI(picture.Width, picture.Height),
                    pinned.AddrOfPinnedObject(),
                    (uint)(picture.Width * 4),
                    new BitmapProperties1(new PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied)));
                context.DrawBitmap(bitmap, new Rect(left, top, drawnWidth, drawnHeight), 1, Vortice.Direct2D1.InterpolationMode.HighQualityCubic, null, null);
            }
            finally
            {
                pinned.Free();
            }
        });
        var result = (layer, (double)hx, (double)hy);
        sprites[key] = result;
        return result;
    }

    /// <summary>Clears a layer and draws into it. Direct2D shares the device, so the compositor must not be mid-pass.</summary>
    public void Draw(RenderLayer layer, Action draw)
    {
        using var surface = layer.Texture.QueryInterface<IDXGISurface>();
        using var bitmap = context.CreateBitmapFromDxgiSurface(
            surface,
            new BitmapProperties1(new PixelFormat(Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied), 96, 96, BitmapOptions.Target | BitmapOptions.CannotDraw));
        context.Target = bitmap;
        context.AntialiasMode = AntialiasMode.PerPrimitive;
        context.TextAntialiasMode = Vortice.Direct2D1.TextAntialiasMode.Grayscale;
        context.BeginDraw();
        context.Clear(new Color4(0, 0, 0, 0));
        draw();
        context.EndDraw();
        context.Target = null;
    }

    public void Dispose()
    {
        foreach (var sprite in sprites.Values)
        {
            sprite.Layer.Dispose();
        }

        writeFactory.Dispose();
        context.Dispose();
        d2dDevice.Dispose();
        factory.Dispose();
    }

    // Direct2D ignores SVG filters. Every cursor file uses the same one: black at 50%, stdDeviation 3, dy 2.4 (view box units).
    private void AddSvgDropShadow(RenderLayer layer, int size)
    {
        const double viewBoxScale = 2.56;
        var immediate = device.ImmediateContext;
        var pixels = ImageTexture.ReadBack(device, immediate, layer.Texture, size, size);
        var sigma = 3 * viewBoxScale;
        var radius = (int)Math.Ceiling(sigma * 3);
        var weights = new float[radius + 1];
        var total = 0f;
        for (var i = 0; i <= radius; i++)
        {
            weights[i] = (float)Math.Exp(-(i * i) / (2 * sigma * sigma));
            total += i == 0 ? weights[i] : 2 * weights[i];
        }

        var alpha = new float[size * size];
        var scratch = new float[size * size];
        for (var i = 0; i < alpha.Length; i++)
        {
            alpha[i] = pixels[i * 4 + 3] / 255f;
        }

        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var sum = 0f;
                for (var k = -radius; k <= radius; k++)
                {
                    sum += alpha[y * size + Math.Clamp(x + k, 0, size - 1)] * weights[Math.Abs(k)];
                }

                scratch[y * size + x] = sum / total;
            }
        }

        var offset = (int)Math.Round(2.4 * viewBoxScale);
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var sum = 0f;
                for (var k = -radius; k <= radius; k++)
                {
                    sum += scratch[Math.Clamp(y - offset + k, 0, size - 1) * size + x] * weights[Math.Abs(k)];
                }

                var shadow = sum / total * 0.5f;
                var o = (y * size + x) * 4;
                var keep = 1 - pixels[o + 3] / 255f;
                pixels[o + 3] = (byte)Math.Clamp(pixels[o + 3] + shadow * keep * 255f + 0.5f, 0, 255);
                pixels[o] = pixels[o];
            }
        }

        immediate.UpdateSubresource(pixels, layer.Texture, 0, (uint)(size * 4));
    }

    private static string MapKind(string raw) => raw switch
    {
        "arrow" or "default" => "pointer",
        // Older recordings on both platforms wrote `pointer` for the hand (spec/06 ADR-73).
        "pointingHand" or "pointinghand" or "pointer" => "pointinghand",
        "iBeam" or "ibeam" or "ibeamstroke" => "ibeamstroke",
        "crosshair" or "cross" => "cross",
        "closedHand" or "closedhand" or "openHand" or "openhand" => "closedhand",
        _ => "pointer"
    };

    private static ComStream MemoryStream(byte[] data)
    {
        var pointer = SHCreateMemStream(data, (uint)data.Length);
        if (pointer == 0)
        {
            throw new InvalidOperationException("SHCreateMemStream failed.");
        }

        return new ComStream(pointer);
    }

    [DllImport("shlwapi.dll")]
    private static extern nint SHCreateMemStream(byte[] data, uint size);
}
