// VisualizerShaders.metal
// Radial-bloom polar shader for the tvOS visualizer.
//
// Each fragment maps its angle (atan2 around screen center) to an FFT band.
// Band amplitude controls a "petal radius"; we render a soft Gaussian falloff
// around that radius, tinted by the artwork accent color. Time drives a slow
// rotation so the bloom rotates lazily even on stable bands.
//
// Renders at 1080p (drawableSize set in renderer); tvOS compositor upscales to
// the panel's native resolution. ~ MAD-bound on Apple TV 4K A12+.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3 accentColor;
    float  time;
    float  aspect;
    int    binCount;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle, no vertex buffer required.
// vertex_id 0,1,2 covers the entire screen via overdraw outside the viewport.
vertex VertexOut visualizer_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = (pos[vid] + 1.0) * 0.5;
    return out;
}

fragment float4 visualizer_fragment(VertexOut in [[stage_in]],
                                    constant Uniforms &u [[buffer(0)]],
                                    constant float *bins [[buffer(1)]]) {
    // Map [0,1] uv → [-1,+1] centered, correct for aspect so the bloom is round.
    float2 p = in.uv * 2.0 - 1.0;
    p.x *= u.aspect;

    float r = length(p);
    float angle = atan2(p.y, p.x);                 // -π..+π
    angle = angle + u.time * 0.05;                  // slow lazy rotation
    angle = fract(angle / (2.0 * M_PI_F) + 0.5);   // 0..1

    // Sample two adjacent bands, lerp for smooth angular interpolation.
    float bandF = angle * float(u.binCount);
    int   b0    = int(bandF) % u.binCount;
    int   b1    = (b0 + 1)   % u.binCount;
    float frac  = bandF - floor(bandF);
    float v     = mix(bins[b0], bins[b1], frac);

    // Petal radius pulses with band amplitude. Base 0.30, grows to 0.70 at peak.
    float petalR = 0.30 + clamp(v, 0.0, 1.0) * 0.40;

    // Gaussian ring around petal radius — sharp peak, soft tail.
    float ringDist  = r - petalR;
    float ring      = exp(-ringDist * ringDist * 32.0);

    // Inner bloom — soft glow from the center, modulated by overall energy.
    float core = exp(-r * r * 6.0) * (v * 0.6 + 0.08);

    // Outer halo — faint, gives the bloom presence even on quiet sections.
    float halo = exp(-r * r * 1.5) * 0.05;

    float intensity = ring * (0.6 + v * 0.8) + core + halo;
    intensity = clamp(intensity, 0.0, 1.4);

    // Tint with accent color; add a touch of white at the brightest core for highlight.
    float3 col = u.accentColor * intensity;
    col += float3(intensity * intensity * 0.15);

    return float4(col, 1.0);
}
