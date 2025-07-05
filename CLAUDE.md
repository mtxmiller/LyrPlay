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
- **ServerTimeSynchronizer**: Server time synchronization for gapless playback

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

The codebase is well-structured, thoroughly documented, and follows modern iOS development practices with comprehensive error handling and state management.