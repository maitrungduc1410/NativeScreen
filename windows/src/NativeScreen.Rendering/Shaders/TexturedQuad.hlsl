// dxc: ps_5_0
// Draws a premultiplied texture through an affine map from output pixels to uv, clipped to a rounded rect.
cbuffer Quad : register(b0)
{
    float4 mapU;
    float4 mapV;
    float4 clipRect;
    float clipRadius;
    float opacity;
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
    float3 px = float3(position.xy, 1);
    float2 uv = float2(dot(mapU.xyz, px), dot(mapV.xyz, px));
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

    return image.Sample(linearClamp, uv) * coverage * opacity;
}
