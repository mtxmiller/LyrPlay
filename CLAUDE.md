# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LMS_StreamTest is an iOS SwiftUI application that implements a SlimProto client for streaming audio from Logitech Media Server (LMS). The app acts as a Squeezebox player replacement, allowing iOS devices to connect to LMS instances and stream high-quality audio with native FLAC support.

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
The audio system is modular with clear separation of concerns:

- **AudioPlayer**: StreamingKit-based player with native FLAC support
- **AudioSessionManager**: iOS audio session management and interruption handling
- **NowPlayingManager**: Lock screen and Control Center integration
- **InterruptionManager**: Specialized handling for audio interruptions

### Key Dependencies
- **CocoaAsyncSocket**: Network socket communication for SlimProto
- **StreamingKit**: Audio streaming with native FLAC support
- **WebKit**: Embedded Material LMS interface

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
The app handles complex audio session scenarios:
- Background audio playback with proper iOS background modes
- Interruption recovery (phone calls, other apps)
- Lock screen integration with Now Playing info
- Audio format prioritization (FLAC > ALAC > AAC > MP3)

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
- iOS 14.0 minimum deployment target
- Xcode 12.0+ for SwiftUI support
- CocoaPods for dependency management

### Key Build Settings
- Background modes: Audio, fetch, processing
- Network security: Arbitrary loads allowed for LMS servers
- Audio session: Playback category with mixing options

## Current Development Status

The project is actively developed with recent focus on:
- SlimProto command standardization
- Audio metadata handling improvements
- Server discovery enhancements
- Background audio reliability
- **FLAC seeking limitation** - Known issue with FLAC file seeking (see Known Limitations below)
- **Audio session optimization** - Removed forced sample rate settings for better format compatibility

The codebase is well-structured, thoroughly documented, and follows modern iOS development practices with comprehensive error handling and state management.

## Known Limitations

### FLAC Seeking
- **Issue**: Seeking within FLAC files fails with StreamingKit error 2 (Stream Parse Bytes Failed)
- **Cause**: LMS server sends raw FLAC audio frames without required metadata headers when seeking
- **Impact**: Users cannot seek within FLAC files - seeking will cause playback to fail
- **Workarounds**: 
  - Restart tracks from beginning instead of seeking
  - Use AAC or MP3 transcoding for files where seeking is important
- **Status**: Known limitation, not currently planned for immediate fix due to complexity

## Reference Source Code

When updating the application, reference the following source code repositories for implementation details and protocol understanding:

### Available Reference Sources
- **slimserver** folder: Complete Lyrion Music Server source code for protocol understanding
- **squeezelite** folder: Reference Squeezebox player implementation
- **lms-material** folder: Material skin web interface source code
- **StreamingKit** source in CocoaPods: Audio streaming implementation details

These repositories provide definitive reference for:
- SlimProto protocol implementation
- Audio streaming protocols and formats
- Server communication patterns
- Material skin metadata handling approaches

## Recent Updates and Improvements

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

#### FLAC Seeking Issue - SOLVED with Server-Side Configuration
- **Problem**: StreamingKit error 2 (STKAudioPlayerErrorStreamParseBytesFailed) when seeking into FLAC files
- **Root Cause**: When seeking, LMS server starts FLAC streams at frame boundaries without STREAMINFO headers, which StreamingKit requires for decoder initialization
- **Solution**: Force server-side FLAC transcoding for iOS devices to ensure proper headers on seeks
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
  - Outputs consistent 16-bit FLAC for StreamingKit compatibility (`-b 16` flag)
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

## Future Repository Migration Plan

### Clean Repository Setup for "LyrPlay"
When ready to create the final clean repository, follow this migration plan:

#### Option A: Fresh Xcode Project (Recommended)
1. **Create new Xcode project:**
   - File → New → Project
   - Name it `LyrPlay` 
   - Use same bundle ID: `elm.LMS-StreamTest` (for App Store Connect compatibility)

2. **Copy source files:**
   - Copy all `.swift` files from `LMS_StreamTest/` to `LyrPlay/`
   - Copy `Assets.xcassets`, `Info.plist` content
   - Copy `CLAUDE.md` and update project references

3. **Re-add dependencies:**
   - Copy `Podfile`, update target name to `LyrPlay`
   - Run `pod install`

4. **Update build commands in CLAUDE.md:**
   ```bash
   # Build from command line
   xcodebuild -workspace LyrPlay.xcworkspace -scheme LyrPlay -configuration Debug build
   
   # Run tests
   xcodebuild -workspace LyrPlay.xcworkspace -scheme LyrPlay -destination 'platform=iOS Simulator,name=iPhone 15' test
   ```

#### Benefits of Clean Repository:
- Project name: `LyrPlay`
- Clean file structure with no legacy naming
- Same bundle ID (App Store compatible)
- Fresh git history starting from polished final version
- Professional appearance for open-source release

#### Current Status:
- App display name already updated to "LyrPlay" in Xcode
- All source code references updated from "LMS Stream" to "LyrPlay"
- Bundle ID remains `elm.LMS-StreamTest` for App Store compatibility
- Ready for clean repository creation when development is complete