using Vortice.D3DCompiler;
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
        ("Lut3D", "cs_5_0")
    ];

    private readonly D3D11GraphicsDevice _graphics;
    private readonly ID3D11BlendState _sourceOver;
    private readonly List<ID3D11DeviceChild> _shaders = [];

    public FrameCompositor()
    {
        _graphics = new D3D11GraphicsDevice();
        _sourceOver = CreateSourceOver(_graphics.Device);
        foreach (var (name, profile) in ShaderTable)
        {
            var source = ReadEmbedded(name);
            var bytecode = Compiler.Compile(source, "main", name + ".hlsl", profile);
            ID3D11DeviceChild shader = profile.StartsWith("cs", StringComparison.Ordinal)
                ? _graphics.Device.CreateComputeShader(bytecode.Span)
                : _graphics.Device.CreatePixelShader(bytecode.Span);
            shader.DebugName = name;
            _shaders.Add(shader);
        }
    }

    public int CompiledShaderCount => _shaders.Count;

    public ID3D11Texture2D CreateTarget(int width, int height) => _graphics.CreateWorkingTexture(width, height);

    public CompositionSwapChain CreateSwapChain(int width, int height) =>
        new(_graphics.Device, width, height);

    public void BindSourceOver()
    {
        _graphics.Context.OMSetBlendState(_sourceOver);
    }

    public void Dispose()
    {
        foreach (var shader in _shaders)
        {
            shader.Dispose();
        }

        _sourceOver.Dispose();
        _graphics.Dispose();
    }

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
