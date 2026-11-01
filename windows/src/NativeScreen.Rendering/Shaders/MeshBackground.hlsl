// dxc: ps_5_0
// Mesh: linear colors[0] top-left to colors[1] bottom-right, then radial colors[2]
// at top-down (0.78 W, 0.28 H), alpha 1 inside 0.05 W and 0 at 0.75 W.
cbuffer Mesh : register(b0)
{
    float4 color0;
    float4 color1;
    float4 color2;
    float2 outputSize;
    float2 pad;
};

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 uv = position.xy / outputSize;
    float3 rgb = lerp(color0.rgb, color1.rgb, saturate((uv.x + uv.y) * 0.5));
    float2 center = float2(outputSize.x * 0.78, outputSize.y * 0.28);
    float dist = length(position.xy - center);
    float inner = outputSize.x * 0.05;
    float outer = outputSize.x * 0.75;
    float radial = 1.0 - saturate((dist - inner) / max(outer - inner, 1.0));
    rgb = lerp(rgb, color2.rgb, radial);
    return float4(rgb, 1);
}
