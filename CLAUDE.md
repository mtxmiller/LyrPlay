# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**LyrPlay** (formerly LMS_StreamTest) is an iOS SwiftUI application that implements a SlimProto client for streaming audio from Logitech Media Server (LMS). The app acts as a Squeezebox player replacement, allowing iOS devices to connect to LMS instances and stream high-quality audio with native FLAC support.

### Current Status: **LIVE ON APP STORE** 🌟
- ✅ **Version 1.5 Live on App Store** - StreamingKit-based stable release with major stability improvements
- 🚧 **Version 1.6 Build ~20 in TestFlight** - Major audio engine upgrade migrating from StreamingKit to CBass
- ✅ **CBass Audio Framework Migration** - Active development for superior FLAC, Opus, and multi-format support
- ✅ **macOS Compatibility** - iPad app runs on macOS via "Designed for iPad" setting
- ✅ **Enhanced Audio Format Support** - FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS library integration
- ✅ **Improved Interruption Handling** - Fixed phone call interruptions with proper server pause/resume commands
- ✅ **Broader Device Support** - iOS 15.0+ deployment target for compatibility with older devices
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
The audio system is built on the CBass framework with centralized session management:

- **AudioPlayer**: CBass-based player with native BASS audio library integration supporting FLAC, AAC, MP4A, MP3, Opus, OGG
- **CBass Framework**: High-performance audio library with cross-platform support (iOS and macOS)
- **PlaybackSessionController**: Centralized iOS audio session management, interruption handling, and remote command center
- **NowPlayingManager**: Lock screen and Control Center integration with MPNowPlayingInfoCenter
- **InterruptionManager**: Legacy stub - functionality moved to PlaybackSessionController

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
- **Route Changes**: All audio route changes (CarPlay, AirPods, speakers) save position via `reinitializeBASS()`
- **Network Disconnection**: Connection loss saves position for recovery
- **App Backgrounding**: Position saved when app enters background
- **CarPlay Events**: Specific handling for CarPlay connect/disconnect scenarios

#### **Unified Recovery Flow**
All recovery scenarios use the same robust mechanism:

1. **Route Changes** (CarPlay, AirPods, etc.):
   ```swift
   // In reinitializeBASS()
   coordinator.saveCurrentPositionForRecovery()  // Fresh position
   coordinator.performPlaylistRecovery()         // Playlist jump
   ```

2. **Lock Screen Recovery**:
   ```swift
   // User presses play on lock screen when disconnected
   sendLockScreenCommand("play") → performPlaylistRecovery()
   ```

3. **CarPlay Disconnect/Reconnect**:
   ```swift
   // Disconnect: Save → Jump → Pause
   // Reconnect: Save → Jump → Play
   ```

#### **Recovery Data Storage**
```swift
UserDefaults.standard.set(playlistCurIndex, forKey: "lyrplay_recovery_index")
UserDefaults.standard.set(currentPosition, forKey: "lyrplay_recovery_position")
UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
```

This unified approach eliminates timing conflicts and provides consistent behavior across all playback interruption scenarios.

### Seamless Reconnection via HELO Reconnect Bit

**NEW in v1.6.3+**: LyrPlay now implements the **HELO reconnect bit mechanism** used by squeezelite for truly seamless reconnection when app resumes from background.

#### **The Challenge**
When iOS backgrounds LyrPlay and TCP connection drops after ~3 minutes, the LMS server "forgets" the player after 300 seconds. Upon app reopening, position was lost requiring playlist jump recovery with audio blips.

#### **The Solution: Reconnect Bit (0x4000)**
Following squeezelite's proven approach, LyrPlay now sets a reconnect bit in the HELO message's `wlan_channellist` field:

```swift
// In SlimProtoClient.sendHelo():
let wlanChannels: UInt16 = isReconnection ? 0x4000 : 0x0000
```

**How it works:**
1. **First connection**: Send HELO with `0x0000` (new player)
2. **All subsequent connections**: Send HELO with `0x4000` (reconnect bit set)
3. **Server recognizes**: "Same player reconnecting" → calls `playerReconnect()`
4. **Server executes**: `ContinuePlay` event with preserved position
5. **Result**: Seamless resume with NO audio blip, NO playlist jump needed!

#### **Implementation Details**
```swift
// SlimProtoClient.swift
private var isReconnection = false  // Set to true after first HELO

// After first successful HELO:
if !isReconnection {
    isReconnection = true  // All future connections are reconnections
}

// IMPORTANT: Never reset isReconnection in disconnect()
// Maintains state across backgrounding/foregrounding cycles
```

#### **Server-Side Processing** (from LMS source code)
```perl
# Slim/Networking/Slimproto.pm line 973
$reconnect = $wlan_channellist & 0x4000;

# Slim/Player/Squeezebox.pm line 70-96
if ($reconnect) {
    $client->resumeOnPower(1);      # Resume playback state
    $controller->playerReconnect($bytes_received);  # ContinuePlay event
}
```

#### **Benefits vs Playlist Jump**
- ✅ **No audio blip** - Server continues existing stream seamlessly
- ✅ **No seek artifacts** - No new stream creation or seeking required
- ✅ **Paused state preserved** - If paused before, stays paused after reconnect
- ✅ **Server-native** - Uses LMS's built-in reconnection mechanism
- ✅ **Proven approach** - Exactly how squeezelite handles backgrounding

#### **When Used**
- App resumes from background (< 300s timeout)
- Network reconnection after brief disconnection
- Any scenario where player reconnects to same server

This elegant solution eliminates the need for client-side position recovery in most scenarios, providing the smooth experience users expect from native audio apps.

### Key Dependencies
- **CocoaAsyncSocket**: Network socket communication for SlimProto
- **CBass**: Swift Package Manager integration of BASS audio library (Bass, BassFLAC, BassOpus)
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
The app handles complex audio session scenarios through PlaybackSessionController:
- Background audio playback with proper iOS background modes
- Interruption recovery with server pause/resume commands (phone calls, other apps)
- Lock screen integration with Now Playing info and remote command center
- Audio format support: FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS codec integration
- CarPlay integration with automatic audio route handling

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
- **iOS Deployment Target**: 15.0 (broad compatibility for older devices)
- **macOS Support**: iPad app compatibility ("Designed for iPad" on Mac)
- **Device Support**: iPhone and iPad (TARGETED_DEVICE_FAMILY = "1,2")
- **Bundle ID**: `elm.LMS-StreamTest` (preserved for existing TestFlight/App Store compatibility)
- **Display Name**: LyrPlay
- **Current Version**: 1.6 Build ~20 (CBass Migration in TestFlight)
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
- iOS 18.2 deployment target (latest iOS features)
- Xcode 15.0+ for SwiftUI and Swift Package Manager support
- CocoaPods for CocoaAsyncSocket dependency
- Swift Package Manager for CBass framework integration

### Key Build Settings
- Background modes: Audio, fetch, processing
- Network security: Arbitrary loads allowed for LMS servers
- Audio session: Playback category with mixing options

## Current Development Status

**LyrPlay is now a stable, production-ready App Store application** with active development continuing on advanced features:

### Completed Core Platform ✅
- **Stable App Store presence** - Version 1.5 live, Version 1.6 CBass migration ready for submission
- **CBass Audio Framework** - Complete migration from StreamingKit to high-performance BASS library
- **Universal network compatibility** - Server discovery works on all network configurations  
- **Enhanced audio streaming** - CBass integration with superior FLAC, Opus, and multi-format support
- **Professional UI Experience** - LyrPlay loading screen with animated branding and Material integration
- **Background audio** - Full iOS background modes with lock screen integration
- **iOS 18.2 Ready** - Updated for latest iOS features and modern deployment target

### Active Development Areas 🔧
- **CarPlay Implementation** - Phase 2 & 3 complete (~65% done), browse interface and core playback functional
- **Advanced UI Features** - Album/playlist navigation and playback container functionality
- **Performance Optimizations** - Continued refinement of audio session management and metadata handling

### Technical Excellence
The codebase follows modern iOS development practices with comprehensive error handling, proper async/await patterns, and extensive logging for production debugging. All major user-reported issues from GitHub have been resolved.

## Known Limitations

### CBass Migration Benefits ✅
- **Problem**: StreamingKit limitations with FLAC seeking and multi-format support
- **Solution**: Complete migration to CBass framework (BASS audio library)
- **Benefits**: 
  - Superior FLAC support with native seeking
  - Enhanced Opus codec support
  - Better multi-format audio handling
  - Improved performance and reliability
  - App Store validation compliance
- **Status**: **COMPLETED** - CBass v1.6 migration fully implemented and tested
- **Legacy FLAC Server Configuration**: Still available for server-side optimization if needed

### Platform Compatibility
- **macOS/visionOS**: Not supported due to CBass framework targeting iOS optimization
- **CarPlay**: Implementation in progress (~65% complete) with core functionality working
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

### Version 1.6 - CBass Migration Release (January 2025) ✅
- **Complete Audio Engine Upgrade**: Migration from StreamingKit to CBass framework
- **Enhanced FLAC Support**: Native BASS library integration with superior codec handling
- **Professional Loading Screen**: LyrPlay branded loading experience with animations
- **iOS 18.2 Compatibility**: Updated deployment target for latest iOS features
- **App Store Ready**: All framework validation issues resolved with automated build fixes
- **Build Automation**: Automated CBundleVersion fixes for seamless App Store submission
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

### Major Fixes Completed

#### CBass Audio Framework Migration - IN PROGRESS ✅
- **Previous Issue**: StreamingKit error 2 (STKAudioPlayerErrorStreamParseBytesFailed) when seeking into FLAC files
- **Root Cause**: StreamingKit limitations with FLAC seeking and multi-format support
- **Current Solution**: Active migration to CBass framework (BASS audio library) - Version 1.6 Build ~20
- **Benefits Achieved**:
  - Native FLAC seeking with CBass framework
  - Enhanced support for FLAC, AAC, MP4A, MP3, Opus, OGG formats
  - Superior multi-format audio handling with BASS codec integration
  - Cross-platform support (iOS and macOS)
  - Fixed phone call interruption handling with server pause/resume commands

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

**Last Updated**: September 22, 2025 - Version 1.6 CBass Migration In Progress ✅
- **Production app** with active user base on App Store (Version 1.5 StreamingKit-based)
- **Version 1.6 Build ~20** with CBass migration in TestFlight testing
- **Active audio engine upgrade** from StreamingKit to CBass framework
- **Enhanced platform support** with macOS compatibility via "Designed for iPad" setting
- **Improved interruption handling** with server pause/resume commands
- **Repository optimized** with GitHub sponsorship and clean organization

#### Current Status:
- **Live Audio Engine**: StreamingKit (Version 1.5 on App Store)
- **Development Audio Engine**: CBass framework (BASS library) with native multi-format support
- **Current Development Version**: 1.6 Build ~20 (TestFlight)
- **Next App Store Release**: 1.6 with CBass migration
- **Platform Support**: iOS 15.0+ and macOS via "Designed for iPad" compatibility
- **Audio Formats**: FLAC, AAC, MP4A, MP3, Opus, OGG with native BASS integration
- **iOS Deployment Target**: 15.0 for broad device compatibility
- remember playlist jump, where we are using why it is critical on route changes, backgrounding etc