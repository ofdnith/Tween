#include <metal_stdlib>
using namespace metal;

// Mirrors `StreamQuadParams` in StreamCompositor.swift.
struct StreamQuadParams {
    float4 rect;     // x, y, width, height in canvas pixels, y from the top
    float4 uvRect;   // sampled region of the source: origin xy, size zw
    float4 canvas;   // x = canvas width, y = canvas height, z = corner radius in pixels
    float4 source;   // xy = source size in pixels
};

struct StreamVertexOut {
    float4 position [[position]];
    float2 uv;       // 0...1 across the quad, (0,0) top-left
};

constexpr sampler streamLinear(filter::linear, address::clamp_to_edge);

vertex StreamVertexOut streamQuadVertex(uint vid [[vertex_id]], constant StreamQuadParams &p [[buffer(0)]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    float2 pixel = p.rect.xy + corner * p.rect.zw;
    StreamVertexOut out;
    out.position = float4(pixel.x / p.canvas.x * 2.0 - 1.0, 1.0 - pixel.y / p.canvas.y * 2.0, 0.0, 1.0);
    out.uv = corner;
    return out;
}

// Plain bilinear above 0.75x; below that four taps spread over the source area one output pixel covers,
// so 4K text stays readable in 1080p.
fragment float4 streamScaleFragment(StreamVertexOut in [[stage_in]],
                                    constant StreamQuadParams &p [[buffer(0)]],
                                    texture2d<float> src [[texture(0)]]) {
    float2 uv = p.uvRect.xy + in.uv * p.uvRect.zw;
    float2 scale = p.rect.zw / (p.source.xy * p.uvRect.zw);
    float3 color;
    if (min(scale.x, scale.y) < 0.75) {
        float2 offset = 0.25 / (scale * p.source.xy);
        color = (src.sample(streamLinear, uv + float2(-offset.x, -offset.y)).rgb
               + src.sample(streamLinear, uv + float2(offset.x, -offset.y)).rgb
               + src.sample(streamLinear, uv + float2(-offset.x, offset.y)).rgb
               + src.sample(streamLinear, uv + float2(offset.x, offset.y)).rgb) * 0.25;
    } else {
        color = src.sample(streamLinear, uv).rgb;
    }
    float alpha = 1.0;
    float radius = p.canvas.z;
    if (radius > 0.0) {
        float2 halfSize = p.rect.zw * 0.5;
        float2 q = abs(in.uv * p.rect.zw - halfSize) - (halfSize - radius);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        alpha = saturate(0.5 - d);
    }
    return float4(color, alpha);
}
