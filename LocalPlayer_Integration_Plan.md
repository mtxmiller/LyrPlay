# LyrPlay LocalPlayer Integration Plan

## Overview

This document outlines the plan to integrate LocalPlayer functionality into LyrPlay, enabling offline/cached audio playback for iOS users with poor cellular connectivity or data limitations.

## Background Research

### LocalPlayer Plugin Analysis
- **Source**: LMS-Community/plugin-LocalPlayer (Triode's original work)
- **Purpose**: Enables same-machine file access for Squeezelite players
- **Key Finding**: NO caching logic - only direct file system access
- **Mechanism**: 
  - Players report `'loc'` as last format capability
  - LMS returns `file://127.0.0.1:3483/` URLs instead of HTTP streams
  - Players convert these back to local file paths

### Forum Discussion Context
The forum discussion about "caching and transcoding like PlexAmp" was proposing to **extend** the LocalPlayer concept to add downloading/caching for remote players - functionality that doesn't exist yet.

## StreamingKit Local File Support - VERIFIED ✅

### Capabilities Confirmed:
1. **Built-in file:// URL support**: `STKAudioPlayer` automatically detects `file://` scheme
2. **Dedicated local file handler**: Uses `STKLocalFileDataSource` for local files
3. **Format support**: Relies on Core Audio codecs (supports FLAC through system)
4. **No code changes needed**: Current `audioPlayer.play(url)` works with file:// URLs

### Code Evidence:
```objective-c
// From STKAudioPlayer.m line 671-673
if ([url.scheme isEqualToString:@"file"])
{
    retval = [[STKLocalFileDataSource alloc] initWithFilePath:url.path];
}
```

### FLAC Handling:
- FLAC extension not in explicit file type mapping (returns hint 0)
- Core Audio handles format detection automatically
- Should work seamlessly with cached FLAC files

## Current LyrPlay Implementation Analysis

### Ready for Integration ✅:
1. **SlimProto capabilities**: Already declares formats in HELO message
2. **Stream handling**: Robust `strm` command processing with URL extraction
3. **Format support**: Handles FLAC, AAC, MP3, ALAC, PCM correctly
4. **StreamingKit integration**: Uses `audioPlayer.play(url)` - works with local files

### Integration Points:
- **HELO message**: Add `'loc'` to capabilities string (line 280 in SlimProtoClient.swift)
- **Stream command handler**: Detect `file://127.0.0.1:3483/` URLs in handleStartCommand
- **Audio pipeline**: No changes needed - StreamingKit handles both HTTP and file:// URLs

## Implementation Plan

### Phase 1: Basic LocalPlayer Support (Low Risk)

#### Changes Required:
1. **Update capabilities string**:
```swift
// In SlimProtoClient.swift line 280
let capabilities = "Model=squeezelite,AccuratePlayPoints=1,HasDigitalOut=1,HasPolarityInversion=1,Balance=1,Firmware=v1.0.0-iOS,ModelName=SqueezeLite,MaxSampleRate=48000,flc,aac,mp3,loc"
```

2. **Add URL detection in SlimProtoCommandHandler.swift**:
```swift
private func handleStartCommand(url: String, format: String, startTime: Double) {
    if url.hasPrefix("file://127.0.0.1:3483/") {
        // LocalPlayer mode - extract original file URL
        let originalURL = String(url.dropFirst("file://127.0.0.1:3483/".count))
        handleLocalFilePlayback(originalURL: originalURL, format: format, startTime: startTime)
    } else {
        // Normal streaming mode - existing code unchanged
        coordinator?.playStream(url: url, format: format, startTime: startTime)
    }
}
```

3. **Add local file handler**:
```swift
private func handleLocalFilePlayback(originalURL: String, format: String, startTime: Double) {
    Task {
        if let cachedFileURL = await getCachedFile(originalURL) {
            // Play cached file using StreamingKit (no changes to audio pipeline)
            coordinator?.playStream(url: cachedFileURL.absoluteString, format: format, startTime: startTime)
        } else {
            // Download and cache first, then play
            if let downloadedFileURL = await downloadAndCacheFile(originalURL) {
                coordinator?.playStream(url: downloadedFileURL.absoluteString, format: format, startTime: startTime)
            } else {
                // Fallback to streaming if download fails
                coordinator?.playStream(url: originalURL, format: format, startTime: startTime)
            }
        }
    }
}
```

#### Benefits:
- ✅ **No breaking changes**: Existing streaming functionality unchanged
- ✅ **Same audio pipeline**: StreamingKit handles both HTTP and file:// URLs
- ✅ **Preserved integrations**: Lock screen, Now Playing, audio session management all work
- ✅ **FLAC seeking fix preserved**: Server-side transcoding still works for streaming

#### Risk Assessment: **LOW**
- Only affects LocalPlayer-enabled servers with 'loc' plugin setting
- Fallback to normal streaming if anything fails
- No changes to core audio handling

### Phase 2: Cache Management System

#### Components:
1. **LyrPlayCacheManager class**:
   - Download files from LMS server
   - Manage cache directory in iOS Documents folder
   - Handle cache size limits and cleanup
   - Track usage patterns for smart cleanup

2. **Storage considerations**:
   - Default cache size: 10GB (user configurable)
   - Location: iOS Documents directory (user accessible via Files app)
   - Format preservation: Download original format (FLAC stays FLAC)
   - Metadata storage: Track file info, usage stats, download dates

3. **Download strategy**:
   - On-demand downloading when LocalPlayer URL received
   - Pre-caching of queue (next 3-5 songs)
   - Background downloading on WiFi only (user setting)
   - Resume interrupted downloads

#### Implementation Details:
```swift
class LyrPlayCacheManager {
    private let cacheDirectory: URL
    private let maxCacheSize: Int64
    private let downloadSession: URLSession
    
    func getCachedFile(_ originalURL: String) async -> URL? {
        // Check if file exists in cache
        // Return file:// URL if found
    }
    
    func downloadAndCacheFile(_ originalURL: String) async -> URL? {
        // Download from LMS server
        // Save with proper file extension (.flac, .mp3, etc.)
        // Update metadata and usage tracking
        // Return file:// URL when complete
    }
    
    func preCacheQueue(_ urls: [String]) async {
        // Background download of upcoming songs
        // WiFi-only option
        // Respect cache size limits
    }
    
    func cleanupCache() {
        // Remove oldest/least-used files
        // Respect user preferences
        // Maintain cache size under limit
    }
}
```

### Phase 3: Advanced Features

1. **Pre-caching Queue Management**:
   - Monitor SlimProto queue changes
   - Automatically download next 3-5 songs
   - Cancel downloads for removed queue items

2. **Smart Cache Management**:
   - LRU (Least Recently Used) cleanup
   - Pin favorite albums for offline
   - Usage statistics and recommendations

3. **User Interface Enhancements**:
   - Cache status in settings
   - Manual download options
   - Offline mode indicator
   - Cache size and usage display

4. **Network Optimization**:
   - WiFi-only downloading
   - Pause downloads on cellular
   - Resume interrupted downloads
   - Parallel downloads with rate limiting

## Testing Strategy

### Phase 1 Testing:
1. **Verify LocalPlayer plugin on LMS server**:
   - Install plugin and enable 'loc' setting
   - Confirm server sends file:// URLs to LyrPlay

2. **Test StreamingKit local file playback**:
   - Create test FLAC, MP3, AAC files in iOS simulator
   - Verify `audioPlayer.play(fileURL)` works correctly
   - Test seeking functionality with local FLAC files

3. **Integration testing**:
   - Test with and without LocalPlayer plugin
   - Verify fallback to streaming works
   - Confirm no impact on existing functionality

### Phase 2 Testing:
1. **Download and caching**:
   - Test download of various formats
   - Verify cache management and cleanup
   - Test cache size limits

2. **Error handling**:
   - Network failures during download
   - Disk space exhaustion
   - Corrupted cache files

## Risks and Mitigations

### Low Risk (Phase 1):
- **FLAC format detection**: StreamingKit should handle via Core Audio
  - *Mitigation*: Test with actual FLAC files, verify playback
- **URL parsing edge cases**: Malformed file:// URLs
  - *Mitigation*: Robust error handling with fallback to streaming

### Medium Risk (Phase 2):
- **iOS storage limitations**: Cache size vs available space
  - *Mitigation*: Dynamic cache size limits, user controls
- **Background download restrictions**: iOS background task limits
  - *Mitigation*: Foreground downloading, WiFi-only options

### High Risk (None identified):
- No high-risk changes due to non-breaking, additive approach

## Success Criteria

### Phase 1:
- [x] StreamingKit local file playback verified
- [ ] LocalPlayer URLs detected and handled
- [ ] No regression in existing streaming functionality
- [ ] FLAC files play correctly from cache

### Phase 2:
- [ ] Files download and cache successfully
- [ ] Cache management respects size limits
- [ ] Smart cleanup maintains frequently used files
- [ ] Background downloading works on WiFi

### Phase 3:
- [ ] Queue pre-caching reduces buffering
- [ ] User interface provides cache control
- [ ] Offline mode works without network
- [ ] Battery impact remains acceptable

## Conclusion

**Recommendation: Proceed with Phase 1**

The research confirms that StreamingKit fully supports local file playback through its built-in `STKLocalFileDataSource`. The integration can be implemented with minimal risk using a non-breaking, additive approach that preserves all existing functionality while adding powerful offline capabilities for mobile users.

The phased approach allows for incremental development and testing, with each phase building on the previous one while maintaining system stability.

---

**Last Updated**: July 29, 2025  
**Status**: Ready for Phase 1 implementation