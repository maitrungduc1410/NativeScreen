// dxc: cs_5_0
cbuffer MotionBlur : register(b0)
{
    float4 rectNow;
    float4 rectPrevious;
    float shutter;
    float pixelsPerSample;
    int maxSamples;
    float pad;
};

Texture2D<float4> srcTex : register(t0);
SamplerState smp : register(s0);
RWTexture2D<float4> dstTex : register(u0);

float4 sampleAt(float2 px, float2 size)
{
    return srcTex.SampleLevel(smp, px / size, 0);
}

float4 toLinear(float4 c)
{
    float a = c.a;
    if (a <= 0.0001)
    {
        return float4(0, 0, 0, 0);
    }
    float3 straight = saturate(c.rgb / a);
    return float4(pow(straight, 2.2) * a, a);
}

float4 fromLinear(float4 c)
{
    float a = c.a;
    if (a <= 0.0001)
    {
        return float4(0, 0, 0, 0);
    }
    float3 straight = saturate(c.rgb / a);
    return float4(pow(straight, 1.0 / 2.2) * a, a);
}

float pixelNoise(float2 px)
{
    return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715))));
}

float2 mapToNow(float2 px, float4 previous, float4 now, float t)
{
    float4 r = lerp(previous, now, t);
    float2 local = (px - r.xy) / r.zw;
    return now.xy + local * now.zw;
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

    float2 size = float2(width, height);
    float2 px = float2(gid.xy) + 0.5;
    float2 opened = mapToNow(px, rectPrevious, rectNow, 1.0 - shutter);
    float travel = length(opened - px);
    if (travel < 0.5)
    {
        dstTex[gid.xy] = sampleAt(px, size);
        return;
    }

    int count = clamp((int)ceil(travel / pixelsPerSample), 2, max(2, maxSamples));
    float jitter = pixelNoise(px);
    float4 sum = float4(0, 0, 0, 0);
    for (int i = 0; i < count; ++i)
    {
        float t = 1.0 - shutter * ((float(i) + jitter) / float(count));
        sum += toLinear(sampleAt(mapToNow(px, rectPrevious, rectNow, t), size));
    }
    dstTex[gid.xy] = fromLinear(sum / float(count));
}
