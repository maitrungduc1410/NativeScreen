// dxc: ps_5_0
// CISmoothLinearGradient: a smoothstep ramp from color0 at point0 to color1 at point1 (pixels, top-down).
// Mesh adds a radial color2 at (0.78 W, 0.28 H), alpha 1 inside 0.05 W and 0 at 0.75 W; radialAmount 0 leaves it out.
cbuffer Background : register(b0)
{
    float4 color0;
    float4 color1;
    float4 color2;
    float2 point0;
    float2 point1;
    float2 outputSize;
    float radialAmount;
    float pad;
};

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 axis = point1 - point0;
    float t = saturate(dot(position.xy - point0, axis) / max(dot(axis, axis), 0.0001));
    float3 rgb = lerp(color0.rgb, color1.rgb, t * t * (3.0 - 2.0 * t));
    float2 center = float2(outputSize.x * 0.78, outputSize.y * 0.28);
    float inner = outputSize.x * 0.05;
    float outer = outputSize.x * 0.75;
    float alpha = 1.0 - saturate((length(position.xy - center) - inner) / max(outer - inner, 1.0));
    rgb = lerp(rgb, color2.rgb, alpha * radialAmount);
    return float4(rgb, 1);
}
