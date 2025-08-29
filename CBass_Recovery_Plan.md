# CBass Recovery Methods & Interruption Management Plan

## Overview

With the CBass migration complete, we need to systematically review and optimize all recovery scenarios to ensure they work properly with the new BASS audio engine. This plan covers CarPlay, lock screen, app open recovery, and interruption management.

## Current Recovery Architecture

### Core Components
- **AudioManager.swift**: Central coordinator with interruption handling
- **NowPlayingManager.swift**: Lock screen integration and position storage
- **SlimProtoCoordinator.swift**: Server communication and custom recovery
- **AudioSessionManager.swift**: Audio session lifecycle (deferred to CBass)
- **InterruptionManager.swift**: Specialized interruption detection

### CBass Integration Status
- ✅ **Basic playback**: Working with immediate FLAC start
- ✅ **Lock screen controls**: Functional with server time sync
- ⚠️ **Recovery methods**: Need CBass-specific optimization
- ⚠️ **Interruption handling**: Requires CBass audio session coordination

## Recovery Scenarios to Review

### 1. CarPlay Recovery Methods

#### Current Implementation (AudioManager.swift:336-378)
```swift
private func handleCarPlayReconnection()
private func notifyServerOfCarPlayDisconnect(position: Double)
private func notifyServerOfCarPlayReconnect()
```

#### CBass-Specific Concerns
- **Audio session transitions**: CBass handles audio session, verify CarPlay transitions
- **Buffer state**: Ensure CBass buffers properly during CarPlay connect/disconnect
- **Timing accuracy**: CBass timing vs server timing during route changes
- **Volume control**: Verify CarPlay volume control integration with CBass

#### Testing Requirements
- [ ] CarPlay connect while playing FLAC
- [ ] CarPlay disconnect during playback
- [ ] Auto-resume after CarPlay reconnection
- [ ] Volume control during CarPlay session
- [ ] Multiple connect/disconnect cycles

### 2. Lock Screen Recovery Methods

#### Current Implementation (NowPlayingManager.swift:164-267)
```swift
func storeLockScreenPosition()
func getStoredPositionWithTimeOffset() -> (position: Double, wasPlaying: Bool, isValid: Bool)
func clearStoredPosition()
```

#### CBass-Specific Concerns
- **Position accuracy**: CBass time vs stored server time precision
- **Recovery timing**: CBass seeks vs position restoration
- **Buffer coordination**: Ensure CBass buffers are ready during recovery
- **State synchronization**: CBass player state vs stored playback state

#### Testing Requirements
- [ ] Lock screen play button after disconnection
- [ ] Position accuracy after various time intervals
- [ ] Recovery during different playback states
- [ ] Multiple lock screen interactions
- [ ] Background/foreground state changes

### 3. App Open Recovery Methods

#### Current Implementation (SlimProtoCoordinator.swift)
- Custom position banking system
- Server-side player preferences storage
- Silent server-muted recovery

#### CBass-Specific Concerns
- **Silent recovery**: Verify CBass volume muting works properly
- **Seeking accuracy**: CBass native seeking vs recovery position
- **Connection timing**: CBass initialization vs server recovery
- **Buffer management**: CBass buffer state during app launch recovery

#### Testing Requirements
- [ ] App open after background termination
- [ ] Recovery with various time gaps
- [ ] Silent recovery verification (no audio snippets)
- [ ] Server state vs CBass state synchronization
- [ ] Cold app launch recovery

### 4. Interruption Management

#### Current Implementation (AudioManager.swift:271-305)
```swift
func handleAudioInterruption(shouldPause: Bool)
func handleInterruptionEnded(shouldResume: Bool)
```

#### CBass-Specific Concerns
- **Audio session management**: CBass controls audio session, verify interruption handling
- **Buffer preservation**: CBass buffer state during interruptions
- **Resume timing**: CBass resume vs server position synchronization
- **Multiple interruption types**: Phone calls, Siri, other apps

#### Testing Requirements
- [ ] Phone call interruptions
- [ ] Siri interruptions
- [ ] Other app audio interruptions
- [ ] Multiple rapid interruptions
- [ ] Long interruption periods

## Implementation Strategy

### Phase 1: Current State Assessment
1. **Audit existing recovery code** for CBass compatibility
2. **Identify StreamingKit-specific logic** that needs adaptation
3. **Map audio session interactions** between components
4. **Document current behavior** vs expected behavior

### Phase 2: CBass Integration Review
1. **Audio session coordination**: Ensure CBass owns audio session lifecycle
2. **Timing synchronization**: Verify CBass time vs server time accuracy
3. **Buffer management**: Understand CBass buffer behavior during interruptions
4. **State management**: Align CBass state with recovery state tracking

### Phase 3: Optimization Implementation
1. **CarPlay optimization**: Update CarPlay handlers for CBass
2. **Lock screen optimization**: Enhance position storage/recovery for CBass timing
3. **App open optimization**: Verify silent recovery with CBass volume control
4. **Interruption optimization**: Improve interruption handling with CBass session management

### Phase 4: Comprehensive Testing
1. **Automated test scenarios** for each recovery type
2. **Edge case testing** (rapid state changes, multiple interruptions)
3. **Cross-platform testing** (iOS, iPadOS, macOS)
4. **Long-term stability testing** (extended use patterns)

## Key CBass Considerations

### Audio Session Management
- CBass owns complete audio session lifecycle
- Other components must not interfere with audio session
- Interruptions should be handled through CBass callbacks

### Buffer Management
- CBass manages network and playback buffers independently
- Recovery methods should respect CBass buffer state
- Buffer health affects recovery timing and success

### Timing Precision
- CBass provides high-precision timing information
- Server time remains master for synchronization
- Recovery positions should use most accurate time source available

### State Synchronization
- CBass player state vs SlimProto server state
- Recovery methods must coordinate both state machines
- Error conditions need proper state recovery

## Success Criteria

### Functional Requirements
- [ ] All recovery scenarios work reliably with CBass
- [ ] No audio artifacts during recovery operations
- [ ] Accurate position restoration across all scenarios
- [ ] Proper state synchronization between CBass and server

### Performance Requirements
- [ ] Recovery operations complete within 2 seconds
- [ ] No false track skipping during recovery
- [ ] Smooth transitions without user-perceivable delays
- [ ] Stable operation across extended use

### Quality Requirements
- [ ] Comprehensive logging for debugging recovery issues
- [ ] Graceful fallback for edge cases
- [ ] User-friendly error messages for failed recovery
- [ ] Consistent behavior across all platforms

## Next Steps

1. **Start with CarPlay review**: Most complex audio routing scenario
2. **Follow with interruption management**: Critical for user experience
3. **Optimize lock screen recovery**: Most frequently used scenario
4. **Finish with app open recovery**: Complex but less frequent

Each phase should include:
- Code review and analysis
- CBass-specific adaptations
- Comprehensive testing
- Documentation updates

---

**Status**: Plan created, ready for systematic implementation
**Priority**: High - Critical for production quality CBass implementation
**Timeline**: Systematic review and optimization of each recovery method