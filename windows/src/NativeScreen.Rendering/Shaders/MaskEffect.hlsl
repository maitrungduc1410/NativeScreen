// dxc: ps_5_0
// Pixelate (mode 0): cells anchored at the mask center, sampled at cell centers, inside the rounded rect.
// Spotlight (mode 1): keeps the rounded rect, multiplies RGB outside it by keep.
cbuffer Mask : register(b0)
{
    float4 rect;
    float2 outputSize;
    float radius;
    float cell;
    float keep;
    int mode;
    float2 pad;
};

Texture2D<float4> image : register(t0);
SamplerState linearClamp : register(s0);

float sdRoundRect(float2 p, float2 halfSize, float radius)
{
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 center = rect.xy + rect.zw * 0.5;
    float coverage = saturate(0.5 - sdRoundRect(position.xy - center, rect.zw * 0.5, radius));
    float4 original = image.Sample(linearClamp, position.xy / outputSize);
    if (mode == 1)
    {
        return float4(original.rgb * lerp(keep, 1.0, coverage), original.a);
    }

    float2 cellIndex = floor((position.xy - center) / cell);
    float2 samplePoint = center + (cellIndex + 0.5) * cell;
    float4 pixelated = image.Sample(linearClamp, samplePoint / outputSize);
    return lerp(original, pixelated, coverage);
}
