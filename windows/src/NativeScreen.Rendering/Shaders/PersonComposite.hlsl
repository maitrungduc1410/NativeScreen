// dxc: ps_5_0
// Full-target passes for the camera's person mask. The mask is in the red channel of t1.
// Mode 0: keep the person. Mode 1: remove the person. Mode 2: raise alpha so a blurred, partly empty image turns opaque
// without darkening it. Mode 3: min (erode) or max (dilate) along texelStep, on red, reading t0.
cbuffer Composite : register(b0)
{
    float2 targetSize;
    float2 texelStep;
    int mode;
    int radius;
    int dilate;
    int pad;
};

Texture2D<float4> image : register(t0);
Texture2D<float4> mask : register(t1);
SamplerState linearClamp : register(s0);

float4 main(float4 position : SV_Position) : SV_Target
{
    float2 uv = position.xy / targetSize;
    float4 color = image.SampleLevel(linearClamp, uv, 0);
    if (mode == 3)
    {
        float value = color.r;
        for (int i = 1; i <= radius; ++i)
        {
            float a = image.SampleLevel(linearClamp, uv + texelStep * float(i), 0).r;
            float b = image.SampleLevel(linearClamp, uv - texelStep * float(i), 0).r;
            value = dilate != 0 ? max(value, max(a, b)) : min(value, min(a, b));
        }

        return float4(value, value, value, 1);
    }

    if (mode == 2)
    {
        if (color.a <= 0.0)
        {
            return float4(0, 0, 0, 0);
        }

        float raised = saturate(color.a * 8.0);
        return float4(color.rgb / color.a * raised, raised);
    }

    float person = mask.SampleLevel(linearClamp, uv, 0).r;
    return color * (mode == 0 ? person : 1.0 - person);
}
