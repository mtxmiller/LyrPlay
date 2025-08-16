# **CBass Audio Library Migration Plan**

**Created**: August 16, 2025  
**Project**: LyrPlay iOS Audio Streaming App  
**Goal**: Replace StreamingKit with CBass audio library for superior FLAC support and audio performance  

---

## **Executive Summary**

This plan outlines the migration from StreamingKit to CBass audio library in LyrPlay, our professional iOS audio streaming application. The migration will eliminate current FLAC seeking limitations while maintaining all existing functionality and significantly improving audio capabilities.

**Key Benefits**:
- ✅ **Native FLAC Seeking**: Eliminates StreamingKit error 2 on FLAC seeking
- ✅ **Professional Audio Foundation**: Industry-standard BASS library  
- ✅ **Enhanced Performance**: Better audio quality, lower latency, reduced memory usage
- ✅ **Future-Proofing**: More flexible foundation for advanced audio features

---

## **Current State Analysis**

### **LyrPlay (Current StreamingKit Implementation)**
✅ **Mature iOS Audio Streaming App**
- **StreamingKit-based AudioPlayer**: Native FLAC support, network streaming, comprehensive delegate system
- **SlimProto Integration**: Full LMS server protocol implementation with command handlers
- **Audio Management**: Professional audio session handling, interruption management, now playing integration
- **FLAC Toggle Feature**: User-configurable FLAC support with auto-reconnection
- **Background Audio**: Proper iOS background modes and audio session management

**Current Architecture**:
```
AudioPlayer.swift (StreamingKit)
├── STKAudioPlayer core engine
├── STKAudioPlayerDelegate callbacks
├── SlimProto integration (commandHandler)
├── Track end detection & metadata handling
└── Audio session coordination
```

**Key Integration Points**:
- `commandHandler?.notifyTrackEnded()` - SlimProto track transitions
- `commandHandler?.handleStreamConnected()` - Stream establishment
- `delegate?.audioPlayerDidStartPlaying()` - UI state updates
- Audio session management for background playback

### **CBass Library (Available in Downloads)**
✅ **Professional Audio Library**
- **BASS 2.14.17**: Core audio engine with comprehensive format support
- **BASSFLAC 2.4.5.5**: Native FLAC support including Ogg FLAC streams
- **Network Streaming**: BASS_StreamCreateURL for HTTP/HTTPS streaming
- **iOS Integration**: Complete xcframework support with Swift wrapper
- **Advanced Features**: Superior seeking, metadata extraction, buffer management

**CBass Capabilities**:
```
Bass Core Library
├── BASS_StreamCreateURL() - Network streaming
├── BASS_ChannelPlay/Pause/Stop() - Playback control
├── BASS_ChannelSetSync() - Event callbacks
├── BASS_ChannelGetPosition/Length() - Time tracking
└── BASSFLAC addon - Native FLAC support
```

---

## **Migration Strategy: StreamingKit → CBass**

### **Phase 1: Foundation Setup (Week 1)**

#### **1.1 Project Configuration**
- **Remove StreamingKit Dependency**:
  ```ruby
  # Remove from Podfile:
  # pod 'StreamingKit'
  ```
- **Add CBass Swift Package**:
  ```
  Repository: https://github.com/Treata11/CBass
  Version: Latest stable release
  ```
- **Update Build Settings**:
  - Configure BASS frameworks linking
  - Maintain existing background audio modes
  - Test basic CBass initialization

#### **1.2 Development Environment**
- **Create Clean CBass Branch** from current main
- **Preserve Existing Implementation** for rollback capability
- **Set Up Testing Environment** with actual LMS server

### **Phase 2: Core Audio Engine Replacement (Week 1-2)**

#### **2.1 CBassAudioPlayer Class Structure**
```swift
class CBassAudioPlayer: NSObject {
    // MARK: - Core Components
    private var currentStream: HSTREAM = 0
    private let audioQueue = DispatchQueue(label: "com.lyrplay.cbass", qos: .userInitiated)
    
    // MARK: - Integration Points (Preserve Exact Interface)
    weak var delegate: AudioPlayerDelegate?
    weak var commandHandler: SlimProtoCommandHandler?
    
    // MARK: - State Management
    private var metadataDuration: TimeInterval = 0.0
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
}
```

#### **2.2 Core Method Implementation**
```swift
// Network streaming with BASS
func playStream(urlString: String) {
    cleanup() // Remove previous stream
    
    currentStream = BASS_StreamCreateURL(
        urlString,
        0,                    // offset
        BASS_STREAM_BLOCK |   // blocking mode for network
        BASS_STREAM_STATUS,   // enable status callbacks
        nil, nil              // callback params
    )
    
    setupCallbacks()
    BASS_ChannelPlay(currentStream, FALSE)
}

// Native FLAC seeking (major improvement!)
func seekToPosition(_ time: Double) {
    let bytes = BASS_ChannelSeconds2Bytes(currentStream, time)
    BASS_ChannelSetPosition(currentStream, bytes, BASS_POS_BYTE)
}
```

#### **2.3 BASS Callback System**
```swift
// Replace STKAudioPlayerDelegate with BASS callbacks
private let statusProc: SYNCPROC = { handle, channel, data, user in
    let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user!).takeUnretainedValue()
    
    switch data {
    case BASS_SYNC_END:
        // CRITICAL: Maintain exact SlimProto integration
        player.commandHandler?.notifyTrackEnded()
        DispatchQueue.main.async {
            player.delegate?.audioPlayerDidReachEnd()
        }
    case BASS_SYNC_STALL:
        DispatchQueue.main.async {
            player.delegate?.audioPlayerDidStall()
        }
    // Additional callbacks for position updates, buffering, etc.
    }
}
```

### **Phase 3: Advanced Features Integration (Week 2)**

#### **3.1 FLAC Support Enhancement**
```swift
func initializeAudio() {
    // Initialize BASS core
    BASS_Init(-1, 44100, 0, nil, nil)
    
    // Initialize BASSFLAC addon
    BASSFLAC_Init()
    
    // Configure for optimal LMS streaming
    BASS_SetConfig(BASS_CONFIG_NET_TIMEOUT, 15000)  // 15s timeout
    BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
    BASS_SetConfig(BASS_CONFIG_BUFFER, 500)         // 500ms playback buffer
}
```

#### **3.2 Audio Session Integration**
```swift
// Maintain existing AudioSessionManager integration
func setupForLosslessAudio() {
    // Use existing AudioSessionManager patterns
    audioSessionManager.setupForLosslessAudio()
    
    // BASS-specific optimizations
    BASS_SetConfig(BASS_CONFIG_UPDATEPERIOD, 5)     // 5ms update period
    BASS_SetConfig(BASS_CONFIG_UPDATETHREADS, 2)    // Dual-threaded updates
}
```

#### **3.3 SlimProto Integration Preservation**
```swift
// CRITICAL: Maintain exact integration points
func setupCallbacks() {
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    
    // Stream connection (STMc command)
    BASS_ChannelSetSync(currentStream, BASS_SYNC_META, 0, { _, _, _, user in
        let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user!).takeUnretainedValue()
        player.commandHandler?.handleStreamConnected()
    }, selfPtr)
    
    // Track end detection (STMd command)
    BASS_ChannelSetSync(currentStream, BASS_SYNC_END, 0, statusProc, selfPtr)
    
    // Position updates (existing Material skin integration)
    BASS_ChannelSetSync(currentStream, BASS_SYNC_POS, 
        BASS_ChannelSeconds2Bytes(currentStream, 1.0), statusProc, selfPtr)
}
```

### **Phase 4: Quality & Performance Optimization (Week 2-3)**

#### **4.1 Buffer Management**
```swift
// Format-specific optimization
func configureForFormat(_ format: String) {
    switch format.uppercased() {
    case "FLAC", "ALAC":
        BASS_SetConfig(BASS_CONFIG_BUFFER, 1000)        // 1s buffer for lossless
        BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 16384)   // 16KB network buffer
    case "AAC":
        BASS_SetConfig(BASS_CONFIG_BUFFER, 500)         // 500ms for AAC
        BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
    case "MP3":
        BASS_SetConfig(BASS_CONFIG_BUFFER, 750)         // 750ms for MP3 streams
        BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
    }
}
```

#### **4.2 Error Handling & Recovery**
```swift
enum CBassError: Error, LocalizedError {
    case streamCreationFailed(Int32)
    case playbackFailed(Int32)
    case seekFailed(Int32)
    case networkError(Int32)
    
    var errorDescription: String? {
        switch self {
        case .streamCreationFailed(let code):
            return "Stream creation failed: \(bassErrorDescription(code))"
        // Additional error cases...
        }
    }
}

private func handleBassError(_ context: String) {
    let errorCode = BASS_ErrorGetCode()
    os_log(.error, log: logger, "%{public}s: BASS error %d", context, errorCode)
    
    // Implement retry logic for network errors
    if errorCode == BASS_ERROR_FILEOPEN {
        // Network retry logic
    }
}
```

#### **4.3 Memory Management**
```swift
private func cleanup() {
    if currentStream != 0 {
        BASS_ChannelStop(currentStream)
        BASS_StreamFree(currentStream)
        currentStream = 0
    }
}

deinit {
    cleanup()
    BASS_Free() // Clean up BASS resources
}
```

### **Phase 5: Testing & Validation (Week 3)**

#### **5.1 Functionality Testing**
- ✅ **All existing features work identically**
- ✅ **FLAC seeking works natively** (major improvement!)
- ✅ **Background audio preserved**
- ✅ **Lock screen controls functional**
- ✅ **Position recovery validated**
- ✅ **Track transitions seamless**
- ✅ **Multi-server setup compatible**

#### **5.2 Performance Testing**
- ✅ **Memory usage comparison** (target: ≤ StreamingKit usage)
- ✅ **CPU usage analysis** (target: ≤ StreamingKit usage)
- ✅ **Battery life impact** (target: improvement due to efficiency)
- ✅ **Audio quality verification** (target: equal or better)
- ✅ **Network reliability** (various stream formats and qualities)

#### **5.3 Integration Testing**
- ✅ **SlimProto protocol compliance** maintained exactly
- ✅ **Material skin integration** preserved
- ✅ **Settings management** (FLAC toggle, buffer sizes)
- ✅ **Server discovery** and connection handling
- ✅ **Interruption handling** (calls, other apps)

---

## **Technical Implementation Details**

### **Interface Compatibility Matrix**

| **StreamingKit Method** | **CBass Implementation** | **Notes** |
|------------------------|---------------------------|-----------|
| `STKAudioPlayer.play(url:)` | `BASS_StreamCreateURL()` | Direct replacement |
| `audioPlayer.pause()` | `BASS_ChannelPause()` | 1:1 mapping |
| `audioPlayer.resume()` | `BASS_ChannelPlay()` | 1:1 mapping |
| `audioPlayer.seek(toTime:)` | `BASS_ChannelSetPosition()` | **Native FLAC seeking!** |
| `audioPlayer.progress` | `BASS_ChannelGetPosition()` | Time calculation needed |
| `audioPlayer.duration` | `BASS_ChannelGetLength()` | Time calculation needed |
| `STKAudioPlayerDelegate` | `BASS_ChannelSetSync()` | Callback bridge required |

### **FLAC Seeking Improvement**

**Current (StreamingKit)**:
```
FLAC seek → StreamingKit Error 2 → Server transcode workaround needed
```

**New (CBass)**:
```
FLAC seek → BASS_ChannelSetPosition() → Direct seeking works natively!
```

**Benefits**:
- ✅ No server-side transcode rules needed
- ✅ Instant seeking in FLAC files
- ✅ Reduced server CPU load
- ✅ Better user experience

### **Dependencies & Package Management**

**Remove**:
```ruby
# Podfile
pod 'StreamingKit'  # Remove this line
```

**Add**:
```
// Swift Package Manager
Repository: https://github.com/Treata11/CBass
Products: Bass, BassFLAC
```

**Project Configuration**:
```
// Required frameworks (automatic with CBass)
- Bass.xcframework
- BassFLAC.xcframework
- Audio background mode (preserved)
```

---

## **Risk Assessment & Mitigation**

### **Low Risk Factors**
- ✅ **Interface Preservation**: Maintaining exact AudioPlayerDelegate interface
- ✅ **Architecture Stability**: No changes to SlimProto communication patterns
- ✅ **Gradual Migration**: Phase-based approach with thorough testing
- ✅ **Rollback Capability**: Git branching allows instant rollback

### **Mitigation Strategies**
- ✅ **Parallel Development**: Keep StreamingKit available during development
- ✅ **Interface Compatibility**: CBassAudioPlayer implements identical public interface
- ✅ **Comprehensive Testing**: Each phase validated before proceeding
- ✅ **Performance Monitoring**: Continuous comparison with baseline metrics

### **Success Criteria Validation**
- ✅ **Functional Parity**: All features work exactly as before
- ✅ **FLAC Enhancement**: Native seeking demonstrably better
- ✅ **Performance Metrics**: Equal or better than StreamingKit
- ✅ **User Experience**: No degradation in app responsiveness
- ✅ **App Store Ready**: No compliance issues introduced

---

## **Implementation Timeline**

### **Week 1: Foundation & Core Engine**
- **Day 1-2**: Project setup, dependency management, CBass initialization
- **Day 3-4**: CBassAudioPlayer class creation, basic streaming implementation
- **Day 5-7**: Core playback methods, basic callback system

### **Week 2: Advanced Features & Integration**
- **Day 1-3**: FLAC support integration, seeking implementation
- **Day 4-5**: SlimProto integration preservation, audio session management
- **Day 6-7**: Buffer optimization, error handling, performance tuning

### **Week 3: Testing & Validation**
- **Day 1-3**: Comprehensive functionality testing, performance benchmarking
- **Day 4-5**: Integration testing with LMS servers, edge case validation
- **Day 6-7**: App Store preparation, final validation

### **Week 4: Release Preparation**
- **Day 1-2**: Final performance validation, memory leak testing
- **Day 3-4**: App Store submission preparation, release notes
- **Day 5**: App Store submission (if all criteria met)

---

## **Success Metrics**

### **Functional Success**
- ✅ **100% feature parity** with existing StreamingKit implementation
- ✅ **FLAC seeking works** without server-side transcoding
- ✅ **All SlimProto integration** preserved and functioning
- ✅ **Audio quality** equals or exceeds current implementation

### **Performance Success**
- ✅ **Memory usage** ≤ current StreamingKit baseline
- ✅ **CPU usage** ≤ current StreamingKit baseline  
- ✅ **Battery life** equal or improved
- ✅ **Network efficiency** equal or improved

### **Quality Success**
- ✅ **Zero regressions** in existing functionality
- ✅ **Improved user experience** with native FLAC seeking
- ✅ **App Store compliance** maintained
- ✅ **Professional audio quality** throughout

---

## **Post-Migration Benefits**

### **Immediate Benefits**
- ✅ **Native FLAC Seeking**: Eliminates current limitation and improves UX
- ✅ **Reduced Server Load**: No transcoding needed for FLAC seeking
- ✅ **Professional Foundation**: Industry-standard audio library
- ✅ **Enhanced Reliability**: More mature and tested audio engine

### **Long-term Benefits**
- ✅ **Advanced Audio Features**: Foundation for future enhancements
- ✅ **Better Format Support**: Native support for more audio formats
- ✅ **Performance Optimization**: More efficient audio processing pipeline
- ✅ **Competitive Advantage**: Superior audio capabilities vs competitors

### **Developer Benefits**
- ✅ **Better Documentation**: BASS has extensive documentation and community
- ✅ **Active Support**: Professional library with ongoing development
- ✅ **Flexibility**: More configuration options for audio optimization
- ✅ **Future-Proofing**: Stable API with long-term support commitment

---

## **Conclusion**

This migration plan provides a comprehensive roadmap for replacing StreamingKit with CBass while maintaining all existing functionality and significantly improving audio capabilities. The phase-based approach ensures thorough testing and minimal risk, while the focus on interface preservation guarantees seamless integration with existing SlimProto and UI systems.

**The primary benefit - native FLAC seeking - will eliminate the current StreamingKit limitation and provide users with the high-quality audio experience they expect from a professional streaming application.**

---

**Document Version**: 1.0  
**Last Updated**: August 16, 2025  
**Next Review**: Phase 1 Completion  