# Playlist Recovery Extension Plan

## Overview
We have successfully implemented playlist-based position recovery for lock screen scenarios using the Home Assistant approach with `["playlist", "jump", index, 1, 0, {"timeOffset": position}]`. Now we need to extend this same reliable method to CarPlay disconnect/reconnect and app open recovery scenarios.

## Current Working System (Lock Screen)

### Position Saving Triggers
1. **App backgrounded**: `connectionManagerDidEnterBackground()` → `saveCurrentPositionForRecovery()`
2. **Any disconnect**: `slimProtoDidDisconnect()` → `saveCurrentPositionForRecovery()`
3. **Background task expires**: `prepareForBackgroundSuspension()` → disconnection → save

### Recovery Method
- Uses `getCurrentTimeForSaving()` for accurate live position
- Queries server for `playlist_cur_index` 
- Stores in UserDefaults with 5-minute grace period
- Executes `["playlist", "jump", savedIndex, 1, 0, {"timeOffset": savedPosition}]`

## Extension Plan

### 1. CarPlay Disconnect/Reconnect Recovery

#### Use Case
- User is listening to music in car at 2:30 position
- User exits car, CarPlay disconnects, **app automatically pauses**
- App gets backgrounded over time while in pocket
- User returns to car, connects CarPlay
- Music should resume at 2:30 position (where it was when paused) and **begin playing automatically**

#### Technical Requirements
1. **Leverage Existing CarPlay Detection** ✅
   - **Already implemented**: AudioManager.swift:329-337 detects CarPlay route changes
   - **CarPlay Disconnect**: `notifyServerOfCarPlayDisconnect(position: currentPosition)` already saves position
   - **CarPlay Reconnect**: Route change detection already logs "CarPlay reconnected"

2. **Position Saving Strategy** ✅ 
   - **CarPlay Disconnect**: Already handled by `notifyServerOfCarPlayDisconnect()` in AudioManager.swift:358
   - **Background**: Position saved by existing `connectionManagerDidEnterBackground()` trigger
   - **Strategy**: Extend existing CarPlay disconnect handler to use playlist recovery

3. **Recovery Logic** (New)
   - **Trigger**: Extend existing CarPlay Connected route detection (AudioManager.swift:457-459)
   - **Method**: Same playlist jump with timeOffset
   - **Behavior**: Resume playback at saved position and **continue playing**

#### Implementation Points
```swift
// EXTEND existing AudioManager.swift:457-459
} else if routeChangeDescription == "CarPlay Connected" {
    // CarPlay reconnected - use playlist recovery instead of server auto-resume
    os_log(.info, log: logger, "🚗 CarPlay reconnected - performing playlist recovery")
    coordinator.performCarPlayRecovery()  // NEW method
}

// EXTEND existing AudioManager.swift:358 
private func notifyServerOfCarPlayDisconnect(position: Double) {
    sendJSONRPCCommand("pause")
    // NEW: Save position for playlist recovery
    coordinator.saveCurrentPositionForRecovery() 
    os_log(.info, log: logger, "🚗 Saved position for CarPlay recovery: %.2f", position)
}
```

### 2. App Open Recovery

#### Use Case  
- User is listening to music and pauses playback
- User goes to do something else, app gets backgrounded
- App is killed/closed while paused
- User reopens app later
- App should recover to **exact pause position** and remain paused (user must press play to resume)

#### Technical Requirements
1. **Position Saving**
   - Already handled by existing `slimProtoDidDisconnect()` and `connectionManagerDidEnterBackground()` triggers
   - Saves position when app is backgrounded or connection lost

2. **Recovery Detection**
   - App startup: Check for recent recovery data
   - Only recover if within grace period (5 minutes)

3. **Recovery Behavior (CRITICAL DIFFERENCE)**
   - Execute playlist jump with timeOffset
   - **PAUSE after recovery** (do not auto-play)
   - Update UI to show correct position
   - Wait for user to press play

#### Implementation Points
```swift
func performAppOpenRecovery() {
    // Use same playlist jump command
    let playlistJumpCommand: [String: Any] = [
        "id": 1,
        "method": "slim.request", 
        "params": [playerID, [
            "playlist", "jump", savedIndex, 1, 0, [
                "timeOffset": savedPosition
            ]
        ]]
    ]
    
    sendJSONRPCCommandDirect(playlistJumpCommand) { [weak self] response in
        // CRITICAL: Pause after recovery for app open scenario
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self?.sendJSONRPCCommand("pause")
            os_log(.info, log: self?.logger, "🎯 App open recovery: jumped to position and paused")
        }
    }
}
```

## Implementation Strategy

### Phase 1: CarPlay Recovery
1. **Extend existing CarPlay detection** ✅
   - **Already working**: CarPlay connect/disconnect detection in AudioManager.swift
   - **Enhance**: Add playlist recovery calls to existing handlers

2. **Add CarPlay recovery method**
   - Add `performCarPlayRecovery()` method to SlimProtoCoordinator.swift
   - Use same playlist jump technique as lock screen recovery
   - Continue playback after recovery (auto-play for CarPlay)

### Phase 2: App Open Recovery  
1. **Add app startup recovery check**
   - Check for recent recovery data on app launch
   - Determine if recovery should be attempted

2. **Implement pause-after-recovery**
   - Execute playlist jump
   - Send pause command after position is restored
   - Update UI to reflect correct position

### Phase 3: Unified Recovery System
1. **Create recovery method enum**
   ```swift
   enum RecoveryMethod {
       case lockScreen    // Continue playing (wake from lock screen)
       case carPlay       // Continue playing (auto-resume when CarPlay reconnects)
       case appOpen       // Pause after recovery (user manually reopened app)
   }
   ```

2. **Unified recovery function**
   ```swift
   func performPlaylistRecovery(method: RecoveryMethod) {
       // Execute same playlist jump
       // Apply method-specific post-recovery behavior
   }
   ```

## Technical Considerations

### Shared Recovery Data
- Continue using same UserDefaults keys
- Same 5-minute grace period
- Same live position saving (`getCurrentTimeForSaving()`)

### Recovery Method Detection
```swift
func determineRecoveryMethod() -> RecoveryMethod {
    if isCarPlayReconnect {
        return .carPlay      // Auto-play when CarPlay reconnects
    } else if isAppLaunchRecovery {
        return .appOpen      // Pause after recovery when user opens app
    } else {
        return .lockScreen   // Continue playing when wake from lock screen
    }
}
```

### Error Handling
- Same graceful fallback to simple play command
- Clear recovery data after successful use
- Handle edge cases (no playlist, invalid index, etc.)

## Expected Benefits

1. **Consistent Recovery**: Same reliable playlist jump method across all scenarios
2. **User Experience**: Seamless position recovery in all contexts  
3. **No Duplicate Work**: Leverages existing CarPlay framework (~65% complete)
4. **Maintainable**: Single recovery mechanism with behavior variations
5. **Reliable**: Built on proven Home Assistant approach

## Files to Modify

1. **SlimProtoCoordinator.swift** (Primary)
   - Add `performCarPlayRecovery()` method (similar to existing `performPlaylistRecovery()`)
   - Add `performAppOpenRecovery()` method (with pause after recovery)
   - Add recovery method detection logic

2. **AudioManager.swift** (Minor Extensions)
   - **Line 358**: Extend `notifyServerOfCarPlayDisconnect()` to call `saveCurrentPositionForRecovery()`
   - **Line 457-459**: Extend CarPlay Connected detection to call `performCarPlayRecovery()`

3. **App Launch Logic** (New)
   - Add app startup recovery check in main app initialization
   - Determine if app open recovery needed based on UserDefaults

## Testing Strategy

1. **CarPlay Testing**
   - Play music in CarPlay
   - Disconnect and reconnect
   - Verify position recovery and continued playback

2. **App Open Testing**  
   - Play music, force-close app
   - Reopen app within grace period
   - Verify position recovery with paused state

3. **Cross-scenario Testing**
   - Ensure recovery methods don't conflict
   - Test edge cases (no recent data, invalid positions)
   - Verify 5-minute timeout behavior

## Success Criteria

- ✅ CarPlay disconnect/reconnect resumes at correct position
- ✅ App open recovery positions correctly but remains paused
- ✅ Lock screen recovery continues to work as before
- ✅ All methods use same reliable playlist jump technique  
- ✅ Clean fallback to simple play when recovery data unavailable
- ✅ 5-minute grace period respected across all scenarios