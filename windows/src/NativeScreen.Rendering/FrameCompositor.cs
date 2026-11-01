using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Rendering;

public sealed class FrameCompositor : IDisposable
{
    public const Format WorkingFormat = Format.B8G8R8A8_UNorm;

    private static readonly (string Name, string Profile)[] ShaderTable =
    [
        ("Nv12ToRgb", "ps_5_0"),
        ("RoundedRect", "ps_5_0"),
        ("MeshBackground", "ps_5_0"),
        ("MagnifierLens", "cs_5_0"),
        ("CameraMotionBlur", "cs_5_0"),
        ("Lut3D", "cs_5_0"),
        ("FullscreenTriangle", "vs_5_0")
    ];

    private readonly D3D11GraphicsDevice _graphics;
    private readonly ID3D11BlendState _sourceOver;
    private readonly List<ID3D11DeviceChild> _shaders = [];
    private readonly ID3D11VertexShader _fullscreen;
    private readonly ID3D11PixelShader _mesh;
    private readonly ID3D11PixelShader _box;
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
        _meshConstants = CreateConstants(Marshal.SizeOf<MeshConstants>());
        _boxConstants = CreateConstants(Marshal.SizeOf<BoxConstants>());
    }

    public int CompiledShaderCount => _shaders.Count;

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

    /// <summary>Render thread only.</summary>
    public void DrawStage(CompositionSwapChain swapChain, StageScene scene, int width, int height)
    {
        var context = _graphics.Context;
        using var backBuffer = swapChain.SwapChain.GetBuffer<ID3D11Texture2D>(0);
        using var target = _graphics.Device.CreateRenderTargetView(backBuffer);
        context.OMSetRenderTargets(target);
        context.RSSetViewport(0, 0, width, height);
        context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        context.VSSetShader(_fullscreen);

        context.OMSetBlendState(null);
        context.PSSetShader(_mesh);
        var mesh = new MeshConstants(scene.Color0, scene.Color1, scene.Color2, new Vector2(width, height), scene.RadialAmount, 0);
        context.UpdateSubresource(in mesh, _meshConstants);
        context.PSSetConstantBuffer(0, _meshConstants);
        context.Draw(3, 0);

        BindSourceOver();
        context.PSSetShader(_box);
        context.PSSetConstantBuffer(0, _boxConstants);
        foreach (var box in scene.Boxes)
        {
            var constants = new BoxConstants(box.Rect, box.Radius, box.Softness, box.RingWidth, 0, box.Color);
            context.UpdateSubresource(in constants, _boxConstants);
            context.Draw(3, 0);
        }

        // Drops the back buffer reference so a later ResizeBuffers can succeed.
        context.ClearState();
    }

    public void Dispose()
    {
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
        _graphics.Device.CreateBuffer(new BufferDescription((uint)size, BindFlags.ConstantBuffer));

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

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct MeshConstants(Vector4 Color0, Vector4 Color1, Vector4 Color2, Vector2 OutputSize, float RadialAmount, float Pad);

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct BoxConstants(Vector4 Rect, float Radius, float Softness, float RingWidth, float Pad, Vector4 Color);
}
