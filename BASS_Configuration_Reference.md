# BASS Configuration Reference

This document provides a comprehensive reference for all BASS configuration parameters used in the LyrPlay audio player, with official definitions, units, and analysis of our current vs. default settings.

## Core Buffer Configuration

| Parameter | Purpose | Units | Range | BASS Default | Our Setting | Current Issue |
|-----------|---------|-------|-------|--------------|-------------|---------------|
| **BASS_CONFIG_BUFFER** | Playback buffer length for streams | Milliseconds | 10-5000ms | 500ms | 2000ms (general)<br>15000ms (FLAC) | FLAC: 15s buffer working |
| **BASS_CONFIG_NET_BUFFER** | Network download buffer length | Milliseconds | No limit specified | 5000ms (5s) | 5000ms (general)<br>512000ms (FLAC) | **FLAC: 512s (8.5min) buffer!** |
| **BASS_CONFIG_NET_PREBUF** | Pre-buffer percentage before playback | Percentage | 0-100% | 75% | 75% | Using default |
| **BASS_CONFIG_UPDATEPERIOD** | Buffer update frequency | Milliseconds | 5-100ms | 100ms | 250ms (FLAC) | Slower updates for stability |

## Network Configuration

| Parameter | Purpose | Units | Range | BASS Default | Our Setting | Notes |
|-----------|---------|-------|-------|--------------|-------------|--------|
| **BASS_CONFIG_NET_TIMEOUT** | Server connection timeout | Milliseconds | No limit | 5000ms (5s) | 15000ms | 3x longer timeout |
| **BASS_CONFIG_NET_READTIMEOUT** | Data delivery timeout | Milliseconds | No limit (0=none) | 0 (no timeout) | 8000ms | Added read timeout |

## Audio Quality Configuration

| Parameter | Purpose | Units | Range | BASS Default | Our Setting | Notes |
|-----------|---------|-------|-------|--------------|-------------|--------|
| **BASS_CONFIG_SRC** | Sample rate conversion quality | Quality Level | 0-4+ | 2 (SSE/ARM)<br>1 (other) | 4 | Highest quality (64-point sinc) |
| **BASS_CONFIG_FLOATDSP** | Use float processing in DSP | Boolean | 0/1 | 0 (disabled) | 1 (enabled) | Better quality through DSP chain |

## Format Detection & Verification

| Parameter | Purpose | Units | Range | BASS Default | Our Setting | Notes |
|-----------|---------|-------|-------|--------------|-------------|--------|
| **BASS_CONFIG_VERIFY** | File format detection data | Bytes | 1000-1000000 | 16000 bytes | 1 (enabled) | Enable file verification |
| **BASS_CONFIG_VERIFY_NET** | Network stream format detection | Bytes | 1000-1000000<br>0=25% of VERIFY | 0 (25% of VERIFY) | 1 (enabled) | Enable network verification |

## iOS-Specific Configuration

| Parameter | Purpose | Units | Values | BASS Default | Our Setting | Notes |
|-----------|---------|-------|--------|--------------|-------------|--------|
| **BASS_CONFIG_IOS_MIXAUDIO** | Enable iOS audio session integration | Boolean | 0/1 | Not specified | 1 (enabled) | **CRITICAL for CarPlay** |

## Metadata & Streaming Control

| Parameter | Purpose | Units | Values | BASS Default | Our Setting | Notes |
|-----------|---------|-------|--------|--------------|-------------|--------|
| **BASS_CONFIG_NET_META** | Process Shoutcast metadata | Boolean | 0/1 | 1 (enabled) | 0 (disabled) | Disable for LMS streams |
| **BASS_CONFIG_NET_PLAYLIST** | Process playlist URLs | Boolean | 0/1 | 1 (enabled) | 0 (disabled) | Disable for direct streaming |

## Analysis of Current Configuration Issues

### FLAC Buffer Configuration Mystery

Our "working" FLAC configuration uses what appears to be incorrect units:

```swift
// Current FLAC configuration that works better
let flacBufferMS = settings.flacBufferSeconds * 1000        // 15 * 1000 = 15,000ms (15s)
let networkBufferMS = settings.networkBufferKB * 1000       // 512 * 1000 = 512,000ms (8.5 minutes!)
```

**Why the 512-second network buffer may work:**

1. **BASS Auto-Capping**: Documentation states "values are automatically capped" at reasonable limits
2. **Extreme Buffer Strategy**: The huge value forces BASS to use maximum internal buffering
3. **FLAC Requirements**: FLAC has higher bitrate and more complex decoding than compressed formats
4. **Stream Stability**: Large buffers prevent underruns during seeking and format transitions

### Comparison with SwiftCBassDemo

The official CBass demo uses **minimal configuration**:
```swift
BASS_Init(-1, 44100, 0, nil, nil)  // Only basic initialization
// NO BASS_SetConfig calls at all!
```

This suggests BASS defaults work for basic use cases, but LMS streaming (especially FLAC) needs custom tuning.

## Stream Creation Flags

Our current stream creation uses these flags:
```swift
let streamFlags = DWORD(BASS_STREAM_STATUS) |    // Enable status info
                 DWORD(BASS_STREAM_AUTOFREE) |   // Auto-free when stopped  
                 DWORD(BASS_SAMPLE_FLOAT) |      // Use float samples
                 DWORD(BASS_STREAM_BLOCK)        // Force streaming mode
```

## User-Configurable Settings

From `SettingsManager.swift`:

| Setting | Default | Purpose | BASS Parameter |
|---------|---------|---------|----------------|
| `flacBufferSeconds` | 15 | FLAC playback buffer | BASS_CONFIG_BUFFER |
| `networkBufferKB` | 512 | Network buffer (used as seconds!) | BASS_CONFIG_NET_BUFFER |

## Recommendations

### For FLAC Streaming Fix
1. **Test reasonable network buffer sizes**: Try 30s (30000ms) instead of 512s
2. **Analyze buffer underrun patterns**: Monitor BASS_SYNC_STALL events
3. **Format-specific optimization**: Different buffer strategies per audio format

### For General Optimization
1. **Monitor actual buffer usage**: Use BASS_StreamGetFilePosition(BASS_FILEPOS_BUFFERING)
2. **Profile network conditions**: Adjust based on connection quality
3. **Test different pre-buffer percentages**: Higher values (85-90%) for FLAC

## Critical Insights

1. **The "wrong" configuration works better**: Our 512-second network buffer shouldn't work but does
2. **BASS auto-capping behavior**: Extreme values may trigger better internal buffering
3. **FLAC vs compressed format needs**: FLAC requires significantly more buffering
4. **iOS integration is critical**: BASS_CONFIG_IOS_MIXAUDIO essential for CarPlay

---

*Generated from official BASS documentation and current LyrPlay implementation analysis*
*Last updated: January 2025*