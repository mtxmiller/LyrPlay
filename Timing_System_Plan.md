# Timing System Recovery Plan

## Problem Analysis

We've completely lost the plot on how timing should work. The main branch had a **simple, proven approach** that we've overcomplicated during the CBass migration.

## Core Issue

**Current broken approach**: 
- Complex timer systems fighting with each other
- Server time fetching vs CBass time vs position polling
- Server skips break timing completely

**What we need**: 
- **Server time as anchor point + local elapsed time interpolation** (like main branch + lms-material)

## The Correct Methodology (Material-Style)

### **From LMS-Material Study**:
- Uses `playerStatus.current.time` as single source of truth
- Server provides time updates
- Client interpolates between server updates
- Server skips automatically reset the timing anchor

### **From Main Branch Study**:
- `SimpleTimeTracker` is the core timing engine
- `updateFromServer(time, playing)` sets anchor point
- `getCurrentTime()` returns `originalServerTime + elapsed` when playing
- Server skips work because new server time resets the anchor

## The Problem with Our Current CBass Implementation

1. **❌ We disabled server time fetching** - but server time is the ANCHOR, not a conflict
2. **❌ We're using CBass polling timers** - this doesn't handle server skips
3. **❌ We're fighting against SimpleTimeTracker** - instead of using it properly

## The Correct Approach

### **Core Principle**: 
**Server Time = Anchor Point, Local Elapsed = Interpolation**

Just like lms-material web interface:
- Server tells us "you're at 45.3 seconds" 
- We interpolate "45.3 + 2.1 elapsed = 47.4 seconds"
- Server skip happens "you're now at 120.7 seconds"
- We reset anchor and interpolate from new position

### **Implementation Strategy**:

1. **✅ Keep SimpleTimeTracker** - It's perfect, just use it correctly
2. **✅ Server time updates as anchor** - Every time server sends position
3. **✅ CBass handles playback** - But doesn't drive timing directly  
4. **✅ Interpolation for smoothness** - Between server updates

## Detailed Implementation Plan

### **Phase 1: Fix the Architecture**

#### **1.1 - Restore Server Time as Anchor (Not Conflict)**
```swift
// Server status updates should call:
simpleTimeTracker.updateFromServer(time: serverTime, playing: isPlaying)

// This sets the anchor point for interpolation
```

#### **1.2 - Use SimpleTimeTracker for Lock Screen**
```swift
// NowPlayingManager should get time from:
let (currentTime, isPlaying) = simpleTimeTracker.getCurrentTime()

// NOT from CBass directly, NOT from position polling
```

#### **1.3 - Server Time Fetching Strategy**
```swift
// Fetch server time every 8-10 seconds to refresh anchor
// This handles server skips, seeking, track changes
// NOT continuous polling - just periodic anchor refreshes
```

### **Phase 2: CBass Integration**

#### **2.1 - CBass Role**
- **Primary**: Audio playback engine
- **Secondary**: Provide playing/paused state updates
- **NOT**: Drive timing directly (that's server + interpolation)

#### **2.2 - CBass Time Updates**
```swift
// Use CBass time ONLY for:
// 1. Immediate feedback when play/pause state changes
// 2. Validation/sync with server time (not replacement)
// 3. Fallback when server time unavailable
```

### **Phase 3: Handle Edge Cases**

#### **3.1 - Server Skips**
- Server sends new position → `updateFromServer()` → Timing resets correctly
- **This is automatic with server time anchor approach**

#### **3.2 - Track Transitions** 
- Server sends position 0.0 → `updateFromServer(0.0)` → Timer resets to 0
- **This is automatic with server time anchor approach**

#### **3.3 - Disconnection Recovery**
- CBass continues playing → Use last known server time + elapsed
- Server reconnects → New server time resets anchor
- **SimpleTimeTracker already handles this**

## Key Insights from Study

### **LMS-Material Approach**:
- Single `playerStatus.current.time` value
- Server updates this value
- UI just displays it with interpolation
- Server skips/seeks automatically work

### **Main Branch Approach**:
- `SimpleTimeTracker` is the single source of truth
- Server time updates reset anchor point
- Interpolation provides smooth progression
- **This is exactly what lms-material does, just in Swift**

## What We Need to Undo

1. **❌ Remove position polling timers** - These fight with server time
2. **❌ Remove CBass-driven timing** - CBass plays audio, server provides time
3. **❌ Remove complex timing conflicts** - One source of truth: SimpleTimeTracker

## What We Need to Restore

1. **✅ Server time as anchor point** - Just like main branch
2. **✅ Periodic server time fetching** - For anchor refreshes (not continuous polling)
3. **✅ SimpleTimeTracker interpolation** - Proven logic from main branch
4. **✅ Clean separation** - Server = anchor, CBass = audio, SimpleTimeTracker = timing

## Success Criteria

1. **Server skips work automatically** - New server time resets timing anchor
2. **Track transitions reset to 0** - Server sends 0.0 → timing resets
3. **Smooth progression** - Interpolation between server updates
4. **No timing conflicts** - Single source of truth
5. **Matches main branch behavior** - Proven, simple, reliable

## Implementation Steps

1. **Revert complex timing changes** - Back to simple server time anchor
2. **Restore periodic server time fetching** - For anchor refreshes only
3. **Fix NowPlayingManager** - Use SimpleTimeTracker.getCurrentTime()
4. **Simplify CBass integration** - Audio engine, not timing driver
5. **Test server skips** - Should work automatically
6. **Test track transitions** - Should reset to 0 automatically

---

**Bottom Line**: We had the right approach in main branch. We just need to use **SimpleTimeTracker correctly** with **server time as anchor** + **interpolation**, exactly like lms-material web interface does.

The complexity came from trying to make CBass drive timing instead of just handling audio playback. Server time + interpolation is the proven approach.