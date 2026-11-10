using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

public sealed partial class FrameCompositor : IDisposable
{
    public const Format WorkingFormat = Format.B8G8R8A8_UNorm;

    private static readonly (string Name, string Profile)[] ShaderTable =
    [
        ("Nv12ToRgb", "ps_5_0"),
        ("RoundedRect", "ps_5_0"),
        ("MeshBackground", "ps_5_0"),
        ("TexturedQuad", "ps_5_0"),
        ("GaussianBlur", "ps_5_0"),
        ("MaskEffect", "ps_5_0"),
        ("LanczosScale", "ps_5_0"),
        ("PersonComposite", "ps_5_0"),
        ("MagnifierLens", "cs_5_0"),
        ("ClickRipple", "cs_5_0"),
        ("CameraMotionBlur", "cs_5_0"),
        ("Lut3D", "cs_5_0"),
        ("SharpenLuma", "cs_5_0"),
        ("ChromaKey", "cs_5_0"),
        ("FullscreenTriangle", "vs_5_0")
    ];

    private readonly D3D11GraphicsDevice _graphics;
    private readonly ID3D11BlendState _sourceOver;
    private readonly List<ID3D11DeviceChild> _shaders = [];
    private readonly ID3D11VertexShader _fullscreen;
    private readonly ID3D11PixelShader _mesh;
    private readonly ID3D11PixelShader _box;
    private readonly ID3D11PixelShader _quad;
    private readonly ID3D11PixelShader _gaussian;
    private readonly ID3D11PixelShader _maskEffect;
    private readonly ID3D11PixelShader _lanczos;
    private readonly ID3D11PixelShader _nv12;
    private readonly ID3D11PixelShader _personComposite;
    private readonly ID3D11ComputeShader _motionBlur;
    private readonly ID3D11ComputeShader _lens;
    private readonly ID3D11ComputeShader _clickRipple;
    private readonly ID3D11ComputeShader _lut;
    private readonly ID3D11ComputeShader _sharpen;
    private readonly ID3D11ComputeShader _chromaKey;
    private readonly ID3D11Buffer _meshConstants;
    private readonly ID3D11Buffer _boxConstants;

    public FrameCompositor()
    {
        _graphics = new D3D11GraphicsDevice();
        _sourceOver = CreateSourceOver(_graphics.Device);
        var shaders = new Dictionary<string, ID3D11DeviceChild>();
        foreach (var (name, profile) in ShaderTable)
        {
            var source = ReadEmbedded(name);
            var bytecode = Compiler.Compile(source, "main", name + ".hlsl", profile);
            ID3D11DeviceChild shader = profile[0] switch
            {
                'c' => _graphics.Device.CreateComputeShader(bytecode.Span),
                'v' => _graphics.Device.CreateVertexShader(bytecode.Span),
                _ => _graphics.Device.CreatePixelShader(bytecode.Span)
            };
            shader.DebugName = name;
            _shaders.Add(shader);
            shaders[name] = shader;
        }

        _fullscreen = (ID3D11VertexShader)shaders["FullscreenTriangle"];
        _mesh = (ID3D11PixelShader)shaders["MeshBackground"];
        _box = (ID3D11PixelShader)shaders["RoundedRect"];
        _quad = (ID3D11PixelShader)shaders["TexturedQuad"];
        _gaussian = (ID3D11PixelShader)shaders["GaussianBlur"];
        _maskEffect = (ID3D11PixelShader)shaders["MaskEffect"];
        _lanczos = (ID3D11PixelShader)shaders["LanczosScale"];
        _nv12 = (ID3D11PixelShader)shaders["Nv12ToRgb"];
        _personComposite = (ID3D11PixelShader)shaders["PersonComposite"];
        _motionBlur = (ID3D11ComputeShader)shaders["CameraMotionBlur"];
        _lens = (ID3D11ComputeShader)shaders["MagnifierLens"];
        _clickRipple = (ID3D11ComputeShader)shaders["ClickRipple"];
        _lut = (ID3D11ComputeShader)shaders["Lut3D"];
        _sharpen = (ID3D11ComputeShader)shaders["SharpenLuma"];
        _chromaKey = (ID3D11ComputeShader)shaders["ChromaKey"];
        _meshConstants = CreateConstants(Marshal.SizeOf<BackgroundConstants>());
        _boxConstants = CreateConstants(Marshal.SizeOf<BoxConstants>());
    }

    public int CompiledShaderCount => _shaders.Count;

    public ID3D11Device Device => _graphics.Device;

    public ID3D11DeviceContext Context => _graphics.Context;

    public ID3D11Texture2D CreateTarget(int width, int height) => _graphics.CreateWorkingTexture(width, height);

    public CompositionSwapChain CreateSwapChain(int width, int height) =>
        new(_graphics.Device, width, height);

    public void BindSourceOver()
    {
        _graphics.Context.OMSetBlendState(_sourceOver);
    }

    /// <summary>Render thread only. Back buffers must have no outstanding views.</summary>
    public void ResizeSwapChain(CompositionSwapChain swapChain, int width, int height, float rasterScale)
    {
        _graphics.Context.ClearState();
        _graphics.Context.Flush();
        swapChain.Resize(width, height, rasterScale);
    }

    /// <summary>Render thread only. Composes the frame and copies it to the back buffer.</summary>
    public void Present(CompositionSwapChain swapChain, ComposeRequest request, int width, int height)
    {
        var frame = Compose(request, width, height);
        using var backBuffer = swapChain.SwapChain.GetBuffer<ID3D11Texture2D>(0);
        _graphics.Context.CopyResource(backBuffer, frame.Texture);
        // Drops the back buffer reference so a later ResizeBuffers can succeed.
        _graphics.Context.ClearState();
    }

    public void Dispose()
    {
        foreach (var layer in layers.Values)
        {
            layer.Dispose();
        }

        foreach (var (scratch, _) in scratchLayers)
        {
            scratch.Dispose();
        }

        foreach (var upload in nv12Uploads.Values)
        {
            upload.Dispose();
        }

        foreach (var word in captionWords.Values)
        {
            word.Dispose();
        }

        DisposeAnnotationSprites();
        overlays?.Dispose();
        DisposeCameraEffects();
        foreach (var view in lutViews.Values)
        {
            view.Dispose();
        }

        foreach (var sprite in keycapSprites.Values)
        {
            sprite.Dispose();
        }

        lutConstants?.Dispose();
        wallpaperView?.Dispose();

        linearClamp?.Dispose();
        quadConstants?.Dispose();
        blurConstants?.Dispose();
        maskConstants?.Dispose();
        motionConstants?.Dispose();
        lensConstants?.Dispose();
        rippleConstants?.Dispose();
        _meshConstants.Dispose();
        _boxConstants.Dispose();
        foreach (var shader in _shaders)
        {
            shader.Dispose();
        }

        _sourceOver.Dispose();
        _graphics.Dispose();
    }

    private ID3D11Buffer CreateConstants(int size) =>
        _graphics.Device.CreateBuffer(new BufferDescription((uint)((size + 15) / 16 * 16), BindFlags.ConstantBuffer));

    private static ID3D11BlendState CreateSourceOver(ID3D11Device device)
    {
        var description = new BlendDescription
        {
            AlphaToCoverageEnable = false,
            IndependentBlendEnable = false
        };
        description.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = true,
            SourceBlend = Blend.One,
            DestinationBlend = Blend.InverseSourceAlpha,
            BlendOperation = BlendOperation.Add,
            SourceBlendAlpha = Blend.One,
            DestinationBlendAlpha = Blend.InverseSourceAlpha,
            BlendOperationAlpha = BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.All
        };
        return device.CreateBlendState(description);
    }

    private static string ReadEmbedded(string name)
    {
        var resource = typeof(FrameCompositor).Assembly.GetManifestResourceStream($"NativeScreen.Rendering.Shaders.{name}.hlsl")
            ?? throw new InvalidOperationException($"Missing embedded shader {name}.");
        using var reader = new StreamReader(resource);
        return reader.ReadToEnd();
    }
}
