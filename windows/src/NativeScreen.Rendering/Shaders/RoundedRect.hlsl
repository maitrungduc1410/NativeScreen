// dxc: ps_5_0
// Premultiplied rounded rect. Blend state is ONE / INV_SRC_ALPHA.
// ringWidth above 0 cuts a disc of radius - ringWidth out of the middle, for the click ripple.
cbuffer Box : register(b0)
{
    float4 rect;
    float radius;
    float ringWidth;
    float2 pad;
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
    float dist = sdRoundRect(position.xy - center, rect.zw * 0.5, min(radius, min(rect.z, rect.w) * 0.5));
    float coverage = saturate(0.5 - dist);
    if (ringWidth > 0.0)
    {
        coverage *= saturate(dist + ringWidth + 0.5);
    }

    float alpha = color.a * coverage;
    return float4(color.rgb * alpha, alpha);
}
