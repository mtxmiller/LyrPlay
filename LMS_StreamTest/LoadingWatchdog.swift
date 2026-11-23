// File: LoadingWatchdog.swift
// The "Loading Material Interface" screen has no buttons, and only a WebView
// callback (commit, failure) takes it down. A load that never produces one left
// it up until a force-quit (bd f9r0, 2026-11-21: after a flight, music playing,
// server reachable). The watchdog bounds that time; it counts only seconds the
// phone screen is in front, so a CarPlay drive with the phone locked never trips it.

import Foundation

enum LoadingWatchdog {
    /// Show Retry / Settings on the loading screen.
    static let escapeAfter = 15
    /// Nothing in flight by now: load Material again, once.
    static let freshLoadAfter = 20
    /// Give up: show the can't-connect screen (its buttons, the saved-music offer).
    static let giveUpAfter = 60
    /// After giving up, the can't-connect screen stays this long before a live
    /// server brings Material back by itself (Settings or Retry act at once).
    static let retryAfterGiveUp: TimeInterval = 30

    enum Action: Equatable {
        case none
        case showEscape
        case freshLoad
        case giveUp
    }

    /// One decision per second of loading screen in front of the user.
    /// - Parameters:
    ///   - seconds: seconds the loading screen has been visible with the phone screen active
    ///   - webViewBusy: the WKWebView reports a load in flight
    ///   - retried: the fresh load already ran for this loading screen
    ///   - escapeShown: Retry / Settings already visible
    static func action(seconds: Int, webViewBusy: Bool, retried: Bool, escapeShown: Bool) -> Action {
        if seconds >= giveUpAfter { return .giveUp }
        // A slow page that is still arriving is left alone; only an idle web view
        // (the load ended without a callback, or never started) is reloaded.
        if seconds >= freshLoadAfter && !webViewBusy && !retried { return .freshLoad }
        if seconds >= escapeAfter && !escapeShown { return .showEscape }
        return .none
    }
}

/// What the WebView does when iOS kills its content process.
enum ContentProcessRecovery: Equatable {
    /// The view was taken off screen (can't-connect screen): nothing to do, a new
    /// one loads when Material is shown again.
    case ignore
    /// It has a page: reload it.
    case reload
    /// It never committed a page, so reload() would do nothing: load the URL.
    case freshLoad

    static func decide(dismantled: Bool, hasPage: Bool) -> ContentProcessRecovery {
        if dismantled { return .ignore }
        return hasPage ? .reload : .freshLoad
    }
}
