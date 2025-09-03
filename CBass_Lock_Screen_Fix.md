# CBass Lock Screen Controls Fix Plan

## **Problem Statement**
CBass minimal implementation works great for audio playback and FLAC seeking, but lacks iOS lock screen controls integration. Unlike AVPlayer (built-in) or StreamingKit (automatic), CBass requires manual MediaPlayer framework integration.

## **Current Status**
✅ **MP3 playback**: Works perfectly  
✅ **FLAC playback**: Basic functionality (needs buffer optimization)  
✅ **Native FLAC seeking**: Core benefit achieved via `BASS_ChannelSetPosition`  
❌ **Lock screen controls**: Missing entirely  
❌ **FLAC stability**: Needs buffer tuning like previous CBass work  

## **Solution Overview**
Add minimal iOS MediaPlayer framework integration to existing CBass implementation. Focus only on essential lock screen functionality - no complex features needed.

---

## **Phase 1: Basic MediaPlayer Integration (1-2 hours)**

### **Required Imports**
Add to `AudioPlayer.swift`:
```swift
import MediaPlayer  // Add this import
```

### **1.1 AVAudioSession Setup**
Add to `setupCBass()` method after BASS_Init success:
```swift
private func setupCBass() {
    // ... existing BASS_Init code ...
    
    // ADD: Configure iOS audio session for background and lock screen
    do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default, options: [])
        try audioSession.setActive(true)
        os_log(.info, log: logger, "✅ iOS audio session configured for lock screen")
    } catch {
        os_log(.error, log: logger, "❌ Audio session setup failed: %{public}s", error.localizedDescription)
    }
}
```

### **1.2 MediaPlayer Command Center Setup**
Add new method to `AudioPlayer` class:
```swift
// MARK: - Lock Screen Integration
private func setupLockScreenControls() {
    let commandCenter = MPRemoteCommandCenter.shared()
    
    // Play command - maps to existing play() method
    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [weak self] event in
        self?.play()
        return .success
    }
    
    // Pause command - maps to existing pause() method  
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.pauseCommand.addTarget { [weak self] event in
        self?.pause()
        return .success
    }
    
    // Disable commands we don't need (server handles seeking)
    commandCenter.seekForwardCommand.isEnabled = false
    commandCenter.seekBackwardCommand.isEnabled = false
    commandCenter.skipForwardCommand.isEnabled = false
    commandCenter.skipBackwardCommand.isEnabled = false
    
    os_log(.info, log: logger, "✅ Lock screen controls configured")
}
```

### **1.3 Now Playing Info Updates**
Add method to update metadata display:
```swift
private func updateNowPlayingInfo(title: String? = nil, artist: String? = nil) {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    
    // Update track info
    if let title = title {
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
    }
    if let artist = artist {
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist
    }
    
    // Always update playback info
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = getCurrentTime()
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = getDuration()
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = getPlayerState() == "Playing" ? 1.0 : 0.0
    
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
}
```

### **1.4 Integration Points**
Modify existing methods to trigger lock screen updates:

**In `playStream()` method**, after successful playback start:
```swift
let playResult = BASS_ChannelPlay(currentStream, 0)
if playResult != 0 {
    os_log(.info, log: logger, "✅ CBass playback started - Handle: %d", currentStream)
    
    // ADD: Setup lock screen on first successful playback
    setupLockScreenControls()
    updateNowPlayingInfo(title: "LyrPlay Stream", artist: "Lyrion Music Server")
    
    commandHandler?.handleStreamConnected()
    delegate?.audioPlayerDidStartPlaying()
}
```

**In existing callback `setupCallbacks()` position update section**:
```swift
// Position updates for UI
let oneSecondBytes = BASS_ChannelSeconds2Bytes(currentStream, 1.0)
BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_POS), oneSecondBytes, { handle, channel, data, user in
    guard let user = user else { return }
    let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()
    
    let currentTime = player.getCurrentTime()
    DispatchQueue.main.async {
        player.delegate?.audioPlayerTimeDidUpdate(currentTime)
        
        // ADD: Update lock screen time display
        player.updateNowPlayingInfo()
    }
}, selfPtr)
```

---

## **Phase 2: FLAC Buffer Optimization (30 minutes)**

Based on previous CBass research, optimize FLAC streaming stability by updating the `configureForFormat()` method:

```swift
private func configureForFormat(_ format: String) {
    switch format.uppercased() {
    case "FLAC":
        // OPTIMIZED: Use settings from successful CBass implementation
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(20000))        // 20s buffer for stability
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(524288))   // 512KB network chunks  
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(15))       // 15% pre-buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(250))    // Slow updates for stability
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(120000))  // 2min timeout
        os_log(.info, log: logger, "🎵 FLAC optimized: 20s buffer, 512KB network, stable config")
        
    case "AAC", "MP3":
        // Compressed formats - smaller buffer for responsiveness
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))         // 1.5s buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(65536))    // 64KB network
        os_log(.info, log: logger, "🎵 Compressed format optimized")
        
    default:
        // Use defaults from setupCBass()
        break
    }
}
```

---

## **Phase 3: Testing & Validation (30 minutes)**

### **3.1 Lock Screen Testing Checklist**
- [ ] **Play button**: Starts CBass playback, updates button to pause
- [ ] **Pause button**: Pauses CBass playback, updates button to play  
- [ ] **Metadata display**: Shows track title, artist, duration
- [ ] **Time updates**: Current position updates in real-time
- [ ] **Background audio**: Controls remain functional when app backgrounded

### **3.2 Audio Format Testing**
- [ ] **MP3**: Should work perfectly (baseline)
- [ ] **AAC**: Should work perfectly 
- [ ] **FLAC**: Should stream stably with optimized buffer settings
- [ ] **Opus**: Bonus test if server provides Opus streams

### **3.3 Device vs Simulator**
⚠️ **Important**: Lock screen controls often work on device but not simulator. Test on actual iPhone/iPad for accurate results.

### **3.4 SlimProto Integration Verification**
- [ ] **Track transitions**: Automatic track advance works
- [ ] **Server seeking**: App-initiated seeks still work via SlimProto
- [ ] **Volume control**: Server volume commands work
- [ ] **Position recovery**: App restart position recovery works

---

## **Troubleshooting Guide**

### **Controls Not Appearing**
1. **Check audio session**: Ensure `.playback` category and `setActive(true)`
2. **Test on device**: Simulator often doesn't show lock screen controls
3. **Verify background modes**: Ensure "Background Audio" enabled in Info.plist
4. **Check now playing info**: Must set at least title and duration

### **Controls Appear But Don't Work** 
1. **Verify command targets**: Ensure play/pause handlers call correct CBass methods
2. **Check return values**: Command handlers must return `.success`
3. **Audio session conflicts**: Only set category once, don't override

### **FLAC Stability Issues**
1. **Apply buffer optimizations**: Use Phase 2 configuration
2. **Monitor BASS errors**: Check `BASS_ErrorGetCode()` for specific issues
3. **Test network conditions**: FLAC requires stable connection with large buffers

---

## **Expected Results**

After implementation:
- ✅ **Native FLAC seeking**: Core CBass benefit preserved
- ✅ **Lock screen controls**: Play/pause buttons functional
- ✅ **Metadata display**: Track info visible on lock screen
- ✅ **Background audio**: Continues playing when app backgrounded
- ✅ **FLAC stability**: Reliable streaming with optimized buffers
- ✅ **SlimProto integration**: All existing functionality preserved

## **Success Criteria**
1. Lock screen shows play/pause buttons and track metadata
2. Controls work reliably on physical device
3. FLAC files stream without stability issues
4. All existing SlimProto functionality remains intact
5. Background audio continues seamlessly

## **Time Estimate**
- **Phase 1**: 1-2 hours (MediaPlayer integration)
- **Phase 2**: 30 minutes (FLAC optimization)  
- **Phase 3**: 30 minutes (testing)
- **Total**: ~2-3 hours

## **Risk Assessment**
- **Low risk**: Basic MediaPlayer integration is well-documented
- **Medium risk**: FLAC buffer tuning may require iteration
- **Fallback**: Can always revert to AVPlayer + server transcoding if issues arise

---

## **Implementation Notes**

- **Keep it simple**: Only implement essential lock screen features
- **Leverage existing code**: Use current CBass play/pause methods unchanged
- **Don't break SlimProto**: Server-side seeking and volume control unchanged  
- **Test thoroughly**: Lock screen controls vary between iOS versions and devices

This approach gives you **native FLAC streaming + iOS lock screen integration** without the complexity that caused issues in the previous CBass implementation.