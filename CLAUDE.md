# CLAUDE.md

## Project Identity

**LyrPlay** is an iOS SwiftUI app that implements a SlimProto client for streaming audio from Logitech Media Server (LMS). It's essentially a **Swift version of squeezelite** — a Squeezebox player replacement with native FLAC support, CarPlay, Siri, and gapless playback.

- **App Store**: v1.7.6 live, v1.7.7 in development (build 14)
- **Bundle ID**: `elm.LMS-StreamTest` (preserved for App Store continuity — never change this)
- **Display Name**: LyrPlay
- **Local Folder**: `LMS_StreamTest` (intentional — don't rename)
- **GitHub**: https://github.com/mtxmiller/LyrPlay
- **Deployment Target**: iOS 15.6+ (affects which APIs are available)

## Build Commands

```bash
pod install                          # Install dependencies (required after clone)
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -configuration Debug build
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest clean
```

**Always use `LMS_StreamTest.xcworkspace`**, never `.xcodeproj` (CocoaPods requirement). Testing is manual.

## Issue Tracking

This project uses [bd (beads)](https://github.com/steveyegge/beads) for issue tracking. Use `bd` commands, not markdown TODOs. Run `bd ready --json` for available work, `bd create "title" -t bug|feature|task -p 0-4 --json` to file issues, `bd close <id>` to complete.

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

## Known Limitations

- **FLAC seeking** — Non-functional with BASS push stream architecture. MP3, AAC, Opus, OGG, WAV seeking works. Mitigation: [MobileTranscode](https://github.com/mtxmiller/MobileTranscode) LMS plugin provides server-side transcode rules for mobile clients — converts FLAC to seekable formats (AAC, MP3) and re-encodes FLAC with proper headers that enable seeking.
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

## Current Work (v1.7.7)

1. **Gapless Playback Refinement** — Fixing premature CarPlay/server UI sync during transitions
2. **Stream Info Overlay** — Hardware output rate display and decoder throttle improvements
3. **Auto-Reconnect** — Automatic retry on server restart (5-second intervals)

## Deep Documentation

Architecture docs, release history, and decision records live in the Obsidian wiki:
`/Users/ericmiller/Library/Mobile Documents/iCloud~md~obsidian/Documents/Eric's personal/LyrPlay Dev/`

Sections: `Architecture/` (Audio Pipeline, CarPlay, Gapless, Position Recovery, SlimProto, etc.), `Releases/` (v1.4–v1.7.7), `Decisions/`

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
