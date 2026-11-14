// dxc: ps_5_0
// Draws a premultiplied texture through an affine map from output pixels to uv, clipped to a rounded rect.
cbuffer Quad : register(b0)
{
    float4 mapU;
    float4 mapV;
    float4 clipRect;
    float clipRadius;
    float opacity;
    float blackSilhouette;
    float pad;
    // A cursor hand's index finger folding on a click (spec/06 ADR-95): above v = fold.x the sprite is squashed toward that
    // seam by fold.y. The map is continuous at the seam, so the finger does not tear. fold.y = 0 turns it off.
    float4 fold;
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
    float3 px = float3(position.xy, 1);
    float2 uv = float2(dot(mapU.xyz, px), dot(mapV.xyz, px));
    if (fold.y > 0.0 && fold.y < 0.999 && uv.y < fold.x)
    {
        uv.y = fold.x - (fold.x - uv.y) / fold.y;
    }

    if (any(uv < 0.0) || any(uv > 1.0))
    {
        discard;
    }

    float coverage = 1.0;
    if (clipRect.z > 0.0)
    {
        float2 center = clipRect.xy + clipRect.zw * 0.5;
        coverage = saturate(0.5 - sdRoundRect(position.xy - center, clipRect.zw * 0.5, clipRadius));
    }

    float4 color = image.Sample(linearClamp, uv);
    if (blackSilhouette > 0.5)
    {
        color.rgb = 0.0;
    }

    return color * coverage * opacity;
}
