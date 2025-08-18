# CBass FLAC Buffering & Performance Tuning Guide

## Overview

This guide explains all the CBass buffering parameters used in LyrPlay for FLAC streaming optimization. These parameters control how audio is buffered, when playback starts, and how the system handles network interruptions.

## Current FLAC Configuration

### **Primary FLAC Settings (Optimized for Immediate Start)**
```swift
// FLAC-Specific Configuration
BASS_CONFIG_BUFFER = 2000ms           // 2s playback buffer
BASS_CONFIG_NET_BUFFER = 524288       // 512KB network buffer  
BASS_CONFIG_NET_PREBUF = 3%           // 3% pre-buffer (≈15KB to start)
BASS_CONFIG_UPDATEPERIOD = 50ms       // 50ms update frequency
BASS_CONFIG_NET_TIMEOUT = 10000ms     // 10s network timeout
BASS_CONFIG_NET_READTIMEOUT = 5000ms  // 5s read timeout
```

### **Global Network Settings**
```swift
// Applied to All Formats
BASS_CONFIG_NET_TIMEOUT = 20000ms     // 20s global timeout
BASS_CONFIG_NET_READTIMEOUT = 10000ms // 10s global read timeout
BASS_CONFIG_NET_BUFFER = 65536        // 64KB global default
BASS_CONFIG_BUFFER = 2000ms           // 2s global default
BASS_CONFIG_UPDATEPERIOD = 100ms      // 100ms global updates
```

---

## Parameter Explanations

### **🎵 BASS_CONFIG_BUFFER** (Playback Buffer)
- **Current**: `2000ms` (2 seconds)
- **Purpose**: Audio data buffered for smooth playback
- **Impact**: 
  - **Higher**: More stable playback, higher memory usage, slower seeking
  - **Lower**: More responsive, but more prone to dropouts
- **Range**: `500ms - 5000ms`
- **Recommendations**:
  - **WiFi**: `2000ms` (current)
  - **Ethernet**: `1500ms` (faster networks)
  - **Cellular**: `3000ms` (unreliable networks)

### **🌐 BASS_CONFIG_NET_BUFFER** (Network Buffer)
- **Current**: `524288` (512KB for FLAC)
- **Purpose**: Network data buffer before decoding
- **Impact**:
  - **Higher**: Better handling of network hiccups, more memory
  - **Lower**: Lower memory usage, more sensitive to network issues
- **Range**: `32KB - 2MB`
- **Recommendations**:
  - **FLAC**: `512KB - 1MB` (current is good)
  - **Local Network**: `256KB - 512KB`
  - **Internet**: `1MB - 2MB`

### **⚡ BASS_CONFIG_NET_PREBUF** (Pre-buffer Percentage)
- **Current**: `3%` (≈15KB for 512KB buffer)
- **Purpose**: How much to buffer before starting playback
- **Impact**:
  - **Higher**: Delayed start, more stable playback
  - **Lower**: Immediate start, more prone to initial buffering
- **Range**: `1% - 50%`
- **Current Math**: `3% of 512KB = 15.36KB`
- **Recommendations**:
  - **Immediate Start**: `3-5%` (current)
  - **Stable Start**: `10-15%`
  - **Slow Networks**: `20-25%`

### **🔄 BASS_CONFIG_UPDATEPERIOD** (Update Frequency)
- **Current**: `50ms` (FLAC), `100ms` (global)
- **Purpose**: How often BASS checks stream status
- **Impact**:
  - **Lower**: More responsive UI, higher CPU usage
  - **Higher**: Lower CPU usage, less responsive
- **Range**: `25ms - 500ms`
- **Recommendations**:
  - **Performance**: `25-50ms`
  - **Battery**: `100-200ms`

### **⏱️ BASS_CONFIG_NET_TIMEOUT** (Network Timeout)
- **Current**: `10000ms` (FLAC), `20000ms` (global)
- **Purpose**: How long to wait for network response
- **Impact**:
  - **Higher**: More patient with slow networks
  - **Lower**: Faster failure detection
- **Range**: `5000ms - 60000ms`
- **Recommendations**:
  - **Local Network**: `5000-10000ms` (current)
  - **Internet**: `15000-30000ms`
  - **Cellular**: `30000-60000ms`

### **📖 BASS_CONFIG_NET_READTIMEOUT** (Read Timeout)
- **Current**: `5000ms` (FLAC), `10000ms` (global)
- **Purpose**: How long to wait for data during streaming
- **Impact**:
  - **Higher**: More tolerance for slow servers
  - **Lower**: Faster detection of stalled streams
- **Range**: `2000ms - 30000ms`
- **Recommendations**:
  - **Local Network**: `3000-5000ms` (current)
  - **Internet**: `10000-15000ms`

---

## Performance Profiles

### **🚀 Immediate Start** (Current FLAC Settings)
**Goal**: Start playback as quickly as possible
```swift
BASS_CONFIG_BUFFER = 2000ms           // 2s safety buffer
BASS_CONFIG_NET_BUFFER = 512KB        // Reasonable network buffer
BASS_CONFIG_NET_PREBUF = 3%           // Minimal prebuffer (15KB)
BASS_CONFIG_UPDATEPERIOD = 50ms       // Responsive updates
```
**Pros**: ≈0.5s start time, responsive seeking
**Cons**: More sensitive to network hiccups

### **🛡️ Stable Streaming** (Alternative)
**Goal**: Maximum stability for unreliable networks
```swift
BASS_CONFIG_BUFFER = 3000ms           // 3s safety buffer
BASS_CONFIG_NET_BUFFER = 1MB          // Large network buffer
BASS_CONFIG_NET_PREBUF = 10%          // 100KB prebuffer
BASS_CONFIG_UPDATEPERIOD = 100ms      // Moderate updates
```
**Pros**: Very stable, handles network issues well
**Cons**: 2-3s start delay, more memory usage

### **⚡ Ultra-Responsive** (Experimental)
**Goal**: Absolute minimum latency
```swift
BASS_CONFIG_BUFFER = 1000ms           // 1s minimal buffer
BASS_CONFIG_NET_BUFFER = 256KB        // Small network buffer
BASS_CONFIG_NET_PREBUF = 1%           // Tiny prebuffer (2.5KB)
BASS_CONFIG_UPDATEPERIOD = 25ms       // Maximum responsiveness
```
**Pros**: ≈0.2s start time, instant seeking
**Cons**: Very sensitive to network issues

---

## Stream Starvation Analysis

### **Current Starvation Detection**
The app monitors buffer health and detects when streams run out of data:

```swift
// Buffer Health Calculation
let flacBitrate = 800kbps              // Realistic FLAC bitrate
let remainingSeconds = bufferBytes / (800KB/s)
let bufferPercentage = (remainingSeconds / 2.0) * 100

// Health Categories
80-100%: EXCELLENT (green)
50-79%:  GOOD (blue) 
20-49%:  LOW (yellow)
0-19%:   CRITICAL (red)
```

### **Starvation Prevention**
To reduce stream starvation during track transitions:

1. **Increase Network Buffer**: `512KB → 1MB`
2. **Increase Pre-buffer**: `3% → 5%`
3. **Extend Timeouts**: `10s → 15s`

---

## Network-Specific Recommendations

### **🏠 Home WiFi (5GHz, Strong Signal)**
```swift
BASS_CONFIG_BUFFER = 1500ms           // Lower latency
BASS_CONFIG_NET_BUFFER = 256KB        // Smaller buffer
BASS_CONFIG_NET_PREBUF = 3%           // Quick start
```

### **🏢 Corporate WiFi (Potentially Restricted)**
```swift
BASS_CONFIG_BUFFER = 3000ms           // More stability
BASS_CONFIG_NET_BUFFER = 1MB          // Larger buffer
BASS_CONFIG_NET_PREBUF = 10%          // Safer start
BASS_CONFIG_NET_TIMEOUT = 30000ms     // Longer timeouts
```

### **📱 Cellular/Weak WiFi**
```swift
BASS_CONFIG_BUFFER = 5000ms           // Maximum stability
BASS_CONFIG_NET_BUFFER = 2MB          // Large buffer
BASS_CONFIG_NET_PREBUF = 25%          // Conservative start
BASS_CONFIG_NET_TIMEOUT = 60000ms     // Very long timeouts
```

---

## Tuning Strategy

### **Step 1: Identify Your Priority**
- **Speed**: Immediate playback start
- **Stability**: Fewer dropouts and stalls  
- **Quality**: Uninterrupted high-quality audio

### **Step 2: Test Configuration**
1. Start with current settings
2. Adjust **one parameter at a time**
3. Test with typical usage patterns
4. Monitor logs for buffer health

### **Step 3: Fine-Tune Based on Results**

**If experiencing starvation**:
- Increase `NET_BUFFER`: `512KB → 1MB`
- Increase `NET_PREBUF`: `3% → 5%`
- Increase timeouts: `+50%`

**If start is too slow**:
- Decrease `NET_PREBUF`: `3% → 1%`
- Decrease `BUFFER`: `2000ms → 1500ms`

**If seeking is laggy**:
- Decrease `BUFFER`: `2000ms → 1000ms`
- Increase `UPDATEPERIOD`: `50ms → 25ms`

---

## Advanced Parameters

### **iOS-Specific Settings**
```swift
BASS_CONFIG_IOS_MIXAUDIO = 0          // Exclusive audio playback
BASS_CONFIG_DEV_BUFFER = 20ms         // Device buffer (iOS optimized)
BASS_CONFIG_GVOL_STREAM = 10000       // Maximum stream volume
```

### **Threading Configuration**
```swift
BASS_CONFIG_UPDATETHREADS = 2         // Dual-threaded updates
BASS_CONFIG_NET_PLAYLIST = 0          // Direct streaming mode
BASS_CONFIG_NET_PASSIVE = 0           // Active network mode
```

---

## Monitoring & Debugging

### **Current Logging**
- Buffer health every 10 seconds during playback
- Critical buffer warnings when <20%
- Stream starvation detection and server notification

### **Key Metrics to Watch**
- **Start Time**: How long until audio begins
- **Buffer Health**: Percentage of target buffer filled
- **Starvation Events**: Frequency of stream interruptions
- **Seeking Performance**: Responsiveness of position changes

### **Log Patterns**
```
✅ FLAC Playing: 10.0s | Downloaded: 715132 | Buffer: EXCELLENT (85% = 1s)
⚠️ FLAC Critical Buffer: CRITICAL (5% = 0s) | Downloaded: 523847
🚨 Stream starvation detected - notifying server (squeezelite-style)
```

---

## Conclusion

The current FLAC configuration prioritizes **immediate start** while maintaining reasonable stability. For most users on good WiFi networks, these settings provide the best balance of responsiveness and reliability.

**Key Takeaway**: The `NET_PREBUF = 3%` setting is the primary driver of the fast start time, requiring only ~15KB of buffered data before playback begins. This can be adjusted based on network conditions and user preferences.