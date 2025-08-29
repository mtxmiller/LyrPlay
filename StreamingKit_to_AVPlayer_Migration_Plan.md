# StreamingKit → AVPlayer Migration Plan

## Executive Summary

This plan outlines the step-by-step migration from StreamingKit to AVPlayer in LyrPlay. The migration will solve macOS/visionOS compatibility issues, eliminate third-party dependencies, and simplify the codebase while maintaining identical functionality.

**Timeline**: 5-7 hours of development  
**Risk Level**: Low-Medium (well-contained changes)  
**Primary Benefit**: Universal platform compatibility + simplified codebase

---

## Current State Analysis

### StreamingKit Usage Audit
- **Primary Usage**: `AudioPlayer.swift` (483 lines, core audio engine)
- **Dependencies**: Only `AudioPlayer.swift` imports StreamingKit directly
- **Integration Points**: 6 delegate methods, complex buffer management
- **Key Features**: Native FLAC support, seeking, state management

### Current Pain Points
- ❌ **macOS/visionOS crashes** - blocks App Store expansion to other platforms
- ❌ **FLAC seeking errors** - requires complex server-side transcoding setup
- ❌ **Third-party dependency** - maintenance burden, potential future compatibility issues
- ❌ **iOS-only limitation** - prevents universal app deployment

### Benefits of Migration
- ✅ **Universal Platform Support** - macOS, visionOS, iPadOS compatibility
- ✅ **Simplified Codebase** - remove 500+ lines of StreamingKit integration
- ✅ **Native iOS Framework** - better system integration, more reliable
- ✅ **No Third-Party Dependencies** - reduce maintenance burden
- ✅ **Reliable Seeking** - AVPlayer handles all formats without special configuration

---

## Migration Strategy: Piece-by-Piece Replacement

### Core Principle
**Maintain identical public API** - no changes to other components, only internal AudioPlayer.swift implementation changes.

### Implementation Approach
1. **Phase 1**: Replace core player engine (STKAudioPlayer → AVPlayer)
2. **Phase 2**: Migrate delegate system (StreamingKit callbacks → AVPlayer notifications)
3. **Phase 3**: Implement FLAC strategy (server transcoding vs native support)
4. **Phase 4**: Remove dependencies and polish

---

## Detailed Implementation Plan

### Phase 1: AVPlayer Foundation (1-2 hours)
**Risk Level**: Low  
**Goal**: Replace STKAudioPlayer with AVPlayer, maintain identical API

#### Core Changes
```swift
// BEFORE (StreamingKit)
import StreamingKit
private var audioPlayer: STKAudioPlayer!
private var lastReportedState: STKAudioPlayerState = []

// AFTER (AVPlayer)
import AVFoundation
private var avPlayer: AVPlayer!
private var avPlayerItem: AVPlayerItem?
private var timeObserver: Any?
private var playerState: PlayerState = .stopped
```

#### Method Mappings
| StreamingKit | AVPlayer Equivalent |
|--------------|-------------------|
| `audioPlayer.play(url)` | `avPlayer.replaceCurrentItem(AVPlayerItem(url:))` + `play()` |
| `audioPlayer.pause()` | `avPlayer.pause()` |
| `audioPlayer.resume()` | `avPlayer.play()` |
| `audioPlayer.stop()` | `avPlayer.pause()` + `replaceCurrentItem(nil)` |
| `audioPlayer.progress` | `avPlayer.currentTime().seconds` |
| `audioPlayer.duration` | `avPlayerItem.duration.seconds` |
| `audioPlayer.seek(toTime:)` | `avPlayer.seek(to: CMTime)` |
| `audioPlayer.volume` | `avPlayer.volume` |

#### Implementation Example
```swift
func playStream(urlString: String) {
    guard let url = URL(string: urlString) else {
        os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
        return
    }
    
    os_log(.info, log: logger, "🎵 Playing stream with AVPlayer: %{public}s", urlString)
    
    prepareForNewStream()
    
    let playerItem = AVPlayerItem(url: url)
    currentPlayerItem = playerItem
    
    if avPlayer == nil {
        avPlayer = AVPlayer(playerItem: playerItem)
        setupAVPlayer()
    } else {
        avPlayer.replaceCurrentItem(with: playerItem)
    }
    
    setupPlayerItemObservers(playerItem)
    avPlayer.play()
    
    os_log(.info, log: logger, "✅ AVPlayer playback started")
}
```

### Phase 2: Delegate System Migration (2-3 hours)
**Risk Level**: Medium  
**Goal**: Replace STKAudioPlayerDelegate with AVPlayer observations

#### StreamingKit Delegates to Replace
```swift
// Current StreamingKit delegate methods (6 total)
func audioPlayer(_ audioPlayer: STKAudioPlayer, didStartPlayingQueueItemId queueItemId: NSObject)
func audioPlayer(_ audioPlayer: STKAudioPlayer, stateChanged state: STKAudioPlayerState, previousState: STKAudioPlayerState)
func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishPlayingQueueItemId queueItemId: NSObject, with stopReason: STKAudioPlayerStopReason, andProgress progress: Double, andDuration duration: Double)
func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishBufferingSourceWithQueueItemId queueItemId: NSObject)
func audioPlayer(_ audioPlayer: STKAudioPlayer, unexpectedError errorCode: STKAudioPlayerErrorCode)
func audioPlayer(_ audioPlayer: STKAudioPlayer, didReceiveRawAudioData audioData: Data, audioDescription: AudioStreamBasicDescription)
```

#### AVPlayer Observation System
```swift
private func setupPlayerItemObservers(_ playerItem: AVPlayerItem) {
    // Track end detection
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(playerItemDidReachEnd),
        name: .AVPlayerItemDidPlayToEndTime,
        object: playerItem
    )
    
    // Stalling/buffering detection
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(playerItemStalled),
        name: .AVPlayerItemPlaybackStalled,
        object: playerItem
    )
    
    // Error handling
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(playerItemFailedToPlayToEndTime),
        name: .AVPlayerItemFailedToPlayToEndTime,
        object: playerItem
    )
    
    // Time updates (replaces periodic callbacks)
    timeObserver = avPlayer.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 1.0, preferredTimescale: 1),
        queue: .main
    ) { [weak self] time in
        self?.handleTimeUpdate(time.seconds)
    }
    
    // State changes (via KVO)
    avPlayer.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)
}

// KVO for state changes
override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard keyPath == "timeControlStatus" else { return }
    
    DispatchQueue.main.async {
        switch self.avPlayer.timeControlStatus {
        case .playing:
            self.handlePlayerStateChange(.playing)
        case .paused:
            self.handlePlayerStateChange(.paused)
        case .waitingToPlayAtSpecifiedRate:
            self.handlePlayerStateChange(.buffering)
        @unknown default:
            break
        }
    }
}
```

#### State Management
```swift
enum PlayerState {
    case stopped, playing, paused, buffering, error
}

private func handlePlayerStateChange(_ newState: PlayerState) {
    guard newState != playerState else { return }
    
    let oldState = playerState
    playerState = newState
    
    os_log(.debug, log: logger, "🔄 AVPlayer state changed: %{public}s → %{public}s", 
           oldState.description, newState.description)
    
    switch newState {
    case .playing:
        if oldState != .playing {
            delegate?.audioPlayerDidStartPlaying()
        }
    case .paused:
        delegate?.audioPlayerDidPause()
    case .stopped:
        delegate?.audioPlayerDidStop()
    case .buffering:
        delegate?.audioPlayerDidStall()
    case .error:
        delegate?.audioPlayerDidStall()
    }
}
```

### Phase 3: FLAC Strategy Implementation (1 hour)
**Risk Level**: Low (if using recommended approach)  
**Goal**: Decide and implement FLAC handling approach

#### Option A: Server Transcoding (RECOMMENDED)
**Approach**: Force server-side transcoding, remove FLAC capability from client

**Benefits**:
- ✅ Universal compatibility across all platforms
- ✅ No seeking issues - AAC seeks perfectly
- ✅ Better mobile experience - lower bandwidth
- ✅ No special server configuration required
- ✅ Simpler client implementation

**Implementation**:
```swift
// In SettingsManager.swift - Remove FLAC capability
var capabilitiesString: String {
    let baseCapabilities = "Model=squeezelite,AccuratePlayPoints=1,HasDigitalOut=1,HasPolarityInversion=1,Balance=1,Firmware=v1.0.0-iOS,ModelName=LyrPlay,MaxSampleRate=48000"
    // Force server transcoding - no FLAC capability
    let formats = "aac,mp3"  // Removed: flc (FLAC)
    return "\(baseCapabilities),\(formats)"
}

// Remove FLAC setting entirely or make it always false
@Published var flacEnabled: Bool = false  // Always false, no user control
```

**Server Behavior**:
- LMS server sees client doesn't support FLAC
- Automatically transcodes FLAC → AAC (high quality)
- Client receives properly formatted AAC streams
- Perfect seeking, no configuration needed

#### Option B: Keep FLAC Transcoding Infrastructure
**Approach**: Maintain existing server-side FLAC transcoding rules, AVPlayer receives pre-transcoded FLAC

**Benefits**:
- ✅ Maintains "native FLAC" marketing
- ✅ Users keep existing server configurations

**Risks**:
- ❌ Users still need complex server setup
- ❌ Seeking issues if misconfigured
- ❌ Additional complexity

#### Option C: Native AVPlayer FLAC (NOT RECOMMENDED)
**Approach**: Use iOS 17+ native FLAC support in AVPlayer

**Risks**:
- ❌ iOS 17+ only (limits compatibility)
- ❌ Limited FLAC support in AVPlayer
- ❌ Potential seeking issues remain
- ❌ Complex fallback logic needed

**Recommendation**: **Option A (Server Transcoding)** - simplest, most reliable, universal compatibility

### Phase 4: Dependencies and Polish (1 hour)
**Risk Level**: Low  
**Goal**: Remove StreamingKit dependencies and update project

#### Podfile Changes
```ruby
# Remove from Podfile:
# pod 'StreamingKit'

# Run after removal:
# pod install
```

#### Project Cleanup
- Update import statements
- Remove StreamingKit references in comments/logs
- Update error handling for AVPlayer-specific errors
- Test on multiple devices/simulators

#### Buffer Management Simplification
```swift
// Remove complex StreamingKit buffer configuration:
// var options = STKAudioPlayerOptions()
// options.bufferSizeInSeconds = bufferSeconds
// options.readBufferSize = readBufferSize

// Replace with simple AVPlayer buffer preference:
private func setupAVPlayer() {
    // AVPlayer handles buffering intelligently
    // Optional: Set preferred forward buffer duration
    if let playerItem = avPlayer.currentItem {
        playerItem.preferredForwardBufferDuration = TimeInterval(bufferSizeToSeconds(settings.bufferSize))
    }
}
```

---

## Testing Strategy

### Phase 1 Testing
- ✅ Basic playback (AAC, MP3 streams)
- ✅ Play/pause/stop controls
- ✅ Volume control
- ✅ Time reporting accuracy

### Phase 2 Testing  
- ✅ State change notifications to other components
- ✅ Track end detection and auto-advance
- ✅ Error handling and recovery
- ✅ Lock screen integration still works

### Phase 3 Testing
- ✅ FLAC files get transcoded to AAC by server
- ✅ No seeking errors with transcoded streams
- ✅ Quality comparison (high-bitrate AAC vs FLAC)

### Phase 4 Testing
- ✅ All platforms (iOS, macOS simulator if available)
- ✅ Memory usage comparison
- ✅ Battery usage comparison
- ✅ App Store build validation

---

## Risk Mitigation

### Low Risk Items
- Basic playback functionality
- Volume and seek controls
- Time reporting

### Medium Risk Items
- State change delegate system
- Track end detection timing
- Error handling differences

### High Risk Mitigation
- **FLAC Compatibility**: Solved by server transcoding approach
- **Platform Support**: Solved by using native AVPlayer
- **Seeking Issues**: Eliminated with AAC transcoding
- **Performance**: AVPlayer is highly optimized by Apple

### Rollback Plan
- Keep StreamingKit code in git history
- Test extensively before removing dependencies
- Can revert individual phases if issues discovered
- Maintain feature branch during development

---

## Timeline and Milestones

### Week 1: Foundation (2-3 hours)
- [ ] Phase 1: Basic AVPlayer replacement
- [ ] Phase 1 testing and validation
- [ ] Commit: "Replace STKAudioPlayer with AVPlayer foundation"

### Week 1: Integration (3-4 hours)  
- [ ] Phase 2: Delegate system migration
- [ ] Phase 2 testing - ensure all callbacks work
- [ ] Commit: "Migrate StreamingKit delegates to AVPlayer notifications"

### Week 2: Strategy & Cleanup (1-2 hours)
- [ ] Phase 3: FLAC strategy implementation  
- [ ] Phase 4: Remove dependencies and polish
- [ ] Final testing across all scenarios
- [ ] Commit: "Complete StreamingKit to AVPlayer migration"

### Total Estimated Time: 6-9 hours

---

## Success Criteria

### Functional Requirements
- [ ] All existing playback functionality preserved
- [ ] Identical API for other components (no breaking changes)
- [ ] Lock screen integration continues to work
- [ ] Server communication unaffected
- [ ] Error handling maintains user experience

### Performance Requirements  
- [ ] No degradation in audio quality
- [ ] Similar or better memory usage
- [ ] Similar or better battery life
- [ ] Faster startup time (expected with AVPlayer)

### Platform Requirements
- [ ] iOS compatibility maintained (current target)
- [ ] macOS compatibility achieved (new capability)  
- [ ] visionOS compatibility achieved (future expansion)
- [ ] App Store build validation passes

### Quality Requirements
- [ ] No audio dropouts or glitches
- [ ] Smooth seeking across all formats
- [ ] Reliable track end detection
- [ ] Proper error messaging to users

---

## Post-Migration Benefits

### Immediate Benefits
1. **Universal Platform Support** - can release on macOS App Store
2. **Simplified Codebase** - remove 500+ lines of complex integration  
3. **Improved Reliability** - native Apple framework
4. **Better User Experience** - faster startup, no seeking issues

### Long-term Benefits  
1. **Reduced Maintenance** - no third-party audio engine to maintain
2. **Future iOS Features** - automatic benefit from Apple's AVPlayer improvements
3. **Broader Market** - macOS and visionOS user expansion
4. **Development Velocity** - simpler debugging and development

### App Store Benefits
1. **Platform Expansion** - submit to macOS App Store
2. **Simplified Support** - fewer FLAC setup issues reported
3. **Better Reviews** - more reliable experience leads to higher ratings
4. **Larger User Base** - universal app reaches more users

---

## Conclusion

This migration represents a strategic improvement to LyrPlay's architecture. By moving from StreamingKit to AVPlayer, we solve current platform limitations while simplifying the codebase and improving reliability.

**Key Decision**: Recommend **Option A (Server Transcoding)** for FLAC handling - this provides the best balance of simplicity, reliability, and universal compatibility.

The piece-by-piece approach minimizes risk while ensuring no functionality is lost during the transition. The estimated 6-9 hours of development time will yield significant long-term benefits in maintainability and platform reach.

**Next Step**: Review this plan and decide whether to proceed with Phase 1 implementation.