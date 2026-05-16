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

enum VisualizerPreset: Int, CaseIterable {
    case bloom        = 0   // current radial-bloom polar shader (default for new installs + upgrades)
    case ledHiFi      = 1   // green/yellow/red stacked LED segments (Step 0 feel-checked PASS on Apple TV 4K)
    case winamp       = 2   // continuous bars with vertical gradient + falling peak caps
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
