using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace NativeScreen.Media;

/// <summary>
/// BGRA to tightly packed NV12 on the GPU, with the same matrix and 2×2 chroma average as Nv12Converter. At full display
/// resolution the CPU path costs 23 ms per frame, too slow for 60 fps and a lot of heat for a recorder.
/// </summary>
public sealed class GpuNv12Converter : IDisposable
{
    private const string VertexSource = """
        float4 main(uint id : SV_VertexID) : SV_Position
        {
            float2 uv = float2((id << 1) & 2, id & 2);
            return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
        }
        """;

    private const string LumaSource = """
        Texture2D<float4> source : register(t0);
        float main(float4 position : SV_Position) : SV_Target
        {
            float3 c = source.Load(int3(position.xy, 0)).rgb;
            return dot(c, float3(47, 157, 16)) / 256.0 + 16.0 / 255.0;
        }
        """;

    private const string ChromaSource = """
        Texture2D<float4> source : register(t0);
        float2 main(float4 position : SV_Position) : SV_Target
        {
            int2 p = int2(position.xy) * 2;
            float3 c = (source.Load(int3(p, 0)).rgb + source.Load(int3(p + int2(1, 0), 0)).rgb
                + source.Load(int3(p + int2(0, 1), 0)).rgb + source.Load(int3(p + int2(1, 1), 0)).rgb) / 4.0;
            return float2(dot(c, float3(-26, -86, 112)), dot(c, float3(112, -102, -10))) / 256.0 + 128.0 / 255.0;
        }
        """;

    private readonly ID3D11DeviceContext context;
    private readonly int width;
    private readonly int height;
    private readonly ID3D11VertexShader vertex;
    private readonly ID3D11PixelShader lumaShader;
    private readonly ID3D11PixelShader chromaShader;
    private readonly ID3D11Texture2D lumaTexture;
    private readonly ID3D11Texture2D chromaTexture;
    private readonly ID3D11Texture2D lumaStaging;
    private readonly ID3D11Texture2D chromaStaging;
    private readonly ID3D11RenderTargetView lumaTarget;
    private readonly ID3D11RenderTargetView chromaTarget;

    public GpuNv12Converter(ID3D11Device device, ID3D11DeviceContext context, int width, int height)
    {
        this.context = context;
        this.width = width;
        this.height = height;
        vertex = device.CreateVertexShader(Compiler.Compile(VertexSource, "main", "nv12-vs.hlsl", "vs_5_0").Span);
        lumaShader = device.CreatePixelShader(Compiler.Compile(LumaSource, "main", "nv12-y.hlsl", "ps_5_0").Span);
        chromaShader = device.CreatePixelShader(Compiler.Compile(ChromaSource, "main", "nv12-uv.hlsl", "ps_5_0").Span);
        lumaTexture = Target(device, width, height, Format.R8_UNorm);
        chromaTexture = Target(device, width / 2, height / 2, Format.R8G8_UNorm);
        lumaStaging = Staging(device, width, height, Format.R8_UNorm);
        chromaStaging = Staging(device, width / 2, height / 2, Format.R8G8_UNorm);
        lumaTarget = device.CreateRenderTargetView(lumaTexture);
        chromaTarget = device.CreateRenderTargetView(chromaTexture);
    }

    /// <summary>Source is a width × height view of BGRA. Blocks only for the GPU to finish this frame.</summary>
    public void Convert(ID3D11ShaderResourceView source, byte[] nv12)
    {
        context.ClearState();
        context.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        context.VSSetShader(vertex);
        context.PSSetShaderResource(0, source);
        Draw(lumaTarget, lumaShader, width, height);
        Draw(chromaTarget, chromaShader, width / 2, height / 2);
        context.ClearState();
        context.CopyResource(lumaStaging, lumaTexture);
        context.CopyResource(chromaStaging, chromaTexture);
        CopyPlane(lumaStaging, nv12.AsSpan(0, width * height), width, height);
        CopyPlane(chromaStaging, nv12.AsSpan(width * height, width * (height / 2)), width, height / 2);
    }

    public void Dispose()
    {
        lumaTarget.Dispose();
        chromaTarget.Dispose();
        lumaStaging.Dispose();
        chromaStaging.Dispose();
        lumaTexture.Dispose();
        chromaTexture.Dispose();
        lumaShader.Dispose();
        chromaShader.Dispose();
        vertex.Dispose();
    }

    private void Draw(ID3D11RenderTargetView target, ID3D11PixelShader shader, int targetWidth, int targetHeight)
    {
        context.OMSetRenderTargets(target);
        context.RSSetViewport(0, 0, targetWidth, targetHeight);
        context.PSSetShader(shader);
        context.Draw(3, 0);
    }

    private unsafe void CopyPlane(ID3D11Texture2D staging, Span<byte> destination, int rowBytes, int rows)
    {
        var mapped = context.Map(staging, 0, MapMode.Read);
        try
        {
            for (var row = 0; row < rows; row++)
            {
                new ReadOnlySpan<byte>((byte*)mapped.DataPointer + row * mapped.RowPitch, rowBytes).CopyTo(destination.Slice(row * rowBytes, rowBytes));
            }
        }
        finally
        {
            context.Unmap(staging, 0);
        }
    }

    private static ID3D11Texture2D Target(ID3D11Device device, int width, int height, Format format) => device.CreateTexture2D(new Texture2DDescription
    {
        Width = (uint)width,
        Height = (uint)height,
        MipLevels = 1,
        ArraySize = 1,
        Format = format,
        SampleDescription = new SampleDescription(1, 0),
        Usage = ResourceUsage.Default,
        BindFlags = BindFlags.RenderTarget
    });

    private static ID3D11Texture2D Staging(ID3D11Device device, int width, int height, Format format) => device.CreateTexture2D(new Texture2DDescription
    {
        Width = (uint)width,
        Height = (uint)height,
        MipLevels = 1,
        ArraySize = 1,
        Format = format,
        SampleDescription = new SampleDescription(1, 0),
        Usage = ResourceUsage.Staging,
        CPUAccessFlags = CpuAccessFlags.Read
    });
}
