#include <metal_stdlib>
using namespace metal;

// Mirrors `ColorParams` in Renderer.swift.
struct ColorParams {
    float4 uvRect;        // xy = origin, zw = size of the sampled source region (Fill crops)
    float4 range;         // x = luma offset, y = luma scale, z = chroma scale
    float4 coefficients;  // x = Kr, y = Kb
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

// One oversized triangle covering the viewport; uv (0,0) is the top-left of the image.
vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

static float3 ycbcrToRGB(float y, float cb, float cr, constant ColorParams &p) {
    float luma = (y - p.range.x) * p.range.y;
    float u = (cb - 128.0 / 255.0) * p.range.z;
    float v = (cr - 128.0 / 255.0) * p.range.z;
    float kr = p.coefficients.x;
    float kb = p.coefficients.y;
    float r = luma + 2.0 * (1.0 - kr) * v;
    float b = luma + 2.0 * (1.0 - kb) * u;
    float g = (luma - kr * r - kb * b) / (1.0 - kr - kb);
    return saturate(float3(r, g, b));
}

// 420v / 420f: plane 0 = Y' (r8), plane 1 = CbCr (rg8).
fragment float4 biplanarFragment(VertexOut in [[stage_in]],
                                 texture2d<float> lumaTex [[texture(0)]],
                                 texture2d<float> chromaTex [[texture(1)]],
                                 constant ColorParams &p [[buffer(0)]]) {
    float2 uv = p.uvRect.xy + in.uv * p.uvRect.zw;
    float y = lumaTex.sample(linearClamp, uv).r;
    float2 c = chromaTex.sample(linearClamp, uv).rg;
    return float4(ycbcrToRGB(y, c.x, c.y, p), 1.0);
}

// YUY2 (gbgr422) / UYVY (bgrg422): the GPU unpacks 4:2:2 so g = Y', b = Cb, r = Cr.
fragment float4 packed422Fragment(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant ColorParams &p [[buffer(0)]]) {
    float2 uv = p.uvRect.xy + in.uv * p.uvRect.zw;
    float4 t = tex.sample(linearClamp, uv);
    return float4(ycbcrToRGB(t.g, t.b, t.r, p), 1.0);
}

// MARK: - Upscaling

constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge);

static float lanczos3(float x) {
    x = abs(x);
    if (x < 1e-5) return 1.0;
    if (x >= 3.0) return 0.0;
    float px = M_PI_F * x;
    return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
}

// Separable Lanczos-3, horizontal half: source → (output width × source height).
// Each result is clamped to its two nearest source pixels so edges don't ring (no halos on HUD text).
fragment float4 lanczosHorizontal(VertexOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    int w = src.get_width();
    int h = src.get_height();
    int row = clamp(int(in.uv.y * h), 0, h - 1);
    float x = in.uv.x * w - 0.5;
    float fx = floor(x);
    int base = int(fx);
    float f = x - fx;

    float4 sum = 0.0, lo = 0.0, hi = 0.0;
    float weights = 0.0;
    for (int i = -2; i <= 3; i++) {
        float wgt = lanczos3(float(i) - f);
        float4 c = src.read(uint2(clamp(base + i, 0, w - 1), row));
        sum += c * wgt;
        weights += wgt;
        if (i == 0) lo = hi = c;
        if (i == 1) { lo = min(lo, c); hi = max(hi, c); }
    }
    return clamp(sum / weights, lo, hi);
}

// Vertical half: (output width × source height) → the video area of the drawable.
fragment float4 lanczosVertical(VertexOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    int w = src.get_width();
    int h = src.get_height();
    int col = clamp(int(in.uv.x * w), 0, w - 1);
    float y = in.uv.y * h - 0.5;
    float fy = floor(y);
    int base = int(fy);
    float f = y - fy;

    float4 sum = 0.0, lo = 0.0, hi = 0.0;
    float weights = 0.0;
    for (int i = -2; i <= 3; i++) {
        float wgt = lanczos3(float(i) - f);
        float4 c = src.read(uint2(col, clamp(base + i, 0, h - 1)));
        sum += c * wgt;
        weights += wgt;
        if (i == 0) lo = hi = c;
        if (i == 1) { lo = min(lo, c); hi = max(hi, c); }
    }
    return float4(clamp(sum / weights, lo, hi).rgb, 1.0);
}

// 1:1 copy of an already-scaled texture into the video area.
fragment float4 copyFragment(VertexOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return float4(src.sample(nearestClamp, in.uv).rgb, 1.0);
}

// MARK: - Frame generation input

// The interpolator only takes 420v, so 4:2:2 captures are repacked on the GPU first.
// Values stay in video range; no colour conversion happens here.
fragment float4 packedToLuma(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return float4(tex.sample(linearClamp, in.uv).g);
}

fragment float4 packedToChroma(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    float4 t = tex.sample(linearClamp, in.uv);
    return float4(t.b, t.r, 0.0, 0.0);
}

// Scales one 420v plane (Y' as r8 or CbCr as rg8) into a smaller interpolator buffer.
fragment float4 resampleFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return tex.sample(linearClamp, in.uv);
}

// MARK: - Frame generation: still-pixel lock

struct StillParams {
    float tolerance;  // largest luma change that still counts as "didn't move"
    float step;       // 1 / real frames a pixel must hold still before it is locked
};

// How long each pixel has held still: counts up while the two newest real frames agree, and
// starts again from zero the moment they don't.
fragment float4 stillnessFragment(VertexOut in [[stage_in]],
                                  texture2d<float> current [[texture(0)]],
                                  texture2d<float> previous [[texture(1)]],
                                  texture2d<float> history [[texture(2)]],
                                  constant StillParams &p [[buffer(0)]]) {
    float change = abs(current.sample(nearestClamp, in.uv).r - previous.sample(nearestClamp, in.uv).r);
    float held = history.sample(nearestClamp, in.uv).r;
    return float4(change <= p.tolerance ? min(held + p.step, 1.0) : 0.0);
}

// One plane of the in-between frame: pixels that have held still (HUD, text, a fixed camera) come
// straight from the real frame; everything else from the generated one, scaled up if it is smaller.
// For the half-size chroma plane the linear sample only passes when all four luma pixels are still.
fragment float4 lockStillFragment(VertexOut in [[stage_in]],
                                  texture2d<float> generated [[texture(0)]],
                                  texture2d<float> real [[texture(1)]],
                                  texture2d<float> stillness [[texture(2)]]) {
    float held = stillness.sample(linearClamp, in.uv).r;
    return held > 0.99 ? real.sample(nearestClamp, in.uv) : generated.sample(linearClamp, in.uv);
}

// MARK: - Latency test marker

fragment float4 solidFragment(VertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
}
