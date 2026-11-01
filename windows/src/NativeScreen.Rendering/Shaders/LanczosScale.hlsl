// dxc: ps_5_0
// One direction of a Lanczos-3 downscale, the CILanczosScaleTransform used for the screen when it shrinks uniformly.
cbuffer Scale : register(b0)
{
    float2 axis;
    float ratio;
    float pad;
};

Texture2D<float4> image : register(t0);

static const float PI = 3.14159265358979;

float lanczos(float x)
{
    x = abs(x);
    if (x < 0.0001)
    {
        return 1.0;
    }

    if (x >= 3.0)
    {
        return 0.0;
    }

    float p = PI * x;
    return 3.0 * sin(p) * sin(p / 3.0) / (p * p);
}

float4 main(float4 position : SV_Position) : SV_Target
{
    uint width;
    uint height;
    image.GetDimensions(width, height);
    int limit = int(dot(axis, float2(width, height))) - 1;
    float center = dot(axis, position.xy) / ratio;
    float support = 3.0 / ratio;
    int first = max(0, int(floor(center - support)));
    int last = min(limit, int(ceil(center + support)));
    int2 fixedCoordinate = int2(position.xy * (1.0 - axis));
    float4 sum = float4(0, 0, 0, 0);
    float total = 0.0;
    for (int i = first; i <= last; ++i)
    {
        float weight = lanczos((float(i) + 0.5 - center) * ratio);
        sum += image.Load(int3(fixedCoordinate + int2(axis) * i, 0)) * weight;
        total += weight;
    }

    return saturate(sum / max(total, 0.0001));
}
