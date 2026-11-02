// dxc: cs_5_0
// Bends the positioned screen around each click: spec/07 Pass 4, spec/06 ADR-30. Everything is in canvas pixels.
cbuffer ClickRipple : register(b0)
{
    float4 waves[3]; // center x, y in pixels, front radius in pixels, signed strength
    int waveCount;
    float bandWidth;
    float pull;
    float fringe;
    float coreRadius;
    float3 pad;
};

Texture2D<float4> srcTex : register(t0);
SamplerState smp : register(s0);
RWTexture2D<float4> dstTex : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint width, height;
    dstTex.GetDimensions(width, height);
    if (id.x >= width || id.y >= height)
    {
        return;
    }

    float2 size = float2(width, height);
    float2 px = float2(id.xy) + 0.5;
    float2 displacement = float2(0, 0);
    float2 split = float2(0, 0);
    for (int i = 0; i < waveCount; i++)
    {
        float4 wave = waves[i];
        float2 offset = px - wave.xy;
        float dist = length(offset);
        float band = (dist - wave.z) / bandWidth;
        if (dist < 0.001 || abs(band) > 3.0)
        {
            continue;
        }

        float2 radial = offset / dist;
        float weight = exp(-band * band * 3.5) * smoothstep(0.0, coreRadius, dist);
        displacement += radial * wave.w * weight * pull;
        split += radial * abs(wave.w) * weight * (1.0 - weight) * 4.0 * fringe;
    }

    if (displacement.x == 0.0 && displacement.y == 0.0)
    {
        dstTex[id.xy] = srcTex.SampleLevel(smp, px / size, 0);
        return;
    }

    // Red and blue bend a little apart from green, only where the band is moving through.
    float2 at = px - displacement;
    float4 green = srcTex.SampleLevel(smp, at / size, 0);
    float4 red = srcTex.SampleLevel(smp, (at - split) / size, 0);
    float4 blue = srcTex.SampleLevel(smp, (at + split) / size, 0);
    dstTex[id.xy] = float4(red.r, green.g, blue.b, green.a);
}
