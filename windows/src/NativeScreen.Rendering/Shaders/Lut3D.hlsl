// dxc: cs_5_0
// 3D LUT. Texture x is red (fastest axis, Adobe .cube order), y green, z blue.
cbuffer Lut : register(b0)
{
    float intensity;
    float lutSize;
    float2 pad;
};

Texture2D<float4> srcTex : register(t0);
Texture3D<float4> lut : register(t1);
SamplerState linearClamp : register(s0);
RWTexture2D<float4> dstTex : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    uint width;
    uint height;
    dstTex.GetDimensions(width, height);
    if (gid.x >= width || gid.y >= height)
    {
        return;
    }

    float4 original = srcTex.Load(int3(gid.xy, 0));
    float scale = (lutSize - 1.0) / lutSize;
    float offset = 0.5 / lutSize;
    float3 graded = lut.SampleLevel(linearClamp, original.rgb * scale + offset, 0).rgb;
    dstTex[gid.xy] = float4(lerp(original.rgb, graded, saturate(intensity)), original.a);
}
