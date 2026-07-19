// File: VisualizerPreset.swift
// The 4 visualizer presets the tvOS user can cycle through via click-pad LEFT/RIGHT.
// Pure-Foundation enum so it lives in the shared target (target membership: iOS + tvOS)
// and is unit-testable alongside VisualizerEngine. iOS imports but ignores it — the
// visualizer itself is tvOS-only.
//
// Raw values are persisted as Int via @AppStorage("lyrplay_visualizer_preset");
// changing or reordering existing cases would break persistence for upgraders. Add
// new presets at the END; never renumber.
import Foundation

// IMPORTANT: rawValue is sent as an `int preset` uniform to bar_fragment in
// LMS_StreamTest-tvOS/VisualizerBarShader.metal. The shader's switch case
// numbers MUST match these rawValues exactly. If you reorder or renumber any
// case here, update the shader switch in lockstep — a mismatch produces
// visually-wrong-preset bugs (e.g. swiping to LED actually renders Winamp).
// Case 0 (bloom) uses a different pipeline state and never reaches bar_fragment.
enum VisualizerPreset: Int, CaseIterable {
    case bloom        = 0   // radial-bloom polar shader (default for new installs + upgrades)
    case ledHiFi      = 1   // green/amber/red stacked LED segments (Step 0 feel-checked on Apple TV 4K)
    case winamp       = 2   // continuous bars with yellow→orange→red gradient + falling peak caps
    case iTunesClean  = 3   // smooth rounded-top bars, single artwork-derived accent color

    /// User-facing name shown in the swap-name overlay (fades in for ~2s on cycle).
    var displayName: String {
        switch self {
        case .bloom:       return "Bloom"
        case .ledHiFi:     return "LED Hi-Fi"
        case .winamp:      return "Winamp"
        case .iTunesClean: return "iTunes"
        }
    }

    /// Cycle forward with wrap (iTunesClean → bloom). Drives click-pad RIGHT swipe.
    func next() -> VisualizerPreset {
        let all = VisualizerPreset.allCases
        let idx = (all.firstIndex(of: self) ?? 0) + 1
        return all[idx % all.count]
    }

    /// Cycle backward with wrap (bloom → iTunesClean). Drives click-pad LEFT swipe.
    func previous() -> VisualizerPreset {
        let all = VisualizerPreset.allCases
        let curr = all.firstIndex(of: self) ?? 0
        let idx = (curr + all.count - 1) % all.count
        return all[idx]
    }
}
