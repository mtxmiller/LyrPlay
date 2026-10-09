# CLAUDE.md

## Project Identity

**LyrPlay** is an iOS SwiftUI app that implements a SlimProto client for streaming audio from Logitech Media Server (LMS). It's essentially a **Swift version of squeezelite** — a Squeezebox player replacement with native FLAC support, CarPlay, Siri, and gapless playback.

- **Version state**: build/version live in `LMS_StreamTest.xcodeproj/project.pbxproj` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). Per-release status (in dev / submitted / live) tracked in the wiki under `wiki/Releases/`.
- **Bundle ID**: `elm.LMS-StreamTest` (preserved for App Store continuity — never change this)
- **Display Name**: LyrPlay
- **Local Folder**: `LMS_StreamTest` (intentional — don't rename)
- **GitHub**: https://github.com/mtxmiller/LyrPlay
- **Deployment Target**: iOS 15.6+ (affects which APIs are available)

## Build Commands

```bash
# Pods/ is committed — run `pod install` only after changing the Podfile (CocoaPods may not be installed)
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -configuration Debug build
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest clean
```

**Always use `LMS_StreamTest.xcworkspace`**, never `.xcodeproj` (CocoaPods requirement).

Xcode 27: tvOS builds need the Metal Toolchain for the visualizer shaders (`xcodebuild -downloadComponent MetalToolchain`).

For the CLI build → install → launch loop on a connected iPhone, see the wiki at `Setup/iPhone Build Workflow.md`. Personal device IDs are kept in user-local Claude memory, not committed.

**Test LMS server**: `192.168.1.8` (default ports — 9000 JSON-RPC, 3483 SlimProto) is available on-network for debugging and exercising new features.

## Testing & Verification

Unit test targets exist on both platforms (Swift Testing + XCTest). Run them before claiming a change works:

```bash
# tvOS — use -only-testing: the UITests runner has a known dlopen failure (bd LMS_StreamTest-39m)
xcodebuild test -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest-tvOS \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -only-testing:LMS_StreamTest-tvOSTests

# iOS — device name must exist on the LATEST installed iOS runtime
# (xcodebuild implies OS:latest; a name that only exists on an older runtime
# fails with "Unable to find a device matching"). Check: xcrun simctl list devices available
xcodebuild test -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LMS_StreamTestTests
```

The full unit suites pass on both platforms. If a test fails, investigate — don't pre-attribute it to a known-failing list.

Changes to shared files (`LMS_StreamTest/*.swift` compiled into both targets) must be verified on **both** platforms.

**Server-as-oracle verification**: LyrPlay is a client of an observable server — playback health is machine-checkable over JSON-RPC against the test LMS, no listening required. A healthy pipeline shows: player present in `serverstatus`, `mode == play`, `time` advancing at ~1x wall clock, `playlist_cur_index` changing at expected track boundaries (not early/late). Use these signals to verify playback-adjacent changes end-to-end. Full scenario catalog + assertion library spec: `scripts/smoke/README.md` (implementation tracked in bd epic `LMS_StreamTest-6b1`).

**Still human-only**: audible quality (gapless seams, audio bursts, clicks), CarPlay hardware behavior, real phone-call interruptions, lock-screen timing. Don't claim these verified from a simulator.

**Autonomous pilot loop**: `/pilot` (`.claude/commands/pilot.md`) runs one bd-issue → draft-PR iteration scoped to tvOS/UI work (audio pipeline and recovery files are off-limits to it); `/loop /pilot` keeps it running. It never merges, never closes bd issues, and caps at 3 open draft PRs.

## Issue Tracking

This project uses [bd (beads)](https://github.com/steveyegge/beads) for issue tracking. Use `bd` commands, not markdown TODOs. Run `bd ready --json` for available work, `bd create "title" -t bug|feature|task -p 0-4 --json` to file issues, `bd close <id>` to complete.

## Commits & PRs

**No Claude attribution** — no `Co-Authored-By: Claude` trailer, no `Claude-Session:` link, no "Generated with Claude Code" footer in commits, PR descriptions, GitHub comments, or release notes.

## Critical Rules

1. **NO ASSUMPTIONS** — Verify everything against the code and reference repos. Use adversarial review when making changes to critical systems (audio pipeline, SlimProto, recovery).
2. **Never manually manage AVAudioSession** — BASS handles all session lifecycle via `BASS_CONFIG_IOS_SESSION`. Manual management causes silent audio failures and conflicts.
3. **Never add an Intents Extension for Siri** — INPlayMediaIntent is handled in the main app via `SiriMediaHandler` in AppDelegate. This is an App Store validation constraint.
4. **Never simplify playlist jump recovery to a simple seek** — Playlist jump is atomic (track index + time offset). Simple seek breaks when the playlist position has changed during backgrounding. Always use noplay=0 (start playing), then pause in callback if needed — noplay=1 breaks position recovery after server timeout.
5. **Never change the bundle ID** — `elm.LMS-StreamTest` is locked for App Store continuity.
6. **Don't add logic to InterruptionManager** — It's a legacy stub. All interruption handling lives in `PlaybackSessionController`.
7. **Don't refactor singletons** — `AudioManager.shared` and `SettingsManager.shared` are singletons by design. CarPlay and main app share the same instances.
8. **Never create a new SlimProtoCoordinator when one exists** — CarPlay and main app share the same coordinator via `AudioManager.shared`. Creating a second one stops playback. See `ContentView.init()` for the reuse pattern.
9. **The 45-second background threshold** governs recovery strategy (quick resume vs full reconnect). Test both paths if changing it.
10. **BASS error checking** — Most BASS functions return 0/FALSE on failure. Call `BASS_ErrorGetCode()` immediately after — errors are thread-local and get overwritten by the next BASS call. BASS callbacks run on arbitrary threads — always marshal to main thread with `DispatchQueue.main.async`.
11. **ICY metadata requires duration > 0** — Sending ICY metadata for infinite streams (radio, duration=0) crashes the LMS server. Always check duration before sending.
12. **Silent recovery muting** — When recovering from backgrounding without playing (app-open recovery), mute BEFORE the stream is created via `enableSilentRecoveryMode()`. Late muting causes audio bursts.

## Architecture & Key Files

### Entry Points
- `SlimProtoCoordinator.swift` — Main orchestrator. Start here.
- `AppDelegate.swift` — Scene routing (CarPlay) and Siri handler
- `ContentView.swift` — Main SwiftUI view with Material WebView

### Audio Pipeline
- `AudioPlayer.swift` — BASS integration, push stream logic, gapless transitions
- `AudioManager.swift` — Singleton coordinating audio components
- `PlaybackSessionController.swift` — Interruptions, remote commands, CarPlay/lock screen commands, position saving

### SlimProto & Networking
- `SlimProtoClient.swift` — Binary protocol over TCP (CocoaAsyncSocket). Big-endian network byte order. Messages: 2-byte length prefix + 4-char command tag.
- `SlimProtoCommandHandler.swift` — Command processing (STRM, STAT, SETD, etc.)
- `SlimProtoConnectionManager.swift` — Connection state, retry logic

### Two Communication Channels with LMS
1. **SlimProto (binary TCP)**: Player registration, streaming commands, STAT responses — persistent connection
2. **JSON-RPC (HTTP)**: Metadata queries, playlist operations, browse commands — stateless requests. Don't mix these up.

### Push Stream Data Flow (Gapless)
Network data → `SlimProtoCommandHandler` → `AudioPlayer.pushStreamProc` (BASS push stream buffer) → BASS pulls and decodes → sync callback fires at track boundary → next track loads. Write position tracking drives boundary detection.

### Playlist Jump Recovery
Atomic track+position recovery via JSON-RPC `playlist jump` with `timeOffset`. Used for all reconnection scenarios (lock screen, CarPlay, backgrounding). Position saved to UserDefaults on pause, route change, disconnect, and backgrounding. See `performPlaylistRecovery()` in `SlimProtoCoordinator.swift`.

### CarPlay & UI
- `CarPlaySceneDelegate.swift` — CarPlay UI (CPTemplateApplicationSceneDelegate)
- `NowPlayingManager.swift` — Lock screen / Control Center metadata
- `SettingsView.swift` / `SettingsManager.swift` — Configuration

## Coding Patterns

- **Logging**: OSLog with subsystem `"com.lmsstream"` — not `print()`, not `Logger`
- **State**: `@Published` properties on `ObservableObject` conforming managers for SwiftUI reactivity
- **New features**: Route through `SlimProtoCoordinator`, not direct component access
- **Error handling**: Handle with recovery — this is a production app with real users. Don't just log errors.
- **Audio formats**: FLAC, WAV, AAC, MP4A, MP3, Opus, OGG via BASS xcframeworks + bridging header
- **IAP**: `PurchaseManager.swift` has StoreKit 2 with an icon pack product. Don't gate features behind IAP without explicit direction.
- **Server requests**: build URLs with `settings.buildURLString(path:)` / `absoluteServerURL(_:)` (never hardcode `http://`) and send them through `URLSession.lms` (never `URLSession.shared`) so HTTPS and self-signed certificates work. See wiki `Architecture/HTTPS & Connections.md`.
- **SwiftUI**: never read UIKit window/scene state (`UIWindow.safeAreaInsets`, `UIApplication.shared.connectedScenes`) inside `body` or properties it uses — it causes AttributeGraph cycles that freeze the view (the "stuck on Loading Material Interface" hang, twice). Use GeometryReader / environment values. Debug suspected cycles with `AG_TRAP_CYCLES=1`.

## Known Limitations

- **FLAC seeking** — Works with the BASS push-stream architecture (MP3, AAC, Opus, OGG, WAV also seek). FLAC files with incomplete headers may still misbehave; the [MobileTranscode](https://github.com/mtxmiller/MobileTranscode) LMS plugin re-encodes FLAC with proper headers or transcodes to Opus/AAC/MP3.
- **FLAC push stream data** — BASSFLAC 2.4.17.1 fixed `max_framesize=0` early termination via dedicated threading, but edge cases may remain.

## Reference Sources

We're building a Swift squeezelite. Always consult these when implementing or debugging:

| Task | Primary Reference |
|------|-------------------|
| SlimProto messages, HELO/STAT/STRm | `./squeezelite/slimproto.c` |
| Audio buffer, decode/output pipeline | `./squeezelite/output.c`, `decode.c` |
| Server-side playlist/streaming logic | `./slimserver/Slim/Player/Squeezebox.pm` |
| JSON-RPC API calls, browse patterns | `~/Downloads/lms-material/MaterialSkin/HTML/material/` |
| WebView JavaScript injection | `lms-material` JS APIs |
| BASS API functions and configs | `./docs/bass_documentation/` (HTML reference) |

## Current Work

For open work and what's in flight: run `bd ready` for the issue queue and read the latest `Releases/v1.7.X.md` in the wiki for the in-progress release's scope and status. Don't rely on a hardcoded "current work" list here — it rots.

## Deep Documentation

**Read the matching `Architecture/*.md` BEFORE grepping Swift source for any debug or design task in an architecture-touching area.** It gives you the trigger taxonomy, gating logic, and flow diagrams without having to reconstruct them.

The wiki is an Obsidian vault at `wiki/` in the main checkout. It is gitignored (private notes, never commit it), so it does not exist in worktrees — use the main checkout's absolute path there. Architecture topics: Audio Pipeline, CarPlay, Gapless Playback, Position Recovery, SlimProto Protocol, Material WebView Injection, Server Failover, Reconnection.

Also: `Releases/` for shipped-feature changelogs, `Decisions/` for architectural decision records.

## Skill routing

Skills are available for common workflows (e.g. `investigate` for bugs, `code-review` for reviews, `cut-build` for TestFlight builds). Use one when it clearly fits the request — don't force a skill onto a quick question or a simple push.

# Coding

- **Surgical changes**: every changed line should trace to the request. Don't refactor or reformat adjacent code; mention unrelated dead code instead of deleting it. Remove only what your change made unused.
- **Verify, don't assume**: for multi-step changes, state how each step will be verified (test, build on both platforms, or server-as-oracle check) and loop until it passes.
