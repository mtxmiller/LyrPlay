# LyrPlay Architecture Analysis for Offline Playback Implementation

**Date**: January 2025
**Purpose**: Understanding current architecture before implementing offline playback functionality

## 1. Data Flow Analysis: SlimProto → Audio → UI

### **Core Data Flow Path**

```
[LMS Server]
    ↓ SlimProto Protocol
[SlimProtoClient] → [SlimProtoCommandHandler] → [SlimProtoCoordinator]
    ↓ STRM Commands
[AudioManager] → [AudioPlayer (CBass)]
    ↓ Track Info
[NowPlayingManager] → [Lock Screen/UI]
```

### **Detailed Flow Breakdown**

#### **1.1 SlimProto Command Reception**
**File**: `SlimProtoCommandHandler.swift:44-76`
```swift
func processCommand(_ command: SlimProtoCommand) {
    switch command.type {
    case "strm":
        processServerCommand(command.type, payload: command.payload)
    // ... other commands
    }
}
```

#### **1.2 STRM Command Processing**
**File**: `SlimProtoCommandHandler.swift:170-190`
```swift
private func processServerCommand(_ command: String, payload: Data) {
    guard command == "strm" else { return }

    if payload.count >= 24 {
        let streamCommand = payload[0]
        let autostart = payload[1]
        let format = payload[2]

        // Format detection: FLAC (0x66), Opus (0x67), AAC (0x61), etc.
        switch format {
            case 0x66: formatName = "FLAC"
            case 0x67: formatName = "OPUS"
            case 0x61: formatName = "AAC"
            // ... more formats
        }
    }
}
```

#### **1.3 Audio Playback Invocation**
**File**: `SlimProtoCoordinator.swift:894`
```swift
audioManager.playStreamWithFormat(urlString: url, format: format)
```

**Flow**: `AudioManager.swift:85-90` → `AudioPlayer.swift:327-338`

#### **1.4 CBass Stream Creation**
**File**: `AudioPlayer.swift:584-622`
```swift
private func createStreamForFormat(urlString: String, streamFlags: DWORD) -> HSTREAM {
    let format = currentStreamFormat // From STRM command

    switch format.uppercased() {
    case "OPUS":
        return BASS_OPUS_StreamCreateURL(urlString, ...)
    case "FLAC":
        return BASS_FLAC_StreamCreateURL(urlString, ...)
    default:
        return BASS_StreamCreateURL(urlString, ...)
    }
}
```

## 2. Track Metadata Structure & Available Fields

### **2.1 SlimProto Status Response Structure**
**File**: `SlimProtoCoordinator.swift:1502-1520`

```swift
// Server JSON-RPC response structure:
"playlist_loop": [
    {
        "id": "12345",              // Track ID (key for download URLs)
        "title": "Track Name",      // Display title
        "artist": "Artist Name",    // Artist information
        "album": "Album Name",      // Album information
        "duration": 245.5,          // Track duration in seconds
        "url": "file://server/path", // Server file path
        "artwork_url": "http://...", // Cover art URL
        "coverid": "67890",         // Alternative cover art ID
        "fileType": "FLAC",         // Audio format
        // Additional metadata fields...
    }
    // ... more tracks in queue
]
```

### **2.2 Metadata Processing**
**File**: `SlimProtoCoordinator.swift:1506-1520`
```swift
let trackTitle = firstTrack["title"] as? String ?? "LyrPlay"
let trackArtist = firstTrack["artist"] as? String ?? "Unknown Artist"
let trackAlbum = firstTrack["album"] as? String ?? "Lyrion Music Server"
let serverDuration = firstTrack["duration"] as? Double

// Artwork URL construction
if let artwork = firstTrack["artwork_url"] as? String {
    artworkURL = artwork.hasPrefix("http") ? artwork :
                 "http://\(host):\(port)\(artwork)"
} else if let coverid = firstTrack["coverid"] as? String {
    artworkURL = "http://\(host):\(port)/music/\(coverid)/cover.jpg"
}
```

### **2.3 Available Fields for Offline Cache**
- ✅ **Track ID**: Available (`id` field) - key for download URLs
- ✅ **Metadata**: Title, artist, album, duration
- ✅ **Format**: Available via STRM command format byte
- ✅ **Queue Position**: Array index in `playlist_loop`
- ✅ **Artwork**: Multiple URL patterns available

## 3. WebView ↔ SwiftUI Communication Patterns

### **3.1 Current WebView Integration**
**File**: `ContentView.swift` (WebView implementation)

```swift
// Material LMS web interface embedded in SwiftUI
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // Configure for Material skin
        return webView
    }
}
```

### **3.2 State Management Pattern**
```swift
@StateObject private var coordinator = SlimProtoCoordinator()
@StateObject private var audioManager = AudioManager.shared
@StateObject private var settings = SettingsManager.shared

// UI reflects coordinator state changes via @Published properties
```

### **3.3 Connection Status UI Handling**
**Current Pattern**: WebView visibility controlled by connection state
**Implication**: Need to add offline UI layer that can replace WebView

## 4. Connection Management & Failure Handling

### **4.1 Connection Monitoring**
**File**: `SlimProtoConnectionManager.swift`
```swift
class SlimProtoConnectionManager: ObservableObject {
    @Published var connectionStatus: ConnectionStatus = .disconnected
    private let networkMonitor = NWPathMonitor()

    // Monitors both network connectivity and LMS server reachability
}
```

### **4.2 Current Failure Recovery**
**File**: `SlimProtoCoordinator.swift:262-520` (Recovery mechanisms)
- **App Open Recovery**: Playlist jump with position restoration
- **CarPlay Recovery**: Server reconnection with state sync
- **Lock Screen Recovery**: Position-based resumption

**Pattern**: All recovery methods use playlist jump commands to restore server state

### **4.3 Reconnection Logic**
```swift
// Connection restoration triggers:
1. Network availability restoration
2. Server reachability confirmation
3. SlimProto socket reconnection
4. State synchronization via JSON-RPC
```

## 5. File Storage Patterns & Permissions

### **5.1 Current Storage Usage**
**UserDefaults Keys**:
- `lyrplay_recovery_index`: Playlist position
- `lyrplay_recovery_position`: Playback position
- Player preferences and server configurations

### **5.2 Documents Directory Access**
```swift
let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
// App has full read/write access to Documents directory
```

### **5.3 Background Processing Capabilities**
**Info.plist Background Modes**:
- `audio`: Background audio playback
- `background-fetch`: Background updates
- `background-processing`: Background tasks

## 6. Settings Architecture & Extension Points

### **6.1 SettingsManager Structure**
**File**: `SettingsManager.swift`
```swift
class SettingsManager: ObservableObject {
    // Server configuration
    @Published var activeServerHost: String
    @Published var activeServerWebPort: Int

    // Audio settings
    @Published var flacBufferSeconds: Int = 10
    @Published var networkBufferKB: Int = 64

    // Extension point: Easy to add offline settings here
}
```

### **6.2 Settings UI Pattern**
**File**: `SettingsView.swift`
```swift
// SwiftUI Form-based settings with @AppStorage bindings
Form {
    Section("Audio Settings") {
        // Current settings...
        // Extension point: Add offline settings section here
    }
}
```

## 7. Audio Session Management with CBass

### **7.1 CBass Configuration**
**File**: `AudioPlayer.swift:71-103`
```swift
private func setupCBass() {
    BASS_Init(-1, 44100, 0, nil, nil)

    // CRITICAL: Manual session management
    BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), 0)  // Complete disable

    // Manual audio session setup
    setupManualAudioSession()
}
```

### **7.2 Audio Session Requirements**
```swift
func configureAudioSessionIfNeeded() {
    try audioSession.setCategory(
        .playback,
        mode: .default,
        options: []  // EMPTY required for lock screen controls
    )
}
```

**Critical Constraint**: Lock screen controls require empty category options with CBass

## 8. Manager Coordination & Communication

### **8.1 Manager Hierarchy**
```
SlimProtoCoordinator (main orchestrator)
├── SlimProtoClient (network communication)
├── SlimProtoCommandHandler (protocol processing)
├── AudioManager (audio coordination)
│   └── AudioPlayer (CBass playback)
├── NowPlayingManager (iOS integration)
└── SettingsManager (configuration)
```

### **8.2 Communication Patterns**
- **Delegate Pattern**: SlimProtoClientDelegate, AudioPlayerDelegate
- **@Published Properties**: State updates via Combine framework
- **Weak References**: Prevent retain cycles between managers

## 9. Integration Points for Offline Playback

### **9.1 Low Risk Integration Points**
- ✅ **New OfflineCacheManager**: Isolated component
- ✅ **Settings Extension**: Add to existing SettingsManager
- ✅ **Native UI Components**: Parallel to WebView, not replacing

### **9.2 Medium Risk Integration Points**
- ⚠️ **AudioPlayer Enhancement**: Add local file playback alongside streaming
- ⚠️ **Connection Manager Extension**: Add offline state management
- ⚠️ **Metadata Flow**: Ensure offline tracks get proper metadata

### **9.3 High Risk Integration Points**
- 🚨 **SlimProto Protocol**: Must not break existing command handling
- 🚨 **Audio Session**: Must preserve CBass/lock screen compatibility
- 🚨 **WebView Integration**: UI switching must be seamless

## 10. Implementation Strategy Insights

### **10.1 Safe Implementation Approach**
1. **Create parallel components** (OfflineCacheManager, OfflineUI)
2. **Extend existing managers** with offline capabilities
3. **Use existing patterns** (delegate, @Published, settings)
4. **Preserve all current functionality** during development

### **10.2 Key Success Factors**
- **Respect CBass audio session requirements**
- **Use existing playlist_loop data structure**
- **Follow current error handling patterns**
- **Integrate with existing settings architecture**
- **Maintain SlimProto protocol compliance**

### **10.3 Critical Dependencies**
- **playlist_loop**: Primary source of queue information
- **Download URLs**: Must construct from existing server patterns
- **Track boundaries**: Use existing track end detection
- **State sync**: Use existing playlist jump recovery patterns

## Conclusion

The current LyrPlay architecture provides excellent foundation for offline playback implementation:

- ✅ **Complete queue data** already available via playlist_loop
- ✅ **Format detection** already implemented for audio optimization
- ✅ **Track transition handling** already robust with CBass
- ✅ **State recovery patterns** already proven for various scenarios
- ✅ **Settings architecture** easily extensible for offline preferences
- ✅ **Background processing** capabilities already configured

**Recommended Implementation Path**: Build offline capabilities as **extensions** to existing components rather than replacements, ensuring zero disruption to current functionality while adding powerful new capabilities.