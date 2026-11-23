import Testing
@testable import LMS_StreamTest

/// bd f9r0: the loading screen stayed up after a flight until a force-quit.
struct LoadingWatchdogTests {

    @Test func aNormalLoadIsLeftAlone() {
        #expect(LoadingWatchdog.action(seconds: 5, webViewBusy: true, retried: false, escapeShown: false) == .none)
    }

    @Test func retryAndSettingsAppearAfterFifteenSeconds() {
        #expect(LoadingWatchdog.action(seconds: 15, webViewBusy: true, retried: false, escapeShown: false) == .showEscape)
        #expect(LoadingWatchdog.action(seconds: 16, webViewBusy: true, retried: false, escapeShown: true) == .none)
    }

    @Test func anIdleWebViewIsLoadedAgainOnce() {
        #expect(LoadingWatchdog.action(seconds: 20, webViewBusy: false, retried: false, escapeShown: true) == .freshLoad)
        #expect(LoadingWatchdog.action(seconds: 21, webViewBusy: false, retried: true, escapeShown: true) == .none)
    }

    @Test func aSlowLoadStillArrivingIsNotRestarted() {
        #expect(LoadingWatchdog.action(seconds: 40, webViewBusy: true, retried: false, escapeShown: true) == .none)
    }

    @Test func afterSixtySecondsTheCantConnectScreenShows() {
        #expect(LoadingWatchdog.action(seconds: 60, webViewBusy: true, retried: false, escapeShown: true) == .giveUp)
        #expect(LoadingWatchdog.action(seconds: 60, webViewBusy: false, retried: true, escapeShown: true) == .giveUp)
    }

    @Test func anOffScreenWebViewDoesNothingWhenItsProcessEnds() {
        #expect(ContentProcessRecovery.decide(dismantled: true, hasPage: true) == .ignore)
        #expect(ContentProcessRecovery.decide(dismantled: true, hasPage: false) == .ignore)
    }

    @Test func aWebViewWithAPageReloadsIt() {
        #expect(ContentProcessRecovery.decide(dismantled: false, hasPage: true) == .reload)
    }

    @Test func aWebViewThatNeverLoadedAPageLoadsTheURL() {
        // reload() returns nil then, and the loading screen would stay up.
        #expect(ContentProcessRecovery.decide(dismantled: false, hasPage: false) == .freshLoad)
    }
}
