// dxc: ps_5_0
// BT.709 limited-range NV12 to gamma-encoded sRGB. Do not linearize.
cbuffer Constants : register(b0)
{
    float2 texel;
    float2 pad;
};

Texture2D<float> luma : register(t0);
Texture2D<float2> chroma : register(t1);
SamplerState linearClamp : register(s0);

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 uv = position.xy * texel;
    float y = luma.Sample(linearClamp, uv);
    float2 cbcr = chroma.Sample(linearClamp, uv);
    float yp = (y - 16.0 / 255.0) * (255.0 / 219.0);
    float cb = (cbcr.x - 128.0 / 255.0) * (255.0 / 224.0);
    float cr = (cbcr.y - 128.0 / 255.0) * (255.0 / 224.0);
    float3 rgb = float3(
        yp + 1.5748 * cr,
        yp - 0.1873 * cb - 0.4681 * cr,
        yp + 1.8556 * cb);
    return float4(saturate(rgb), 1);
}
