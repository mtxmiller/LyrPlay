# CarPlay Stream Reinitialization Fix - Implementation Log

**Date**: January 2025  
**Issue**: CarPlay play/pause commands don't work after reconnection, requiring track skip or device-initiated playback to establish proper audio routing  
**Root Cause**: PLAY/PAUSE commands expect existing BASS stream to be properly routed, while NEXT/PREVIOUS commands create fresh streams with current routing

## Problem Analysis (iOS Audio Expert)

**Working Commands (NEXT/PREVIOUS)**:
- Trigger `["playlist", "index", "+1"]` server commands
- Result in complete `playStream()` call with fresh `BASS_StreamCreateURL()`
- New stream handles automatically get current CarPlay routing

**Broken Commands (PLAY/PAUSE)**:
- Send `["pause", "0/1"]` server commands  
- Only change playback state of existing stream handle
- Existing stream handle still bound to pre-CarPlay audio route
- Audio goes into "abyss" (wrong output route)

## Solution: Force Stream Reinitialization on CarPlay Route Changes

### Files Modified

#### 1. AudioPlayer.swift

**Added Import**:
```swift
// Line 8: Added AVFoundation import
import AVFoundation
```

**Added Properties** (Lines 51-53):
```swift
// MARK: - CarPlay Audio Route Integration
private var currentStreamURL: String = ""
private var audioRouteObserver: NSObjectProtocol?
```

**Modified Initialization** (Lines 58-63):
```swift
override init() {
    super.init()
    setupCBass()
    setupAudioRouteMonitoring()  // <- ADDED
    os_log(.info, log: logger, "AudioPlayer initialized with CBass and CarPlay route monitoring")  // <- MODIFIED
}
```

**Added BASS iOS Integration** (Lines 81-82):
```swift
// CRITICAL: Enable iOS audio session integration for CarPlay
BASS_SetConfig(DWORD(BASS_CONFIG_IOS_MIXAUDIO), 1)
```

**Added Route Monitoring Methods** (Lines 97-204):
```swift
// MARK: - CarPlay Audio Route Integration
private func setupAudioRouteMonitoring() {
    audioRouteObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        self?.handleAudioRouteChange(notification)
    }
    
    os_log(.info, log: logger, "✅ Audio route monitoring setup for CarPlay integration")
}

@objc private func handleAudioRouteChange(_ notification: Notification) {
    guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else {
        return
    }
    
    let reasonString = routeChangeReasonString(routeChangeReason)
    os_log(.info, log: logger, "🔀 Audio route change detected: %{public}s", reasonString)
    
    switch routeChangeReason {
    case .newDeviceAvailable, .oldDeviceUnavailable:
        // Check if this is a CarPlay route change
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let isCarPlay = currentRoute.outputs.contains { output in
            output.portType == .carAudio
        }
        
        if isCarPlay {
            os_log(.info, log: logger, "🚗 CarPlay detected - reconfiguring BASS for CarPlay audio routing")
            reconfigureBassForCarPlay()
        } else {
            os_log(.info, log: logger, "📱 Non-CarPlay route - using standard BASS configuration")
            reconfigureBassForStandardRoute()
        }
        
    case .routeConfigurationChange:
        os_log(.info, log: logger, "🔧 Route configuration changed - checking CarPlay status")
        // Handle configuration changes that might affect CarPlay
        
    default:
        os_log(.info, log: logger, "🔀 Other route change: %{public}s", reasonString)
    }
}

private func reconfigureBassForCarPlay() {
    // CRITICAL FIX: Instead of complex BASS reinitialization, simply invalidate current stream
    // This forces PLAY commands to create fresh streams with proper CarPlay routing
    // (Same approach that makes NEXT/PREVIOUS commands work)
    
    let wasPlaying = (currentStream != 0 && BASS_ChannelIsActive(currentStream) == DWORD(BASS_ACTIVE_PLAYING))
    let currentPosition = getCurrentTime()
    
    os_log(.info, log: logger, "🚗 CarPlay route change - invalidating stream for fresh routing (was playing: %{public}@, position: %.2f)", wasPlaying ? "true" : "false", currentPosition)
    
    // CRITICAL: Stop and free current stream to force reinitialization
    if currentStream != 0 {
        BASS_ChannelStop(currentStream)
        BASS_StreamFree(currentStream)
        currentStream = 0
        os_log(.info, log: logger, "🚗 Stream invalidated - next PLAY command will create fresh stream with CarPlay routing")
    }
    
    // DON'T restart stream here - let the server's PLAY command trigger fresh stream creation
    // This ensures PLAY/PAUSE commands behave like NEXT/PREVIOUS (fresh stream = proper routing)
    
    // Save state for recovery if needed
    if wasPlaying && !currentStreamURL.isEmpty {
        os_log(.info, log: logger, "🚗 Stream will be recreated on next PLAY command: %{public}s at position %.2f", currentStreamURL, currentPosition)
        
        // Notify command handler that stream was invalidated for CarPlay
        commandHandler?.notifyStreamInvalidatedForCarPlay()
    }
}

private func reconfigureBassForStandardRoute() {
    // Standard route handling - currently no special action needed
    // Could be extended for other route types in the future
    os_log(.info, log: logger, "📱 Standard audio route - no reconfiguration needed")
}

private func routeChangeReasonString(_ reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .unknown: return "Unknown"
    case .newDeviceAvailable: return "New Device Available"
    case .oldDeviceUnavailable: return "Old Device Unavailable"
    case .categoryChange: return "Category Change"
    case .override: return "Override"
    case .wakeFromSleep: return "Wake From Sleep"
    case .noSuitableRouteForCategory: return "No Suitable Route"
    case .routeConfigurationChange: return "Route Configuration Change"
    @unknown default: return "Unknown Route Change"
    }
}
```

**Modified playStream Method** (Lines 236-238):
```swift
// Store current URL for CarPlay route recovery
currentStreamURL = urlString
```

**Modified play() Method** (Lines 302-306):
```swift
func play() {
    guard currentStream != 0 else { 
        os_log(.info, log: logger, "⚠️ PLAY command with no active stream - stream was invalidated (likely for CarPlay)")
        return 
    }
    // ... rest unchanged
}
```

**Modified deinit** (Lines 577-580):
```swift
// Clean up audio route observer
if let observer = audioRouteObserver {
    NotificationCenter.default.removeObserver(observer)
}
```

#### 2. SlimProtoCommandHandler.swift

**Added Method** (Lines 611-617):
```swift
// MARK: - CarPlay Integration
func notifyStreamInvalidatedForCarPlay() {
    os_log(.info, log: logger, "🚗 Stream invalidated for CarPlay route change - next PLAY command will create fresh stream")
    // Mark stream as inactive so PLAY commands trigger new stream creation
    isStreamActive = false
    streamPosition = 0.0
}
```

#### 3. SlimProtoCoordinator.swift

**Enhanced PLAY Command Processing** (Lines 1193-1208):
```swift
// CRITICAL: For play commands, ensure we have a working SlimProto connection
if command.lowercased() == "play" {
    self.ensureSlimProtoConnection()
    
    // CRITICAL FIX: Check if stream was invalidated for CarPlay
    if self.audioManager.getPlayerState() == "No Stream" {
        os_log(.info, log: self.logger, "🚗 PLAY command with no active stream - likely invalidated for CarPlay")
        os_log(.info, log: self.logger, "🚗 Forcing fresh stream creation like NEXT/PREVIOUS commands")
        
        // Force fresh stream creation by requesting current track status
        // This mimics what NEXT/PREVIOUS commands do to get fresh streams
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            os_log(.info, log: self.logger, "🚗 Requesting fresh metadata to trigger stream creation")
            self.fetchCurrentTrackMetadata()
        }
    }
}
```

#### 4. ContentView.swift

**Enhanced App Open Recovery** (Lines 165-174):
```swift
// CRITICAL FIX: Only perform recovery if app is NOT already playing
let currentState = audioManager.getPlayerState()

if currentState == "Playing" {
    os_log(.info, log: logger, "📱 App Open Recovery: Skipping - already playing (state: %{public}s)", currentState)
} else {
    os_log(.info, log: logger, "📱 App Open Recovery: Proceeding - not playing (state: %{public}s)", currentState)
    slimProtoCoordinator.performAppOpenRecovery()
}
```

## How the Fix Works

### 1. Route Change Detection
- `AVAudioSession.routeChangeNotification` detects when CarPlay connects/disconnects
- `AVAudioSessionRouteChangeReason.newDeviceAvailable` with `.carAudio` port type identifies CarPlay

### 2. Stream Invalidation Strategy  
- Instead of trying to reconfigure BASS with new routing, **invalidate the stream entirely**
- Set `currentStream = 0` to force fresh stream creation
- This makes PLAY commands behave like NEXT/PREVIOUS commands

### 3. Smart PLAY Command Enhancement
- When PLAY command processed, check `audioManager.getPlayerState() == "No Stream"`
- If no stream exists, request fresh track metadata (`fetchCurrentTrackMetadata()`)
- Server responds with current track info → triggers `playStream()` with fresh CarPlay routing

### 4. Prevent Duplicate Recovery
- App Open Recovery now checks if already playing before running
- Prevents conflicts with lock screen recovery

## Expected Behavior After Fix

1. **CarPlay Connects** → Audio route change detected → Current stream invalidated → Logs show stream invalidation
2. **CarPlay Play Button Pressed** → MPRemoteCommandCenter → `sendLockScreenCommand("play")` → Detects no stream → Requests server status → Fresh stream created with CarPlay routing → **Audio works immediately**
3. **No More Track Skipping Required** → PLAY/PAUSE should work on first press

## Rollback Instructions

To undo this fix completely:

### 1. AudioPlayer.swift
- Remove `import AVFoundation` (line 8)
- Remove CarPlay properties: `currentStreamURL`, `audioRouteObserver` (lines 51-53)  
- Restore original `init()` method without `setupAudioRouteMonitoring()`
- Remove `BASS_SetConfig(DWORD(BASS_CONFIG_IOS_MIXAUDIO), 1)` line
- Remove entire CarPlay route monitoring section (lines 97-204)
- Remove `currentStreamURL = urlString` from `playStream()` 
- Restore original `play()` method without CarPlay logging
- Remove audio route observer cleanup from `deinit`

### 2. SlimProtoCommandHandler.swift  
- Remove `notifyStreamInvalidatedForCarPlay()` method (lines 611-617)

### 3. SlimProtoCoordinator.swift
- Remove CarPlay stream detection logic from PLAY command processing (lines 1193-1208)
- Restore original simple `ensureSlimProtoConnection()` call only

### 4. ContentView.swift
- Remove player state check from App Open Recovery
- Restore original direct `slimProtoCoordinator.performAppOpenRecovery()` call

## Testing Notes

- Test CarPlay connect/disconnect scenarios
- Verify play/pause works immediately after CarPlay connection
- Check that NEXT/PREVIOUS still work as before  
- Confirm no regressions in regular (non-CarPlay) audio playback
- Monitor logs for "🚗" CarPlay-specific messages during testing

## Alternative Approaches Considered

1. **Complex BASS Reinitialization** - Rejected as too prone to timing issues
2. **MPRemoteCommandCenter Re-registration** - Not needed, commands work, routing is the issue  
3. **Hybrid StreamingKit/CBass** - Too complex, prefer single audio framework
4. **Audio Session Force Activation** - Doesn't solve stream routing binding issue

The chosen approach mimics the working behavior of NEXT/PREVIOUS commands to ensure consistent CarPlay audio routing.