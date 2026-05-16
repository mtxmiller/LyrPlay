// VisualizerBarShader.metal
// Uber-shader for the 3 bar-style visualizer presets (LED hi-fi / Winamp / iTunes).
// Uniform `preset` selects which color treatment to apply on top of the shared
// bar geometry. Bloom keeps its own shader (VisualizerShaders.metal).
//
// Shares the vertex function `visualizer_vertex` from VisualizerShaders.metal at
// runtime via the renderer's pipeline descriptor — no vertex function is defined
// here. VertexOut is re-declared with the same layout so [[stage_in]] matches.
//
// Buffer bindings (matching renderer's setFragmentBuffer indices):
//   buffer 0: Uniforms (single struct, shared with bloom shader; preset field
//             added at the end — bloom ignores it, bar reads it)
//   buffer 1: bins  — VisualizerEngine output, bandCount floats, 0..~1 amplitude
//   buffer 2: peaks — PeakTracker output, bandCount floats. Used by Winamp only;
//                     LED + iTunes ignore the buffer (still bound by renderer for
//                     simpler unconditional binding logic)
//
// Coordinate convention: uv.y = 0 is screen BOTTOM, uv.y = 1 is screen TOP
// (matches Metal NDC y-up as produced by visualizer_vertex). Bars fill from
// the bottom up to barHeight. Verified on Apple TV 4K in Step 0 throwaway.
//
// All tunables are baked as `constant` per design E4 — no runtime sliders in
// v1. Re-tune = edit file + rebuild + redeploy.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float3 accentColor;     // used by iTunes preset only (artwork-derived RGB 0..1)
    float  time;            // not used by bar shaders (animation drives via bins)
    float  aspect;          // not used by bar shaders (bars are axis-aligned)
    int    binCount;        // shared with bloom
    int    preset;          // matches VisualizerPreset.rawValue: 0=bloom (never reaches
                            // this shader, bloom has its own pipeline), 1=ledHiFi,
                            // 2=winamp, 3=iTunesClean
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Shared geometry / tuning constants (per design E4 — hardcoded, not user-tunable in v1).
constant float kBarGapRatio    = 0.15;   // % of bar slot that's gap on the right edge
constant int   kLEDSegments    = 16;     // vertical LED segments per bar
constant float kSegGapRatio    = 0.10;   // % of LED segment height that's gap at top
constant int   kGreenMaxSeg    = 7;      // LED segs 0..7 are green (bottom 50%)
constant int   kYellowMaxSeg   = 11;     // LED segs 8..11 amber (next 25%); 12..15 red (top 25%)
constant float kPeakCapHeight  = 0.012;  // Winamp peak cap thickness in UV (≈13px @ 1080p)
constant float kITunesTopSoft  = 0.025;  // iTunes rounded-top anti-alias band

// LED preset colors
constant float3 kLEDGreen  = float3(0.05, 0.95, 0.15);
constant float3 kLEDAmber  = float3(0.95, 0.85, 0.05);
constant float3 kLEDRed    = float3(0.95, 0.15, 0.05);

// Winamp gradient stops + peak cap color. Authentic Winamp was green-dominated
// (bars sat mostly in the green zone, hit yellow on louder transients, red only
// on the very top). Gradient runs across the full screen so short bars stay
// green and tall bars reach into yellow/red naturally.
constant float3 kWAGreen   = float3(0.05, 0.95, 0.15);
constant float3 kWAYellow  = float3(0.95, 0.85, 0.05);
constant float3 kWARed     = float3(0.95, 0.05, 0.05);
constant float3 kWAPeakCap = float3(0.95, 0.95, 0.85);  // whitish for contrast on the gradient


// Helper: which bar slot does this fragment live in?
inline int barIndex(float uvX, int binCount) {
    int idx = int(uvX * float(binCount));
    if (idx < 0) idx = 0;
    if (idx >= binCount) idx = binCount - 1;
    return idx;
}

inline float4 ledHiFiColor(float uvY, float barHeight) {
    // Above bar amplitude → black
    if (uvY >= barHeight) return float4(0.0, 0.0, 0.0, 1.0);

    float segHeight = 1.0 / float(kLEDSegments);
    int   segIdx = int(uvY / segHeight);
    if (segIdx < 0) segIdx = 0;
    if (segIdx >= kLEDSegments) segIdx = kLEDSegments - 1;
    float segFrac = fract(uvY / segHeight);

    // Inter-segment gap at top of each segment → black
    if (segFrac > (1.0 - kSegGapRatio)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    if (segIdx <= kGreenMaxSeg)  return float4(kLEDGreen,  1.0);
    if (segIdx <= kYellowMaxSeg) return float4(kLEDAmber,  1.0);
    return float4(kLEDRed, 1.0);
}

inline float4 winampColor(float uvY, float barHeight, float peakHeight) {
    // Peak cap takes priority — it floats ABOVE current bar amplitude, so without
    // checking it first the "above bar → black" path would paint over it.
    if (peakHeight > 0.0 &&
        uvY >= (peakHeight - kPeakCapHeight) &&
        uvY < peakHeight) {
        return float4(kWAPeakCap, 1.0);
    }

    // Above bar amplitude → black
    if (uvY >= barHeight) return float4(0.0, 0.0, 0.0, 1.0);

    // Vertical gradient: green (bottom) → yellow (middle) → red (top of bar).
    // Gradient runs over full uv.y range, not over barHeight, so a short bar
    // stays in the green zone and only loud peaks reach yellow / red — matches
    // the classic Winamp aesthetic where most music sat in green.
    float t = uvY;
    float3 color;
    if (t < 0.5) {
        color = mix(kWAGreen, kWAYellow, t * 2.0);
    } else {
        color = mix(kWAYellow, kWARed, (t - 0.5) * 2.0);
    }
    return float4(color, 1.0);
}

inline float4 iTunesCleanColor(float uvY, float barHeight, float3 accent) {
    // Above bar amplitude → black
    if (uvY >= barHeight) return float4(0.0, 0.0, 0.0, 1.0);

    // Rounded-top anti-alias: within the top ~2.5% of the bar's amplitude, fade
    // to black via smoothstep. Gives the bar tip a soft edge instead of a hard
    // pixel rectangle. Simple vertical softness (not elliptical) — good enough
    // for v1; revisit if it feels too "candle flame" shaped.
    float topDistance = barHeight - uvY;          // 0 at top, increases going down
    float alpha = smoothstep(0.0, kITunesTopSoft, topDistance);

    return float4(accent * alpha, 1.0);
}


fragment float4 bar_fragment(VertexOut in [[stage_in]],
                              constant Uniforms &u     [[buffer(0)]],
                              constant float   *bins   [[buffer(1)]],
                              constant float   *peaks  [[buffer(2)]]) {
    float2 uv = in.uv;

    // 1. Which bar slot are we in?
    int   barIdx = barIndex(uv.x, u.binCount);
    float fracX  = fract(uv.x * float(u.binCount));

    // 2. Inter-bar gap on the right edge of each slot → black.
    if (fracX > (1.0 - kBarGapRatio)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // 3. Sample this bar's amplitude (clamped to display range).
    float barHeight = clamp(bins[barIdx], 0.0, 1.0);

    // 4. Branch on preset — fully coherent across fragments (uniform-driven), so
    //    SIMD divergence is zero. Cost is one extra register and a branch.
    //    Case numbers MUST match VisualizerPreset.rawValue exactly to avoid the
    //    off-by-one bug where .ledHiFi (rawValue=1) was wrongly hitting Winamp.
    //    Case 0 (bloom) is dead code here — bloom uses its own pipeline state and
    //    never reaches bar_fragment — but listing it keeps the shader's switch
    //    1:1 with the enum and resilient to future enum additions.
    switch (u.preset) {
        case 1:  return ledHiFiColor(uv.y, barHeight);
        case 2:  return winampColor(uv.y, barHeight, clamp(peaks[barIdx], 0.0, 1.0));
        case 3:  return iTunesCleanColor(uv.y, barHeight, u.accentColor);
        default: return float4(0.0, 0.0, 0.0, 1.0);  // bloom (0) or unknown → black (defensive)
    }
}
