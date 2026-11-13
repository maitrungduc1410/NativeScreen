// dxc: cs_5_0
cbuffer Lens : register(b0)
{
    float2 center;
    float radius;
    float zoom;
    float rimRatio;
    float fringe;
    float presence;
    float pad;
    // Canvas position of the magnified patch's top-left texel (ADR-86).
    float2 contentOrigin;
    float2 pad2;
};

Texture2D<float4> srcTex : register(t0);
// The scene drawn again from source pixels at lens scale, over a bounded patch around the lens: magnified text stays sharp.
Texture2D<float4> contentTex : register(t1);
SamplerState smp : register(s0);
RWTexture2D<float4> dstTex : register(u0);

float4 sampleAt(float2 px, float2 size)
{
    return srcTex.SampleLevel(smp, px / size, 0);
}

float4 contentAt(float2 px, float2 size)
{
    return contentTex.SampleLevel(smp, (px - contentOrigin) / size, 0);
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
    uint contentWidth;
    uint contentHeight;
    contentTex.GetDimensions(contentWidth, contentHeight);
    float2 contentSize = float2(contentWidth, contentHeight);
    float2 px = float2(gid.xy) + 0.5;
    float4 under = sampleAt(px, size);
    float2 offset = px - center;
    float dist = length(offset);
    float R = radius;

    float shadowSigma = R * 0.10;
    float shadowDist = length(offset - float2(0.0, R * 0.07)) - R * 0.98;
    float shadow = 0.30 * exp(-0.5 * pow(max(shadowDist, 0.0) / shadowSigma, 2.0));
    float coverage = clamp(R - dist + 0.5, 0.0, 1.0);
    float4 outside = float4(under.rgb * (1.0 - shadow * presence * (1.0 - coverage)), under.a);
    if (coverage <= 0.0)
    {
        dstTex[gid.xy] = outside;
        return;
    }

    float r = dist / R;
    float rimStart = 1.0 - rimRatio;
    float rim = smoothstep(rimStart, 1.0, r);
    // The patch is already magnified, so the glass samples it at the offset itself, not offset / zoom.
    float2 lensOffset = offset;
    float bend = 1.0 + 0.55 * rim * rim;
    float spread = 0.045 * fringe * rim;
    float2 baseRel = lensOffset * bend;
    float4 g = contentAt(center + baseRel, contentSize);
    float rr = contentAt(center + baseRel * (1.0 - spread), contentSize).r;
    float bb = contentAt(center + baseRel * (1.0 + spread), contentSize).b;
    float3 glass = float3(rr, g.g, bb);

    float2 dir = dist > 0.001 ? offset / dist : float2(0.0, -1.0);
    float2 toLight = normalize(float2(-0.45, -0.9));
    float facing = dot(dir, toLight);
    float gloss = smoothstep(0.25, -0.85, offset.y / R) * (1.0 - smoothstep(0.55, 0.95, r)) * 0.07;
    glass += gloss;
    glass *= 1.0 - 0.10 * rim * (0.6 - 0.4 * facing);
    float edgePx = R - dist;
    float ringWidth = max(1.5, R * 0.018);
    float ring = exp(-edgePx / ringWidth);
    float highlight = ring * (0.55 * smoothstep(0.1, 0.9, facing) + 0.18 * smoothstep(0.3, 0.95, -facing));
    glass = glass + (1.0 - glass) * clamp(highlight, 0.0, 1.0);

    float mixAmount = coverage * presence;
    dstTex[gid.xy] = float4(lerp(outside.rgb, glass, mixAmount), lerp(outside.a, max(g.a, under.a), mixAmount));
}
