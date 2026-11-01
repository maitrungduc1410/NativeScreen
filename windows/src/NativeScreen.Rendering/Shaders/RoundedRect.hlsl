// dxc: ps_5_0
// Premultiplied rounded rect. Blend state is ONE / INV_SRC_ALPHA.
cbuffer Box : register(b0)
{
    float4 rect;
    float radius;
    float3 pad;
    float4 color;
};

float sdRoundRect(float2 p, float2 halfSize, float radius)
{
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 center = rect.xy + rect.zw * 0.5;
    float dist = sdRoundRect(position.xy - center, rect.zw * 0.5, radius);
    float coverage = saturate(0.5 - dist);
    float alpha = color.a * coverage;
    return float4(color.rgb * alpha, alpha);
}
