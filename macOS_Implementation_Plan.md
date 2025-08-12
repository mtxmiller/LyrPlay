# macOS Support Implementation Plan

**Created**: August 2024  
**Goal**: Add native macOS support using AVPlayer while keeping iOS StreamingKit functionality unchanged  
**Branch**: `feature/macos-support`

## 🎯 Implementation Strategy

### **Key Decisions Made:**
1. **FLAC Toggle UI**: Show as "Not supported on macOS" with disabled toggle
2. **Architecture**: Separate `iOSAudioPlayer` and `macOSAudioPlayer` classes  
3. **Dependencies**: StreamingKit iOS-only via platform-specific Podfile

### **Core Implementation Principles:**
⚠️ **CRITICAL**: DON'T MAKE ASSUMPTIONS - SERVER IS MASTER, USE EXISTING CODE AS REFERENCE
- Follow existing SlimProto protocol patterns exactly
- Server controls playback timing and track advancement
- Client responds to server commands, doesn't make independent decisions
- Use current iOS implementation as reference for all behaviors

### **Platform-Specific Approach:**
- **iOS**: StreamingKit + User-configurable FLAC support
- **macOS**: AVPlayer + Server-side transcoding (no FLAC capabilities)

---

## 📋 Implementation Phases

### **Phase 1: Foundation (Safe) - In Progress**
- [ ] Create `AudioPlayerProtocol.swift` - shared interface
- [ ] Extract current `AudioPlayer.swift` → `iOSAudioPlayer.swift`
- [ ] Create stub `macOSAudioPlayer.swift` with AVPlayer
- [ ] Add `AudioPlayerFactory.swift` for platform detection
- [ ] Update `AudioManager.swift` to use factory pattern
- [ ] **Test**: iOS functionality completely unchanged

### **Phase 2: macOS Enablement**
- [ ] Update `Podfile` for iOS-only StreamingKit dependency
- [ ] Enable macOS target in Xcode project settings
- [ ] Update `SettingsManager.capabilitiesString` with platform logic
- [ ] Update FLAC toggle UI in `SettingsView.swift`
- [ ] **Test**: Basic macOS app launch and connection

### **Phase 3: AVPlayer Implementation**
- [ ] **REFERENCE EXISTING iOS CODE** - Don't assume, copy proven patterns
- [ ] Map StreamingKit delegate methods to AVPlayer observer patterns
- [ ] Implement server command responses exactly as iOS version does
- [ ] **Server-driven track advancement** - respond to server STRM commands only
- [ ] Mirror existing time tracking and STAT packet sending logic
- [ ] **Test**: Audio playback and server-controlled track transitions

### **Phase 4: Integration & Polish**
- [ ] Handle audio session differences between platforms
- [ ] Implement error handling and edge cases  
- [ ] Performance optimization and memory management
- [ ] Comprehensive testing on both platforms
- [ ] **Test**: Full feature parity (minus FLAC on macOS)

---

## 🏗️ Architecture Overview

### **Current State (iOS Only):**
```
AudioManager → AudioPlayer (StreamingKit) → STKAudioPlayer
```

### **Target State (Multi-Platform):**
```
AudioManager → AudioPlayerFactory → AudioPlayerProtocol
                                  ├── iOSAudioPlayer (StreamingKit)
                                  └── macOSAudioPlayer (AVPlayer)
```

### **Key Components:**

#### **AudioPlayerProtocol** (New)
```swift
protocol AudioPlayerProtocol: AnyObject {
    var delegate: AudioPlayerDelegate? { get set }
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    
    func play(url: URL)
    func pause()
    func stop()
    func seek(to time: Double)
    func setVolume(_ volume: Float)
}
```

#### **AudioPlayerFactory** (New)
```swift
class AudioPlayerFactory {
    static func createAudioPlayer() -> AudioPlayerProtocol {
        #if os(iOS)
            return iOSAudioPlayer()
        #elseif os(macOS)
            return macOSAudioPlayer()
        #endif
    }
}
```

---

## 🔄 StreamingKit → AVPlayer Feature Mapping

| StreamingKit Feature | AVPlayer Equivalent | Implementation Notes |
|---------------------|---------------------|---------------------|
| `STKAudioPlayer.play(url:)` | `AVPlayer.replaceCurrentItem()` | URL-based streaming |
| `STKAudioPlayer.pause()` | `AVPlayer.pause()` | Direct mapping |
| `STKAudioPlayer.resume()` | `AVPlayer.play()` | Direct mapping |
| `STKAudioPlayer.seek(toTime:)` | `AVPlayer.seek(to:)` | CMTime conversion needed |
| `STKAudioPlayer.currentTimeInFrames` | `AVPlayer.currentTime()` | Time format conversion |
| `STKAudioPlayerDelegate` | `AVPlayerTimeObserver` | Different callback patterns |
| State tracking | `AVPlayer.timeControlStatus` | Different state system |

---

## 🎛️ Platform-Specific Configurations

### **Capabilities String Logic:**
```swift
// In SettingsManager.swift
var capabilitiesString: String {
    let baseCapabilities = "Model=squeezelite,AccuratePlayPoints=1,HasDigitalOut=1,HasPolarityInversion=1,Balance=1,Firmware=v1.0.0-iOS,ModelName=SqueezeLite,MaxSampleRate=48000"
    
    #if os(iOS)
        let formats = flacEnabled ? "flc,aac,mp3" : "aac,mp3"
    #elseif os(macOS)
        let formats = "aac,mp3"  // Never FLAC - server transcodes
    #endif
    
    return "\(baseCapabilities),\(formats)"
}
```

### **FLAC Toggle UI Logic:**
```swift
// In SettingsView.swift - Audio Settings Section
#if os(iOS)
    Text(isReconnecting ? "Reconnecting..." : "Disabled = MP3 transcode • Auto-reconnects")
        .foregroundColor(isReconnecting ? .blue : .secondary)
    Toggle("", isOn: $settings.flacEnabled)
        .disabled(isReconnecting)
#elseif os(macOS)
    Text("Not supported on macOS • Server transcodes")
        .foregroundColor(.secondary)
    Toggle("", isOn: .constant(false))
        .disabled(true)
#endif
```

### **Podfile Configuration:**
```ruby
platform :ios, '14.0'

target 'LMS_StreamTest' do
  use_frameworks!
  
  pod 'CocoaAsyncSocket'
  
  # iOS-only StreamingKit dependency
  pod 'StreamingKit', :platforms => [:ios]
end
```

---

## ⚠️ Known Challenges & Solutions

### **Track Advancement Issue (Historical)**
- **Problem**: macOS + StreamingKit caused tracks not to advance properly
- **Root Cause**: Likely AVPlayer integration differences, NOT server protocol issues
- **Solution**: Use AVPlayer on macOS which historically worked fine
- **Implementation Approach**: 
  - **DON'T change server communication patterns**
  - Copy exact SlimProto command handling from iOS implementation
  - Server sends STRM commands → client responds exactly like iOS version
  - **Testing Focus**: Verify track transitions work with server-controlled advancement

### **Audio Session Management**
- **iOS**: Complex audio session management for background playback
- **macOS**: Different audio session requirements
- **Solution**: Platform-specific implementations in respective AudioPlayer classes

### **FLAC Support**
- **iOS**: Native FLAC via StreamingKit (user configurable)
- **macOS**: Server-side transcoding to AAC/MP3 (always)
- **Benefit**: Leverages server's proven transcoding capabilities

---

## 🧪 Testing Strategy

### **Phase 1 Testing:**
- [ ] iOS functionality unchanged after refactoring
- [ ] All existing audio features work identically
- [ ] No performance regression

### **Phase 2 Testing:**
- [ ] macOS app launches without crashes
- [ ] Connects to LMS server successfully  
- [ ] No FLAC in capabilities string sent to server

### **Phase 3 Testing:**
- [ ] Audio playback works on macOS
- [ ] Track advancement functions correctly (**Key test**)
- [ ] Seeking and position tracking accurate
- [ ] Volume control responsive

### **Phase 4 Testing:**
- [ ] Stress testing on both platforms
- [ ] Error condition handling
- [ ] Memory leak detection
- [ ] Real-world usage scenarios

---

## 📁 File Structure Changes

### **New Files to Create:**
```
LMS_StreamTest/
├── AudioPlayer/
│   ├── AudioPlayerProtocol.swift      (New)
│   ├── AudioPlayerFactory.swift       (New)
│   ├── iOSAudioPlayer.swift          (Renamed from AudioPlayer.swift)
│   └── macOSAudioPlayer.swift        (New)
```

### **Files to Modify:**
```
├── AudioManager.swift                 (Use factory pattern)
├── SettingsManager.swift             (Platform-specific capabilities)
├── SettingsView.swift                (Platform-specific FLAC UI)
├── Podfile                           (iOS-only StreamingKit)
└── LMS_StreamTest.xcodeproj          (Enable macOS target)
```

---

## 🚀 Current Status

**Active Branch**: `feature/macos-support`  
**Current Phase**: Phase 1 - Foundation (Safe)  
**Next Steps**: 
1. Create `AudioPlayerProtocol.swift`
2. Extract current AudioPlayer to iOSAudioPlayer
3. Test iOS functionality unchanged

**Notes**: 
- iOS FLAC toggle feature completed and working
- Pull request workflow established  
- Ready to begin macOS implementation

---

## 🔄 Progress Log

### August 10, 2024
- Initial planning session completed
- Architecture decisions made
- **CRITICAL PRINCIPLE ESTABLISHED**: Server is master, use existing iOS code as reference
- Don't make assumptions about how things should work - copy proven patterns
- Implementation plan documented with emphasis on following existing protocol handling
- Ready to start Phase 1

---

*This document should be updated throughout implementation to track progress and serve as reference for future development sessions.*