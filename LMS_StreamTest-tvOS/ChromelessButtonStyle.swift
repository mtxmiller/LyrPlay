import SwiftUI

/// `ButtonStyle` that emits ONLY the label — no system-provided background,
/// border, or focus card. Lets the parent view own the entire focused look
/// via `@FocusState` + manual `.scaleEffect` + `.shadow`.
///
/// Why this exists: tvOS 26's `.buttonStyle(.plain)` STILL paints a system
/// focus highlight (a rounded-rect card on tiles, a capsule pill around
/// circle buttons) even with `.focusEffectDisabled()` applied — the chrome
/// comes from the style's own renderer, not the focus-effect machinery. A
/// custom style returning `configuration.label` is the only way to fully
/// suppress it.
///
/// Used by:
///   - `MediaTile` (Library home-extra shelves)
///   - `CircleFocusButton` (Now Playing transport row)
struct ChromelessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Subtle press-down feedback when the Siri Remote select button
            // is held. Matches the press affordance of native tvOS controls
            // without painting any background.
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}
