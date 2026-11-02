// dxc: cs_5_0
// Unsharp mask on luma with radius 1.6 px (spec/07 section 7.2). Chroma is untouched, so edges gain no color fringes.
cbuffer Sharpen : register(b0)
{
    float amount;
    float3 pad;
};

Texture2D<float4> srcTex : register(t0);
RWTexture2D<float4> dstTex : register(u0);

static const float3 LumaWeights = float3(0.2126, 0.7152, 0.0722);
static const float Sigma = 1.6;

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

    float sum = 0;
    float total = 0;
    for (int y = -3; y <= 3; y++)
    {
        for (int x = -3; x <= 3; x++)
        {
            int2 at = clamp(int2(gid.xy) + int2(x, y), int2(0, 0), int2(width - 1, height - 1));
            float weight = exp(-(x * x + y * y) / (2 * Sigma * Sigma));
            sum += dot(srcTex.Load(int3(at, 0)).rgb, LumaWeights) * weight;
            total += weight;
        }
    }

    float4 original = srcTex.Load(int3(gid.xy, 0));
    float luma = dot(original.rgb, LumaWeights);
    dstTex[gid.xy] = float4(saturate(original.rgb + (luma - sum / total) * amount), original.a);
}
