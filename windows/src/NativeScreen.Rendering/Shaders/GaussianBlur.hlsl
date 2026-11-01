// dxc: ps_5_0
// One direction of a separable Gaussian, taps to ceil(3 sigma), edges clamped by the sampler.
cbuffer Blur : register(b0)
{
    float2 texelStep;
    float sigma;
    float pad;
};

Texture2D<float4> image : register(t0);
SamplerState linearClamp : register(s0);

float4 main(float4 position : SV_Position) : SV_Target
{
    uint width;
    uint height;
    image.GetDimensions(width, height);
    float2 uv = position.xy / float2(width, height);
    int taps = min((int)ceil(3.0 * sigma), 192);
    float denominator = 2.0 * sigma * sigma;
    float4 sum = image.SampleLevel(linearClamp, uv, 0);
    float total = 1.0;
    for (int i = 1; i <= taps; ++i)
    {
        float weight = exp(-float(i * i) / denominator);
        float2 offset = texelStep * float(i);
        sum += (image.SampleLevel(linearClamp, uv + offset, 0) + image.SampleLevel(linearClamp, uv - offset, 0)) * weight;
        total += 2.0 * weight;
    }

    return sum / total;
}
