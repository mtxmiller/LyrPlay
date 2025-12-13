//
//  AppIconManager.swift
//  LyrPlay
//
//  Created by Claude Code on 12/11/25.
//  Manages alternate app icon switching with IAP validation
//

import UIKit
import OSLog

/// Manages app icon switching functionality
/// Requires Icon Pack purchase ($2.99) to unlock alternate icons
class AppIconManager: ObservableObject {

    // MARK: - Singleton

    static let shared = AppIconManager()

    // MARK: - Icon Definitions

    enum AppIcon: String, CaseIterable, Identifiable {
        case `default` = "Default"
        case gradientShine = "AppIcon-GradientShine"
        case hiFi = "AppIcon-HiFi"
        case monochrome = "AppIcon-Monochrome"
        case neon = "AppIcon-Neon"
        case outrun = "AppIcon-Outrun"
        case red = "AppIcon-Red"
        case retrowave = "AppIcon-Retrowave"
        case reverseOut = "AppIcon-ReverseOut"
        case white = "AppIcon-White"
        case wordmarkWhite = "AppIcon-WordmarkWhite"
        case wordmark = "AppIcon-Wordmark"

        var id: String { rawValue }

        /// Display name shown in UI
        var displayName: String {
            switch self {
            case .default: return "Default"
            case .gradientShine: return "Gradient Shine"
            case .hiFi: return "Hi-Fi"
            case .monochrome: return "Monochrome"
            case .neon: return "Neon"
            case .outrun: return "Outrun" // Retro wave! 🌆
            case .red: return "Red"
            case .retrowave: return "Retrowave" // Retro wave! 🎵
            case .reverseOut: return "Reverse Out"
            case .white: return "White"
            case .wordmarkWhite: return "Wordmark White"
            case .wordmark: return "Wordmark"
            }
        }

        /// Description for the icon
        var description: String {
            switch self {
            case .default: return "Classic LyrPlay icon"
            case .gradientShine: return "Glossy gradient design"
            case .hiFi: return "Audiophile inspired"
            case .monochrome: return "Minimalist single color"
            case .neon: return "Vibrant neon glow"
            case .outrun: return "80s synthwave aesthetic"
            case .red: return "Bold red theme"
            case .retrowave: return "Retro wave fantasy"
            case .reverseOut: return "Dark mode optimized"
            case .white: return "Clean white design"
            case .wordmarkWhite: return "White with LyrPlay text"
            case .wordmark: return "Full wordmark logo"
            }
        }

        /// Preview image name (matches asset catalog name)
        var previewImageName: String {
            rawValue == "Default" ? "AppIconPreview" : "\(rawValue)Preview"
        }

        /// Value to pass to UIApplication.setAlternateIconName()
        var alternateIconName: String? {
            self == .default ? nil : rawValue
        }
    }

    // MARK: - Published State

    @Published private(set) var currentIcon: AppIcon = .default

    // MARK: - Properties

    private let logger = OSLog(subsystem: "com.lmsstream", category: "AppIconManager")
    private let selectedIconKey = "lyrplay_selected_app_icon"

    // MARK: - Initialization

    private init() {
        loadSelectedIcon()
    }

    // MARK: - Current Icon

    /// Get the currently active app icon
    private func loadSelectedIcon() {
        if let iconName = UIApplication.shared.alternateIconName {
            currentIcon = AppIcon.allCases.first { $0.rawValue == iconName } ?? .default
        } else {
            currentIcon = .default
        }

        os_log(.debug, log: logger, "📱 Current icon: %{public}s", currentIcon.displayName)
    }

    // MARK: - Icon Switching

    /// Switch to a different app icon
    /// - Parameter icon: The icon to switch to
    /// - Throws: Error if icon switching fails or IAP not purchased
    func setIcon(_ icon: AppIcon) async throws {
        // Check if Icon Pack is unlocked (except for default icon)
        let hasIconPack = await PurchaseManager.shared.hasIconPack
        if icon != .default && !hasIconPack {
            os_log(.error, log: logger, "🔒 Icon Pack not purchased - cannot switch to %{public}s", icon.displayName)
            throw AppIconError.iconPackNotPurchased
        }

        // Check if alternate icons are supported
        guard UIApplication.shared.supportsAlternateIcons else {
            os_log(.error, log: logger, "❌ Alternate icons not supported on this device")
            throw AppIconError.notSupported
        }

        // Switch icon
        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)

            // Update current icon
            await MainActor.run {
                self.currentIcon = icon
            }

            // Persist selection
            UserDefaults.standard.set(icon.rawValue, forKey: selectedIconKey)

            os_log(.info, log: logger, "✅ Switched to icon: %{public}s", icon.displayName)

        } catch {
            os_log(.error, log: logger, "❌ Failed to switch icon: %{public}s", error.localizedDescription)
            throw AppIconError.switchFailed(error)
        }
    }

    /// Restore previously selected icon (call on app launch after purchase restore)
    func restoreSelectedIcon() async {
        let hasIconPack = await PurchaseManager.shared.hasIconPack
        guard hasIconPack else {
            os_log(.debug, log: logger, "ℹ️ Icon Pack not purchased - staying on default")
            return
        }

        if let savedIconRawValue = UserDefaults.standard.string(forKey: selectedIconKey),
           let savedIcon = AppIcon.allCases.first(where: { $0.rawValue == savedIconRawValue }),
           savedIcon != currentIcon {

            do {
                try await setIcon(savedIcon)
                os_log(.info, log: logger, "🔄 Restored icon: %{public}s", savedIcon.displayName)
            } catch {
                os_log(.error, log: logger, "❌ Failed to restore icon: %{public}s", error.localizedDescription)
            }
        }
    }
}

// MARK: - Errors

enum AppIconError: LocalizedError {
    case iconPackNotPurchased
    case notSupported
    case switchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .iconPackNotPurchased:
            return "Icon Pack not purchased. Unlock premium icons for $2.99 to customize your app icon."
        case .notSupported:
            return "Alternate app icons are not supported on this device."
        case .switchFailed(let error):
            return "Failed to switch app icon: \(error.localizedDescription)"
        }
    }
}
