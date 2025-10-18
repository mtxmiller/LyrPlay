# LyrPlay Offline Playback Specification

**Version**: 1.0
**Date**: January 2025
**Status**: Design Phase

## Prerequisites: Understanding Current Architecture

Before implementing offline playback, we must thoroughly understand the existing LyrPlay architecture and integration points. This section documents the critical areas that require analysis and understanding.

### **1. SlimProto Protocol & Queue Management**
**Files to Review**: `SlimProtoCoordinator.swift`, `SlimProtoCommandHandler.swift`
- How `playlist_loop` data is currently received and processed
- Track metadata structure in JSON-RPC responses
- When and how often status polling occurs
- How track IDs and URLs are extracted from server responses
- Current queue state management and track advancement logic

### **2. Audio Playback Architecture**
**Files to Review**: `AudioPlayer.swift`, `AudioManager.swift`, `CBass` integration
- How CBass currently handles streaming URLs
- Track transition and end detection mechanisms
- Audio session management with BASS_CONFIG_IOS_SESSION
- How track format detection works (FLAC, Opus, MP3, etc.)
- Current buffering and seeking implementation

### **3. UI State Management & WebView Integration**
**Files to Review**: `ContentView.swift`, WebView Material UI integration
- How WebView embeds Material LMS interface
- State management between SwiftUI and WebView
- How connection status affects UI visibility
- Current error handling and user notification patterns
- Navigation and view hierarchy structure

### **4. Network & Connection Management**
**Files to Review**: `SlimProtoConnectionManager.swift`, `SettingsManager.swift`
- Current connection monitoring implementation
- How connection failures are detected and handled
- Server discovery and fallback mechanisms
- JSON-RPC command sending and response handling
- Reconnection logic and retry patterns

### **5. Data Models & Track Information**
**Files to Review**: Track metadata handling throughout the app
- Current track information structure and fields
- How metadata flows from SlimProto → UI → Audio Player
- Server URL construction patterns for streaming
- How track duration, artwork, and format info is managed

### **6. File System & Storage Patterns**
**Files to Review**: App storage usage, UserDefaults patterns
- Current Documents directory usage and structure
- How app handles file permissions and storage
- Existing UserDefaults keys and storage patterns
- Background processing and file management capabilities

### **7. Settings & Configuration Management**
**Files to Review**: `SettingsManager.swift`, `SettingsView.swift`
- How user preferences are stored and accessed
- Current settings architecture and defaults
- How server configuration affects other app components
- Settings synchronization and change notification patterns

### **8. Error Handling & Recovery Mechanisms**
**Files to Review**: Error handling patterns throughout codebase
- Current error handling philosophies and patterns
- How the app recovers from various failure scenarios
- User notification and error reporting mechanisms
- Logging patterns and debug information management

### **9. Background Processing & iOS Integration**
**Files to Review**: Background audio implementation, iOS capabilities
- Current background modes and capabilities
- How background audio is maintained
- iOS background task management
- Lock screen and CarPlay integration patterns

### **10. Manager Coordination & Communication**
**Files to Review**: Manager interaction patterns
- How AudioManager, SettingsManager, SlimProtoCoordinator communicate
- Delegate patterns and @Published property usage
- State synchronization between managers
- Dependency injection and initialization patterns

## **Analysis Tasks Before Implementation**

### **Phase 0: Architecture Understanding** ✅ COMPLETED
- [x] Map current data flow: SlimProto → Audio → UI
- [x] Document current track metadata structure and fields available
- [x] Understand WebView ↔ SwiftUI communication patterns
- [x] Analyze current connection failure handling and recovery
- [x] Review existing file storage patterns and permissions
- [x] Document current settings architecture and extension points
- [x] Understand audio session management with CBass integration
- [x] Map current background processing capabilities and limitations

**📋 Detailed Analysis Available**: See `ARCHITECTURE_ANALYSIS.md` for comprehensive findings and integration guidance.

### **Integration Risk Assessment**
- **High Risk**: Changes that affect core SlimProto protocol handling
- **Medium Risk**: Modifications to existing audio playback flow
- **Low Risk**: New isolated components (cache manager, offline UI)

### **Compatibility Requirements**
- Must not break existing Material UI WebView integration
- Must preserve current CarPlay and lock screen functionality
- Must maintain existing server compatibility and SlimProto compliance
- Must respect current audio session management with CBass
- Must integrate with existing settings and configuration patterns

## Executive Summary

LyrPlay will implement **seamless offline playback** functionality that allows users to continue listening to music during network interruptions without losing control or experiencing audio gaps. This feature positions LyrPlay as the **first Squeezebox client** with offline capabilities, providing a significant competitive advantage.

## Problem Statement

### Current Limitations
- **Complete playback failure** when network connection is lost
- **Loss of control interface** when LMS server becomes unreachable
- **User frustration** during brief network interruptions (cellular dead zones, WiFi handoffs)
- **No existing solutions** in the Squeezebox ecosystem

### User Impact
- Music stops playing during network drops
- Users lose all playback controls when offline
- No ability to skip tracks or control volume during interruptions
- Poor experience compared to modern streaming apps (Spotify, Apple Music)

## Solution Overview

### Core Architecture: **Queue-Based Intelligent Caching**

1. **Background Download**: Automatically cache current + next 3-5 tracks from queue
2. **Seamless Handoff**: Switch to cached files during connection loss
3. **Track Boundary Switching**: Clean transitions between online/offline modes
4. **Hybrid UI**: Material UI when connected, native controls when offline
5. **State Synchronization**: Restore server state when connection returns

## Technical Specifications

### Phase 1: Queue Intelligence & Download Infrastructure

#### 1.1 Queue Data Source
**Current Implementation**: LyrPlay already receives complete queue data via SlimProto status commands:

```swift
// Existing status request in SlimProtoCoordinator.swift:
"params": [playerID, ["status", "-", "1", "tags:u,d,t,K,c"]]

// Response contains playlist_loop with full queue:
"playlist_loop": [
    {
        "id": "12345",              // Track ID for download URL
        "title": "Track Name",      // Metadata
        "artist": "Artist Name",
        "url": "file://server/path" // Server file path
    }
    // ... more tracks in queue
]
```

#### 1.2 Download URL Format
**Reference Implementation**: LMS App uses `track.streamURL` directly for downloads

```swift
// From LMS App DownloadManager.swift:
guard let streamURL = track.streamURL else { return }
let task = URLSession.shared.downloadTask(with: streamURL) { ... }
```

**LyrPlay Implementation**: Extract download URLs from existing stream URLs:
```swift
// Convert streaming URL to download URL:
// FROM: http://server:9000/stream.mp3?player=mac&songid=12345
// TO:   http://server:9000/music/12345/download
func getDownloadURL(from streamURL: String, trackID: String) -> String {
    return "\(serverURL)/music/\(trackID)/download"
}
```

#### 1.3 Cache Strategy
```swift
class OfflineCacheManager {
    private let defaultCachedTracks = 5  // Minimum recommended
    private let maxCachedTracks = 15     // Maximum allowed
    private let cacheDirectory = "OfflineCache"

    func downloadUpcomingTracks(from playlist: [[String: Any]]) {
        let userCacheSize = UserDefaults.standard.integer(forKey: "maxCachedTracks")
        let cacheSize = userCacheSize > 0 ? userCacheSize : defaultCachedTracks

        // Skip current track (already streaming)
        let upcomingTracks = Array(playlist.dropFirst())
        let tracksToCache = Array(upcomingTracks.prefix(cacheSize))

        for trackInfo in tracksToCache {
            downloadTrackInBackground(trackInfo)
        }
    }
}
```

### Phase 2: Connection Monitoring & UI State Management

#### 2.1 Connection State Detection
```swift
class ConnectionManager: ObservableObject {
    @Published var isConnected: Bool = true
    @Published var uiMode: UIMode = .online

    enum UIMode {
        case online     // Material WebView visible
        case offline    // Native controls visible
        case transition // Switching between modes
    }

    func monitorConnection() {
        // Monitor both network and LMS server connectivity
        // Trigger UI mode changes on state transitions
    }
}
```

#### 2.2 Hybrid UI Architecture
```swift
struct MainPlaybackView: View {
    @StateObject private var connectionManager = ConnectionManager()

    var body: some View {
        ZStack {
            // Material LMS Web Interface
            if connectionManager.uiMode == .online {
                WebView(url: materialURL)
                    .transition(.opacity)
            }

            // Native Offline Controls
            if connectionManager.uiMode == .offline {
                OfflinePlaybackView()
                    .transition(.slide)
            }
        }
    }
}
```

#### 2.3 Native Offline Controls
```swift
struct OfflinePlaybackView: View {
    @StateObject private var offlineManager = OfflinePlaybackManager()

    var body: some View {
        VStack(spacing: 20) {
            // Connection Status
            HStack {
                Image(systemName: "wifi.slash")
                Text("Playing offline - reconnecting...")
                    .foregroundColor(.orange)
            }

            // Track Information
            VStack {
                Text(offlineManager.currentTrack.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(offlineManager.currentTrack.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Playback Controls
            HStack(spacing: 40) {
                Button(action: offlineManager.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button(action: offlineManager.togglePlayPause) {
                    Image(systemName: offlineManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }

                Button(action: offlineManager.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }

            // Queue Preview
            OfflineQueueView(tracks: offlineManager.cachedTracks)
        }
        .padding()
    }
}
```

### Phase 3: Seamless Audio Handoff

#### 3.1 Connection Loss Detection
```swift
class OfflinePlaybackManager: ObservableObject {
    func handleConnectionLoss() {
        // 1. Continue current stream until track ends
        // 2. Prepare next cached track
        // 3. Switch UI to offline mode

        guard let nextCachedTrack = getNextCachedTrack() else {
            showNoOfflineTracksWarning()
            return
        }

        // Schedule handoff at track boundary
        scheduleOfflineHandoff(to: nextCachedTrack)
    }

    private func scheduleOfflineHandoff(to cachedTrack: CachedTrack) {
        // Wait for current track to end naturally
        audioPlayer.onTrackEnd = { [weak self] in
            self?.switchToLocalFile(cachedTrack.localURL)
            self?.updateUIForOfflineMode()
        }
    }
}
```

#### 3.2 Connection Restoration & Sync
```swift
func handleConnectionRestored() {
    // 1. Sync current position with server
    let currentPosition = audioPlayer.getCurrentTime()
    let currentTrackIndex = offlineManager.currentTrackIndex

    // 2. Update server state
    syncServerState(trackIndex: currentTrackIndex, position: currentPosition)

    // 3. Offer user choice for returning to server
    showReconnectionOptions()
}

private func syncServerState(trackIndex: Int, position: Double) {
    let playlistJumpCommand: [String: Any] = [
        "id": 1,
        "method": "slim.request",
        "params": [
            playerID,
            ["playlist", "jump", trackIndex, 1, 0, [
                "timeOffset" : position
            ]]
        ]
    ]
    sendJSONRPCCommand(playlistJumpCommand)
}
```

### Phase 4: User Experience & Control Flow

#### 4.1 Connection Loss Flow
```
[User Playing Music via Material UI]
           ↓
    [Network Connection Lost]
           ↓
[Continue Current Stream Until Track End]
           ↓
    [Switch to Native UI with Status: "Playing offline"]
           ↓
    [Play Next Track from Cache]
           ↓
    [Provide Basic Controls: Play/Pause/Next/Previous]
```

#### 4.2 Connection Restoration Flow
```
[User in Offline Mode]
        ↓
[Network Connection Restored]
        ↓
[Sync Server with Current Position]
        ↓
[Show User Choice Dialog]
        ↓
┌─────────────────────┬─────────────────────┐
│  "Return to Server" │  "Stay Offline"     │
│                     │                     │
│  Switch back to     │  Continue with      │
│  Material UI at     │  native controls    │
│  next track         │  and cached files   │
└─────────────────────┴─────────────────────┘
```

#### 4.3 Reconnection Options Dialog
```swift
func showReconnectionOptions() {
    let alert = UIAlertController(
        title: "Server Connected",
        message: "Your connection to the LMS server has been restored.",
        preferredStyle: .alert
    )

    alert.addAction(UIAlertAction(title: "Return to Server", style: .default) { _ in
        self.returnToServerControl()
    })

    alert.addAction(UIAlertAction(title: "Continue Offline", style: .cancel) { _ in
        self.continueOfflineMode()
    })

    present(alert, animated: true)
}
```

## Implementation Plan

### **Sprint 1: Foundation (Week 1-2)**
- [ ] Create `OfflineCacheManager` class
- [ ] Implement track download functionality using LMS App reference
- [ ] Add connection monitoring with `NetworkMonitor`
- [ ] Test download URL format with existing LMS server

### **Sprint 2: Basic Offline Playback (Week 3-4)**
- [ ] Implement cache-to-streaming handoff at track boundaries
- [ ] Create basic native UI for offline mode
- [ ] Add track advancement logic for cached files
- [ ] Test complete offline playback cycle

### **Sprint 3: UI Integration (Week 5-6)**
- [ ] Implement hybrid UI switching (Material ↔ Native)
- [ ] Add smooth transitions between online/offline modes
- [ ] Create connection status indicators
- [ ] Test UI state management

### **Sprint 4: Server Synchronization (Week 7-8)**
- [ ] Implement server state sync on reconnection
- [ ] Add user choice dialog for reconnection handling
- [ ] Test playlist jump with position recovery
- [ ] Validate complete round-trip (online → offline → online)

### **Sprint 5: Polish & Testing (Week 9-10)**
- [ ] Add user preferences for offline behavior
- [ ] Implement cache size management and cleanup
- [ ] Performance testing and optimization
- [ ] Comprehensive user testing

## Technical Considerations

### Storage Management
```swift
class CacheStorageManager {
    private let maxCacheSize: Int64 = 1_000_000_000 // 1GB (for 5-15 tracks)
    private let maxCachedTracks = 15

    func cleanupOldCaches() {
        // Remove tracks not in current queue
        // Implement LRU eviction policy
        // Respect user storage preferences
    }
}
```

### Battery Optimization
- Download on both WiFi and cellular by default
- Pause downloads when battery is critically low (< 10%)
- Smart download prioritization (current queue first)

### Error Handling
```swift
enum OfflinePlaybackError: Error {
    case noTracksAvailable
    case downloadFailed(TrackInfo)
    case storageExceeded
    case serverSyncFailed
}
```

## User Settings & Preferences

### Offline Settings Panel
```swift
struct OfflinePlaybackSettings: View {
    @AppStorage("offlineEnabled") var offlineEnabled = true
    @AppStorage("maxCachedTracks") var maxCachedTracks = 5
    @AppStorage("autoReturnToServer") var autoReturnToServer = true

    var body: some View {
        Form {
            Section("Offline Playback") {
                Toggle("Enable Offline Mode", isOn: $offlineEnabled)

                Stepper("Cache \(maxCachedTracks) tracks",
                       value: $maxCachedTracks, in: 5...15)

                Toggle("Auto Return to Server", isOn: $autoReturnToServer)
            }
        }
    }
}
```

## Success Metrics

### Technical Metrics
- **Handoff Latency**: < 500ms between online/offline transitions
- **Cache Hit Rate**: > 90% for next track availability
- **Sync Accuracy**: 100% position recovery within 2 seconds
- **Storage Efficiency**: < 100MB average cache size

### User Experience Metrics
- **Seamless Transitions**: Users don't notice connection drops
- **Control Availability**: Always have playback controls
- **State Preservation**: Resume exactly where offline playback ended

## Competitive Analysis

### LyrPlay vs Existing Solutions

**Spotify/Apple Music**:
- ✅ Offline playlists
- ❌ Requires manual download
- ❌ Limited to specific playlists

**LyrPlay Advantage**:
- ✅ **Automatic caching** of current queue
- ✅ **Seamless handoff** during network interruptions
- ✅ **Server integration** with position sync
- ✅ **No manual intervention** required

## Risk Assessment & Mitigation

### Technical Risks
1. **Storage Limitations**: Mitigate with smart cache management
2. **Battery Impact**: Intelligent download scheduling and low battery detection
3. **Server Sync Conflicts**: Implement robust conflict resolution
4. **CBass Integration**: Test thoroughly with local file playback

### User Experience Risks
1. **Confusion about modes**: Clear status indicators and transitions
2. **Unexpected behavior**: Comprehensive user education and documentation
3. **Storage complaints**: Transparent cache size management

## Conclusion

This offline playback feature will establish LyrPlay as the **premier Squeezebox client** by solving a fundamental limitation of the ecosystem. The implementation leverages existing infrastructure (playlist_loop data, download URLs) while providing a modern, user-friendly experience that rivals commercial streaming apps.

**Key Success Factors**:
1. **Seamless operation** - Users shouldn't think about online/offline modes
2. **Reliable handoffs** - No audio interruptions during transitions
3. **Intuitive controls** - Clear status and simple interface during offline mode
4. **Perfect sync** - Server state always matches reality when reconnected

This feature transforms LyrPlay from a simple SlimProto client into a **hybrid streaming/offline music player** that provides the best of both worlds.