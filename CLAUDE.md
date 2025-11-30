# CLAUDE.md

**Note**: This project uses [bd (beads)](https://github.com/steveyegge/beads)
for issue tracking. Use `bd` commands instead of markdown TODOs.
See AGENTS.md for workflow details.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**LyrPlay** (formerly LMS_StreamTest) is an iOS SwiftUI application that implements a SlimProto client for streaming audio from Logitech Media Server (LMS). The app acts as a Squeezebox player replacement, allowing iOS devices to connect to LMS instances and stream high-quality audio with native FLAC support.

### Current Status: **LIVE ON APP STORE** 🌟
- ✅ **Version 1.5 Live on App Store** - StreamingKit-based stable release with major stability improvements
- ✅ **Version 1.7 in TestFlight** - CarPlay Browse + External DAC support + WAV format + Enhanced gapless playback
- ✅ **CBass Audio Framework Migration COMPLETE** - Superior FLAC, Opus, and multi-format support with BASS auto-managed audio sessions
- ✅ **Gapless Playback** - True gapless transitions using BASS push stream architecture
- ✅ **CarPlay Support** - Phase 1 complete with Now Playing template and lock screen recovery integration
- ✅ **macOS Compatibility** - iPad app runs on macOS via "Designed for iPad" setting
- ✅ **Enhanced Audio Format Support** - FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS library integration
- ✅ **Improved Interruption Handling** - Fixed phone call interruptions with proper server pause/resume commands
- ✅ **Mobile Transcode Capability** - Optional server-side transcoding for mobile data optimization
- ✅ **Broader Device Support** - iOS 15.6+ deployment target for compatibility with older devices
- ✅ **Professional GitHub repository** - https://github.com/mtxmiller/LyrPlay
- ✅ **Active user support** - https://github.com/mtxmiller/LyrPlay/issues
- ✅ **GitHub Sponsorship** - Community funding support established

### Repository Information
- **GitHub Repository**: https://github.com/mtxmiller/LyrPlay
- **Local Folder**: Still named `LMS_StreamTest` (internal structure preserved)
- **App Display Name**: LyrPlay
- **Bundle ID**: `elm.LMS-StreamTest` (preserved for App Store compatibility)
- **Internal References**: Still use `LMS_StreamTest` for code consistency

## Development Commands

### Building & Running
```bash
# Install dependencies (required after clone)
pod install

# Build from command line
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -configuration Debug build

# Run tests
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -destination 'platform=iOS Simulator,name=iPhone 15' test

# Clean build
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest clean
```

### CocoaPods Management
```bash
# Update dependencies
pod update

# Install with repo update
pod install --repo-update
```

**Important**: Always use `LMS_StreamTest.xcworkspace`, never the `.xcodeproj` file directly due to CocoaPods integration.

## Architecture Overview

### Core Coordinator Pattern
The app follows a coordinator pattern with `SlimProtoCoordinator` as the main orchestrator:

- **SlimProtoCoordinator**: Main coordinator managing all SlimProto components and state
- **SlimProtoClient**: Low-level protocol handler using CocoaAsyncSocket for network communication
- **AudioManager**: Singleton coordinating all audio-related components
- **SettingsManager**: Configuration and server management singleton

### Audio Architecture
The audio system is built on the CBass framework with BASS-managed audio sessions:

- **AudioPlayer**: CBass-based player with native BASS audio library integration supporting FLAC, AAC, MP4A, MP3, Opus, OGG
- **CBass Framework**: High-performance audio library with cross-platform support (iOS and macOS)
- **BASS Audio Session Management**: BASS automatically manages iOS AVAudioSession lifecycle (activation, deactivation, route changes)
- **Push Stream Architecture**: Gapless playback using BASS push streams with write/read position tracking and sync callbacks
- **PlaybackSessionController**: Centralized interruption handling, remote command center, and CarPlay integration
- **NowPlayingManager**: Lock screen and Control Center integration with MPNowPlayingInfoCenter
- **InterruptionManager**: Legacy stub - functionality moved to PlaybackSessionController

**Important**: Manual AVAudioSession management has been removed. BASS handles all session lifecycle automatically via `BASS_CONFIG_IOS_SESSION`, preventing conflicts and ensuring proper audio routing across all scenarios (CarPlay, AirPods, phone calls, etc.).

### CarPlay Architecture
LyrPlay implements CarPlay support using iOS scene delegation architecture:

#### **Scene Delegate Architecture**
- **AppDelegate**: Routes scene connections based on session role (main app vs. CarPlay)
- **SceneDelegate**: Manages main app window using UIHostingController with SwiftUI ContentView
- **CarPlaySceneDelegate**: Manages CarPlay interface using CPTemplateApplicationSceneDelegate
- **SwiftUI Integration**: Uses `@UIApplicationDelegateAdaptor` to bridge SwiftUI App lifecycle with UIKit scene delegates

#### **Scene Configuration** (Info.plist)
```xml
<key>UIApplicationSceneManifest</key>
<dict>
    <key>UISceneConfigurations</key>
    <dict>
        <!-- Main app scene -->
        <key>UIWindowSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>Default Configuration</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
            </dict>
        </array>
        <!-- CarPlay scene -->
        <key>CPTemplateApplicationSceneSessionRoleApplication</key>
        <array>
            <dict>
                <key>UISceneConfigurationName</key>
                <string>CarPlay</string>
                <key>UISceneClassName</key>
                <string>CPTemplateApplicationScene</string>
                <key>UISceneDelegateClassName</key>
                <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
            </dict>
        </array>
    </dict>
</dict>
```

#### **CarPlay User Interface**
**Phase 1 - Now Playing (COMPLETED)**:
- **CPNowPlayingTemplate**: Displays current track info, artwork, playback controls
- **MPNowPlayingInfoCenter**: Syncs metadata from NowPlayingManager to CarPlay display
- **Remote Commands**: Play/pause/next/previous via PlaybackSessionController
- **Lock Screen Recovery**: CarPlay play button triggers same recovery as lock screen (45s threshold)

**Phase 2 - Browse Interface (PLANNED)**:
- CPListTemplate for library/playlist browsing
- LMS JSON-RPC integration for metadata
- Search functionality
- Tab bar navigation

#### **CarPlay Entitlements**
```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

#### **Remote Command Integration**
CarPlay play/pause commands flow through the same recovery mechanism as lock screen:
```
CarPlay Button Press
  ↓
PlaybackSessionController.handleRemoteCommand()
  ↓
SlimProtoCoordinator.sendLockScreenCommand()
  ↓
If backgrounded > 45s: connect() → performPlaylistRecovery()
If backgrounded < 45s: sendJSONRPCCommand()
```

This unified approach ensures CarPlay, lock screen, and Control Center all benefit from the same robust position recovery system.

### Position Recovery Architecture
The app uses a unified **playlist jump recovery system** that is critical for maintaining playback continuity across various scenarios:

#### **Playlist Jump Recovery (`performPlaylistRecovery`)**
**Command Structure**:
```swift
["playlist", "jump", savedIndex, 1, 0, [
    "timeOffset": savedPosition
]]
```
- `savedIndex`: Which track in playlist (e.g., track 3)
- `savedPosition`: Position within that track (e.g., 45.2 seconds)
- Last `0`: Start playing after jump, `1`: Stay paused after jump

#### **Why Playlist Jump is Critical**
Unlike simple seek commands that only change position within the current track, playlist jump provides:

1. **Track Protection**: Ensures recovery to the correct track even if playlist position changed
2. **Position Accuracy**: Handles both track and time offset in a single atomic operation
3. **Server Synchronization**: Server handles the complex logic of playlist navigation and seeking
4. **Reliability**: Works consistently across all connection states and scenarios

#### **Position Saving Triggers**
Position is automatically saved to UserDefaults during:
- **Pause Commands**: Every pause creates a recovery save point
- **Route Changes**: Position saved when audio routes change (BASS auto-manages device switching)
- **Network Disconnection**: Connection loss saves position for recovery
- **App Backgrounding**: Position saved when app enters background
- **CarPlay Events**: Specific handling for CarPlay connect/disconnect scenarios

**Note**: BASS automatically handles all audio route changes (CarPlay, AirPods, speakers, phone calls) without requiring manual session reinitialization.

#### **Unified Recovery Flow**
All recovery scenarios use the same robust mechanism:

1. **Route Changes** (CarPlay, AirPods, etc.):
   ```swift
   // BASS auto-manages audio route switching
   // Position saved automatically by PlaybackSessionController
   // No manual recovery needed - BASS continues playback seamlessly
   ```

2. **Lock Screen/CarPlay Recovery** (after backgrounding > 45s):
   ```swift
   // User presses play on lock screen or CarPlay when disconnected
   sendLockScreenCommand("play") → performPlaylistRecovery()
   ```

3. **Quick Resume** (backgrounded < 45s):
   ```swift
   // Connection still alive - just send play command
   sendLockScreenCommand("play") → sendJSONRPCCommand("play")
   ```

#### **Recovery Data Storage**
```swift
UserDefaults.standard.set(playlistCurIndex, forKey: "lyrplay_recovery_index")
UserDefaults.standard.set(currentPosition, forKey: "lyrplay_recovery_position")
UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
```

This unified approach eliminates timing conflicts and provides consistent behavior across all playback interruption scenarios.

### Key Dependencies
- **CocoaAsyncSocket**: Network socket communication for SlimProto (via CocoaPods)
- **CBass/BASS**: BASS audio library (Bass, BassFLAC, BassOpus) integrated via bridging header
- **WebKit**: Embedded Material LMS interface
- **Build Automation**: Automated CBundleVersion fixes for App Store compliance

### SlimProto Protocol Implementation
The SlimProto protocol is implemented across several specialized components:

- **SlimProtoClient**: Core protocol implementation with socket management
- **SlimProtoCommandHandler**: Command processing and response handling
- **SlimProtoConnectionManager**: Connection state management and recovery
- **SimpleTimeTracker**: Simplified time tracking for Material-style playback

### WebView Integration
The app embeds the Material LMS web interface with sophisticated integration:

- Custom URL scheme handling (`lmsstream://settings`)
- JavaScript injection for Material settings integration
- Background-aware WebView lifecycle management
- Proper safe area handling for modern iOS devices

## Key Architectural Patterns

### Singleton Pattern
- `AudioManager.shared`: Central audio coordination
- `SettingsManager.shared`: App configuration and server settings

### Delegate Pattern
- `SlimProtoClientDelegate`: Protocol communication callbacks
- `AudioPlayerDelegate`: Audio playback state changes

### ObservableObject Pattern
- Most managers conform to `ObservableObject` for SwiftUI integration
- Extensive use of `@Published` properties for reactive UI updates

## Development Considerations

### Audio Session Management
BASS framework automatically manages iOS AVAudioSession lifecycle via `BASS_CONFIG_IOS_SESSION`. PlaybackSessionController handles high-level coordination:
- **BASS Auto-Management**: Session activation, deactivation, and route changes handled automatically
- **Background audio playback**: Proper iOS background modes with lock screen integration
- **Interruption recovery**: Server pause/resume commands for phone calls and other apps
- **Lock screen integration**: Now Playing info and remote command center via MPNowPlayingInfoCenter
- **Audio format support**: FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS codec integration
- **CarPlay integration**: Automatic audio route handling with unified remote command processing
- **Gapless playback**: BASS push streams with position tracking and boundary sync callbacks

**Important**: Manual AVAudioSession management has been removed to prevent conflicts with BASS. The framework handles all iOS audio session scenarios automatically.

### Network Architecture
- Primary/backup server support with automatic failover
- Connection state management with retry logic
- Server discovery and time synchronization
- Robust error handling and recovery

### Settings Architecture
- Multi-server configuration support
- Per-server settings (host, ports, credentials)
- Debug mode with comprehensive logging overlay
- Material skin integration settings

### Background Processing
The app maintains SlimProto connections in the background:
- Background audio playback
- Connection maintenance and reconnection
- Server time synchronization
- Proper iOS background task handling

## App Store Readiness Status

### Platform Support (UPDATED)
The project supports iPad app compatibility on macOS with CBass framework:

```
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
SUPPORTS_MACCATALYST = NO;
SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES;
SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO;
```

**Platform Status**: CBass framework (BASS audio library) enables macOS deployment through "Designed for iPad" compatibility, allowing the iOS app to run on macOS. visionOS remains excluded pending further testing and optimization.

### App Store Metadata (COMPLETED)
Ready-to-use content for App Store Connect:

**Promotional Text (170 chars):**
```
Transform your iPhone and iPad into a premium Squeezebox player with native FLAC support, Material web interface, and high-quality audio streaming.
```

**Keywords (100 chars):**
```
flac,lms,squeezebox,audio,streaming,music,player,logitech,media,server,hifi,lossless,material
```

**Support URL:** https://github.com/mtxmiller/LyrPlay/issues

### Privacy Compliance (VERIFIED)
- **Risk Level**: Low - No personal data collection
- **Network Usage**: HTTP allowed for LMS servers (justified)
- **Background Audio**: Properly declared with usage descriptions
- **No Analytics**: No tracking or user data collection
- **Local Storage**: Only app preferences (UserDefaults)

### Build Configuration
- **iOS Deployment Target**: 15.6 (broad compatibility for older devices)
- **macOS Support**: iPad app compatibility ("Designed for iPad" on Mac)
- **Device Support**: iPhone and iPad (TARGETED_DEVICE_FAMILY = "1,2")
- **Bundle ID**: `elm.LMS-StreamTest` (preserved for existing TestFlight/App Store compatibility)
- **Display Name**: LyrPlay
- **Current Version**: 1.7 in TestFlight (External DAC + WAV + Enhanced gapless)
- **Live Version**: 1.5 (StreamingKit-based, App Store)

## Testing Structure

### Unit Tests
- Location: `LMS_StreamTestTests/`
- Framework: Swift Testing (modern iOS testing approach)
- Current state: Minimal structure requiring expansion

### UI Tests
- Location: `LMS_StreamTestUITests/`
- Framework: XCTest with XCUIApplication
- Tests: Basic launch and performance tests

## Common Development Patterns

### Logging
Extensive OSLog integration throughout the codebase:
```swift
private let logger = OSLog(subsystem: "com.lmsstream", category: "ComponentName")
os_log(.info, log: logger, "Message with %{public}s", parameter)
```

### State Management
SwiftUI state management with proper lifecycle handling:
```swift
@StateObject private var coordinator = SlimProtoCoordinator()
@Published var connectionState: String = "Disconnected"
```

### Error Handling
Comprehensive error handling with user-friendly recovery:
- Network errors with automatic retry
- Audio playback errors with fallback formats
- Server connection failures with backup servers

## Build Configuration

### Minimum Requirements
- **iOS 15.6+** deployment target (broad device compatibility)
- **Xcode 16.0+** for SwiftUI support and modern project format
- **CocoaPods** for CocoaAsyncSocket dependency
- **BASS audio library** integrated via Swift bridging header (libbass.a, libbassmix.a, libbassflac.a, libbassopus.a)

### Key Build Settings
- Background modes: Audio, fetch, processing
- Network security: Arbitrary loads allowed for LMS servers
- Audio session: Playback category with mixing options

## Current Development Status

**LyrPlay is now a stable, production-ready App Store application** with active development continuing on advanced features:

### Completed Core Platform ✅
- **Stable App Store presence** - Version 1.5 live on App Store
- **CBass Audio Framework COMPLETE** - Full migration from StreamingKit to high-performance BASS library
- **Gapless Playback** - True gapless transitions using BASS push stream architecture with enhanced sync reliability
- **BASS Auto-Managed Sessions** - Eliminated manual AVAudioSession management, BASS handles all scenarios automatically
- **CarPlay Phase 1 COMPLETE** - Now Playing template with unified lock screen recovery
- **External DAC Support** - Output device metrics display with sample rate monitoring for hardware audio interfaces
- **WAV Format Support** - Lossless WAV playback with seeking capability (Qobuz compatibility)
- **FLAC Auto-Routing** - Automatic legacy URL streaming for FLAC (BASSFLAC decode workaround)
- **Real-Time Stream Info** - Live display of current stream format, bitrate, and buffer status
- **Universal network compatibility** - Server discovery works on all network configurations
- **Enhanced audio streaming** - Superior FLAC, Opus, and multi-format support with native BASS codecs
- **Professional UI Experience** - LyrPlay loading screen with animated branding and Material integration
- **Background audio** - Full iOS background modes with lock screen integration
- **iOS 15.6+ Support** - Broad device compatibility from iOS 15.6 through latest iOS

### Active Development Areas 🔧
- **CarPlay Phase 2** - Browse interface with library/playlist navigation (in progress)
- **FLAC Seeking Enhancement** - Continued refinement of FLAC playback with WAV fallback option
- **Performance Optimizations** - Buffer management and gapless transition refinements
- **External DAC Optimization** - Enhanced hardware audio interface support and monitoring

### Technical Excellence
The codebase follows modern iOS development practices with comprehensive error handling, proper async/await patterns, and extensive logging for production debugging. All major user-reported issues from GitHub have been resolved.

## Known Limitations

### BASSFLAC Threading Fix (November 2025) ✅
- **Problem**: BASSFLAC was treating `max_framesize=0` in FLAC STREAMINFO headers (common in LMS transcoded streams) as a literal limit instead of "unknown", causing streams to abort after 5-6 seconds
- **Solution**: Updated to BASSFLAC 2.4.17.1 (Nov 27, 2025) with dedicated threading for asynchronous frame decoding
- **Fix Details**: Ian @ un4seen moved FLAC decoding to a dedicated thread, allowing the decoder to block while waiting for data without freezing the calling thread
- **Benefits**:
  - Resolves early stream termination with transcoded FLAC
  - Improved multithreading performance
  - Better handling of push stream data buffering
- **Status**: **IMPLEMENTED** - New bassflac.xcframework integrated (307K vs 290K previous)
- **Forum Thread**: https://www.un4seen.com/forum/?topic=20817.0

### FLAC Seeking with Push Streams ⚠️
- **Issue**: FLAC seeking currently non-functional with BASS push stream architecture (may be resolved with threading fix above - requires testing)
- **Impact**: Users cannot seek/scrub within FLAC tracks (play/pause/skip still work)
- **Workaround**: Server-side transcode to MP3/AAC enables seeking (with quality tradeoff)
- **Testing Required**: New BASSFLAC threading fix may resolve seeking issues
- **Affects**: Only FLAC format; MP3, AAC, Opus, OGG, WAV seeking works normally

### CBass Migration Benefits ✅
- **Problem**: StreamingKit limitations with FLAC seeking and multi-format support
- **Solution**: Complete migration to BASS audio library via bridging header
- **Benefits**:
  - Gapless playback with push stream architecture
  - Enhanced Opus codec support
  - Better multi-format audio handling (except FLAC seeking)
  - BASS auto-managed audio sessions
  - Improved performance and reliability
  - App Store validation compliance
- **Status**: **COMPLETED** - CBass migration fully implemented and tested

### Platform Compatibility
- **macOS**: Supported via "Designed for iPad" compatibility mode
- **visionOS**: Not currently supported
- **CarPlay**: Phase 1 complete (Now Playing template), Phase 2 browse interface planned
- **Background Limitations**: Standard iOS background audio restrictions apply

## Reference Source Code

When updating the application, reference the following source code repositories for implementation details and protocol understanding:

### Available Reference Sources
- **slimserver** folder: Complete Lyrion Music Server source code for protocol understanding
- **squeezelite** folder: Reference Squeezebox player implementation
- **lms-material** folder: Material skin web interface source code
- **CBass Framework**: Swift Package Manager integration of BASS audio library
- **BASS Documentation**: https://github.com/Treata11/CBass - CBass Swift wrapper documentation

These repositories provide definitive reference for:
- SlimProto protocol implementation
- Audio streaming protocols and formats
- Server communication patterns
- Material skin metadata handling approaches

## Recent Updates and Improvements

### Version 1.7 - External DAC & Format Enhancement Release (December 2025) ✅
- **BASSFLAC Threading Fix**: Updated to BASSFLAC 2.4.17.1 with asynchronous frame decoding to fix `max_framesize=0` early termination issues in transcoded FLAC streams
- **External DAC Support**: Output device metrics display with real-time sample rate monitoring for hardware audio interfaces
- **WAV Format Support**: Lossless WAV playback with full seeking capability (Qobuz compatibility)
- **FLAC Auto-Routing**: Automatic legacy URL streaming mode for FLAC files (BASSFLAC decode workaround)
- **AAC Format Priority**: User-configurable AAC preferred format option for codec priority control
- **Real-Time Stream Info**: Live display showing current stream format, bitrate, sample rate, and buffer status
- **Enhanced Gapless Playback**: Fixed sync issues, boundary drift, and format mismatch transitions
- **Volume Control & ReplayGain**: Fixed volume control and ReplayGain support for push streams
- **Buffer Level Control**: User-configurable buffer limiting to optimize memory usage for podcasts and long streams
- **Critical Bug Fixes**: Resolved CarPlay crashes, infinite logging, lock screen recovery reliability, backup server failover
- **VPN Support**: Fixed Tailscale and VPN connectivity issues
- **Podcast Optimization**: Resolved memory/CPU issues with long-duration content
- **Removed Reconnect Bit**: Simplified reconnection strategy, playlist jump recovery now handles all scenarios

### Version 1.6 - CBass Migration & CarPlay Release (November 2025) ✅
- **Complete Audio Engine Upgrade**: Migration from StreamingKit to BASS library via bridging header
- **Gapless Playback**: True gapless transitions using BASS push stream architecture
- **BASS Auto-Managed Sessions**: Removed manual AVAudioSession management, BASS handles all scenarios automatically
- **CarPlay Phase 1**: Now Playing template with scene delegate architecture and unified lock screen recovery
- **Enhanced FLAC Support**: Native BASS library integration with superior codec handling for all bit depths
- **Professional Loading Screen**: LyrPlay branded loading experience with animations
- **iOS 15.6+ Compatibility**: Broad device support from iOS 15.6 onwards
- **Mobile Transcode Support**: Optional server-side transcoding for data optimization
- **App Store Ready**: All framework validation issues resolved with automated build fixes
- **Repository Cleanup**: Organized codebase with GitHub sponsorship support

### Version 1.5 - Major Stability Release (January 2025) ✅
- **Server Discovery Revolution**: Complete rewrite of UDP discovery protocol with universal network compatibility
- **Volume Recovery Fixed**: Eliminated race conditions in app-open recovery system with dual-backup approach
- **Mobile-First Defaults**: FLAC disabled by default for better mobile performance and data usage optimization
- **New App Icon**: Fresh, modern design with App Store compliance (no transparency)
- **Enhanced Stability**: Comprehensive bug fixes and reliability improvements

### Version 1.4 - Initial App Store Release (2024) ✅  
- **First public release**: Established LyrPlay as a premium Squeezebox replacement on iOS App Store
- **Stable foundation**: Core SlimProto implementation with Material UI integration
- **FLAC support**: Native high-quality audio streaming with StreamingKit integration

### Metadata Simplification (2024)
- **Simplified metadata tags**: Reduced from 35+ tags to Material skin's minimal set for efficiency
- **Material skin approach**: Adopted proven metadata handling patterns from lms-material
- **Duration preservation**: Fixed radio stream duration loss during metadata refresh
- **Conditional updates**: Only update metadata fields when server explicitly provides them

### Recovery Methods Enhancement
- **Lock screen recovery**: Simple position recovery when disconnected and user presses lock screen play
- **Custom position banking**: Server-side player preferences storage for app open recovery with silent server-muted recovery
- **Connection state management**: Enhanced reconnection strategies with proper state handling
- **Server time synchronization**: Refined timing mechanisms for gapless playback
- **Legacy app open recovery**: Removed and replaced with custom position banking system to prevent conflicts

### Previous Approaches (Historical Reference)

#### HELO Reconnect Bit (v1.6.3 - Deprecated)
LyrPlay previously implemented the HELO reconnect bit mechanism (0x4000) used by squeezelite for seamless reconnection. This approach set a reconnect flag in the HELO message's `wlan_channellist` field to signal the LMS server that the player was reconnecting rather than connecting fresh.

**Why It Was Removed:**
While elegant in theory, the reconnect bit approach proved unreliable in production:
- Inconsistent behavior across different LMS server versions
- Limited effectiveness with iOS backgrounding constraints
- Playlist jump recovery provided more reliable position restoration
- Added complexity without measurable benefit over simpler approaches

**Current Approach:** LyrPlay now relies on playlist jump recovery with position banking for all reconnection scenarios, providing consistent and reliable playback restoration across all conditions.

### Major Fixes Completed

#### CBass Audio Framework Migration - COMPLETED ✅
- **Previous Issue**: StreamingKit error 2 (STKAudioPlayerErrorStreamParseBytesFailed) when seeking into FLAC files
- **Root Cause**: StreamingKit limitations with FLAC seeking and multi-format support
- **Solution**: Complete migration to BASS audio library integrated via Swift bridging header
- **Benefits Achieved**:
  - **Gapless Playback**: True gapless transitions using BASS push stream architecture
  - **Enhanced Format Support**: FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS codecs
  - **BASS Auto-Management**: Automatic AVAudioSession handling eliminates manual management conflicts
  - **Superior Audio Quality**: Direct codec integration with optimal performance
  - **Phone Call Recovery**: Proper interruption handling with server pause/resume commands
  - **Cross-Platform**: iOS and macOS support via "Designed for iPad" compatibility
- **Known Limitation**: FLAC seeking currently non-functional with push stream architecture (under investigation)

#### Legacy FLAC Server Configuration (Still Available)
For users who want additional server-side optimization, the previous server configuration method is still documented:
- **Implementation**: Add device-specific transcode rule to LMS server's `convert.conf` file
- **Server Configuration Required**:
  ```
  # Add this rule BEFORE the default "flc flc * *" line in convert.conf
  flc flc * 02:70:68:8c:51:41
          # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
          [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
  ```
- **User Instructions**:
  1. Replace `02:70:68:8c:51:41` with your device's MAC address (shown in LMS web interface)
  2. Add the rule to LMS server's `convert.conf` file before existing FLAC rules
  3. Restart LMS server for changes to take effect
  4. FLAC seeking will now work properly with fresh headers on every seek operation
- **Technical Details**:
  - Forces decode→raw→re-encode pipeline that generates complete FLAC headers
  - Uses LMS variables `$SAMPLESIZE$`, `$SAMPLERATE$`, `$CHANNELS$` for automatic bit depth detection
  - Handles both 16-bit and 24-bit FLAC files correctly by detecting source properties
  - Outputs consistent 16-bit FLAC for legacy StreamingKit compatibility (`-b 16` flag) - CBass handles all bit depths natively
  - Uses sox for reliable audio processing and format conversion
  - Only affects the specific iOS device, other players use normal passthrough
- **Performance Impact**: Minimal - transcoding happens in real-time on server with efficient compression level 0
- **Bit Depth Support**: Supports all FLAC bit depths (16-bit, 24-bit, 32-bit) with automatic detection and conversion to 16-bit output

#### Audio Session Optimization - COMPLETED
- **Problem**: Forced sample rate settings (44.1kHz/48kHz) potentially interfering with FLAC playback
- **Solution**: Commented out forced sample rate settings in AudioSessionManager.swift
- **Files Modified**: AudioSessionManager.swift - `setupForLosslessAudio()` and `setupForCompressedAudio()`
- **Impact**: StreamingKit and audio content now determine optimal sample rates automatically

#### Silent Position Recovery System - COMPLETED
- **Problem**: Audio snippets heard during custom position recovery (play → seek → pause sequences)
- **Root Cause**: App-level volume control only affects StreamingKit internal volume, not system audio output
- **Solution**: Server-side volume control using LMS mixer commands for truly silent recovery
- **Implementation**: 
  - `saveServerVolumeAndMute()`: Query current server volume, save to preferences, set server volume to 0
  - `performCustomPositionRecovery()`: Execute play → seek → pause sequence with server muted
  - `restoreServerVolume()`: Retrieve saved volume from preferences and restore server volume
- **Files Modified**: SlimProtoCoordinator.swift - custom position recovery methods
- **Technical Details**:
  - Uses LMS JSON-RPC `["mixer", "volume", "?"]` to get current volume
  - Stores volume in player preferences: `["playerpref", "lyrPlaySavedVolume", volume]`
  - Sets server volume to 0: `["mixer", "volume", "0"]` during recovery
  - Restores original volume after recovery completes
- **Impact**: Completely silent position recovery with no audio snippets during app reopening

## Repository Migration Status - COMPLETED ✅

### Clean Repository Migration - DONE
The LyrPlay repository has been successfully created and configured:

- **✅ New Repository**: https://github.com/mtxmiller/LyrPlay
- **✅ Professional README**: Complete setup instructions and documentation
- **✅ Clean Commit History**: Starts with professional "Initial LyrPlay release" commit
- **✅ Topics Added**: ios, swift, flac, audio, squeezebox, lms, streaming, music-player, swiftui
- **✅ Local Project**: Remains in `LMS_StreamTest` folder for consistency
- **✅ Git Remote**: Updated to point to LyrPlay repository
- **✅ Xcode Connection**: Source Control now connected to new repository

### Key Benefits Achieved:
- **Professional appearance** for open-source release
- **Clean public commit history** (development history preserved locally)
- **App Store ready** with proper support URL
- **Consistent branding** with LyrPlay name throughout

### Current Development Status
- **Local Folder**: `LMS_StreamTest` (internal consistency preserved)
- **Repository**: `mtxmiller/LyrPlay` (public-facing)
- **All pushes/pulls**: Go to LyrPlay repository
- **Build commands**: Still use `LMS_StreamTest.xcworkspace` (no changes needed)

## Remaining Tasks for App Store Submission

### High Priority (Required)
- [ ] **Test final build** - Verify all iOS-only functionality works correctly
- [ ] **Generate archive build** - Create final .ipa for App Store submission
- [ ] **Submit to App Store Connect** - Upload build and configure metadata

### Medium Priority (Optional)
- [ ] **Privacy Manifest** - Create PrivacyInfo.xcprivacy file (iOS 17+ requirement)
- [ ] **Screenshot preparation** - Create App Store screenshots for iPhone/iPad
- [ ] **App Store review notes** - Prepare notes explaining HTTP usage for LMS servers

### App Store Connect Configuration
When submitting, use these prepared values:
- **Support URL**: https://github.com/mtxmiller/LyrPlay/issues
- **Marketing URL**: (optional) https://github.com/mtxmiller/LyrPlay
- **Keywords**: flac,lms,squeezebox,audio,streaming,music,player,logitech,media,server,hifi,lossless,material
- **Category**: Music
- **Content Rating**: 4+ (No objectionable content)

---

**Last Updated**: December 2025 - Version 1.7 External DAC & Format Enhancement Release ✅

### Production Status
- **App Store Version**: 1.5 (StreamingKit-based, stable)
- **TestFlight Version**: 1.7 (CBass/BASS library with external DAC support and WAV format)
- **Active User Base**: Production app with GitHub community support

### Current Capabilities (v1.7)
- **Audio Engine**: BASS library integrated via Swift bridging header
- **Gapless Playback**: ✅ Enhanced with improved sync reliability and format mismatch handling
- **FLAC Support**: ✅ Auto-routing to legacy URL streaming mode (workaround for seeking)
- **WAV Format**: ✅ Lossless WAV playback with full seeking capability
- **Format Seeking**: ✅ MP3, AAC, Opus, OGG, WAV seeking works normally
- **External DAC**: ✅ Real-time sample rate monitoring and output device metrics
- **Audio Session Management**: BASS auto-managed (manual management removed)
- **CarPlay**: Phase 1 complete (Now Playing template), Phase 2 in development
- **Platform Support**: iOS 15.6+ and macOS via "Designed for iPad" compatibility
- **Audio Formats**: FLAC, WAV, AAC, MP4A, MP3, Opus, OGG with native BASS codecs

### Active Development Priorities
1. **CarPlay Phase 2** - Browse interface for library/playlist navigation (in progress)
2. **FLAC Seeking Enhancement** - Continued refinement with WAV fallback option
3. **External DAC Optimization** - Enhanced hardware audio interface support

### Architecture Notes
- **Playlist Jump Recovery**: Critical for position recovery across backgrounding, lock screen, CarPlay scenarios
- **45-Second Threshold**: Lock screen/CarPlay recovery triggers after 45s backgrounding
- **Scene Delegate Architecture**: SwiftUI + UIKit bridge for CarPlay support
- **Reconnect Bit Removed**: Simplified to playlist jump recovery for all reconnection scenarios