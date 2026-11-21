#include <metal_stdlib>
using namespace metal;

// Must match VertexOut in Shaders.metal (same stage-in layout from fullscreenVertex).
struct SharpenVertexOut {
    float4 position [[position]];
    float2 uv;
};

static float3 tap(texture2d<float> t, int2 p, int2 size) {
    return t.read(uint2(clamp(p, int2(0), size - 1))).rgb;
}

// Contrast Adaptive Sharpening (after AMD FidelityFX CAS, no-scale variant). Sharpens hardest
// where local contrast is low and backs off near strong edges, so it adds detail without halos.
// Runs as the final pass, 1:1 from an output-sized texture into the drawable's video area.
fragment float4 casFragment(SharpenVertexOut in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            constant float &sharpness [[buffer(0)]]) {
    int2 size = int2(src.get_width(), src.get_height());
    int2 p = clamp(int2(in.uv * float2(size)), int2(0), size - 1);

    float3 a = tap(src, p + int2(-1, -1), size);
    float3 b = tap(src, p + int2( 0, -1), size);
    float3 c = tap(src, p + int2( 1, -1), size);
    float3 d = tap(src, p + int2(-1,  0), size);
    float3 e = tap(src, p, size);
    float3 f = tap(src, p + int2( 1,  0), size);
    float3 g = tap(src, p + int2(-1,  1), size);
    float3 h = tap(src, p + int2( 0,  1), size);
    float3 i = tap(src, p + int2( 1,  1), size);

    // Soft min/max: the cross plus the full 3×3, which rounds off the response.
    float3 mn = min(min(min(d, e), min(f, b)), h);
    mn += min(mn, min(min(a, c), min(g, i)));
    float3 mx = max(max(max(d, e), max(f, b)), h);
    mx += max(mx, max(max(a, c), max(g, i)));

    float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, 1e-5)));
    float3 w = amp * (-1.0 / mix(8.0, 5.0, saturate(sharpness)));
    float3 result = (b * w + d * w + f * w + h * w + e) / (1.0 + 4.0 * w);
    return float4(saturate(result), 1.0);
}
