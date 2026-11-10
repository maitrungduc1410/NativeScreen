// dxc: cs_5_0
// Green screen (spec/07 section 7.4), per pixel on sRGB-encoded values: the same functions macOS bakes into 64^3 cubes.
// Mode 0 writes the person mask (1 is the person) to every channel. Mode 1 writes the picture with the backdrop's tint
// pulled out of the key's strongest channel.
cbuffer Chroma : register(b0)
{
    float3 key;
    float similarity;
    float smoothness;
    float spill;
    int mode;
    float pad;
};

Texture2D<float4> srcTex : register(t0);
RWTexture2D<float4> dstTex : register(u0);

float2 Chroma(float3 c)
{
    return float2(
        -0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b,
        0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b);
}

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

    float4 color = srcTex[gid.xy];
    float3 c = color.a > 0.0 ? color.rgb / color.a : float3(0, 0, 0);
    if (mode == 0)
    {
        float distance = length(Chroma(c) - Chroma(key));
        float low = 0.02 + similarity * 0.30;
        float high = low + 0.005 + smoothness * 0.20;
        float t = saturate((distance - low) / (high - low));
        float person = t * t * (3.0 - 2.0 * t);
        dstTex[gid.xy] = float4(person, person, person, 1);
        return;
    }

    if (spill > 0.001)
    {
        if (key.g >= key.r && key.g >= key.b)
        {
            float limit = max(c.r, c.b);
            c.g = c.g > limit ? c.g - (c.g - limit) * spill : c.g;
        }
        else if (key.b >= key.r)
        {
            float limit = max(c.r, c.g);
            c.b = c.b > limit ? c.b - (c.b - limit) * spill : c.b;
        }
        else
        {
            float limit = max(c.g, c.b);
            c.r = c.r > limit ? c.r - (c.r - limit) * spill : c.r;
        }
    }

    dstTex[gid.xy] = float4(c * color.a, color.a);
}
