# LyrPlay

A Squeezebox player for iOS devices that transforms your iPhone or iPad into a high-quality network audio player for Logitech Media Server (LMS).

## Features

- **Native FLAC Support** - High-quality lossless audio streaming with native decoding
- **Material Web Interface** - Embedded Material skin for full LMS control
- **Background Audio** - Continuous playback with lock screen integration
- **Server Discovery** - Automatic LMS server detection with failover support
- **iOS Optimized** - Native SwiftUI app with proper iOS integration

## Audio Format Support

- FLAC (16-bit, 24-bit) with native decoding
- AAC, MP3, and other standard formats
- Note: Gapless playback not currently supported

## Requirements

- iOS 18.2 or later
- Logitech Media Server (LMS/Lyrion Music Server)
- Network connection to your LMS server

## FLAC Seeking Setup

LyrPlay supports native FLAC playback, but seeking within FLAC files requires server-side configuration. Without this setup, seeking will cause playback to fail with StreamingKit error 2.

### For Docker Users (Recommended)

1. **Find your device's MAC address** in the LMS web interface (Settings → Information)

2. **Create a custom-convert.conf file** in your LMS container:
   ```bash
   # Enter your LMS Docker container
   docker exec -it your-lms-container-name /bin/bash
   
   # Create the custom configuration file
   nano /lms/custom-convert.conf
   ```

3. **Add this transcoding rule** (replace `[YOUR_DEVICE_MAC_ADDRESS]` with actual MAC):
   ```
   # LyrPlay FLAC seeking support - add BEFORE any existing FLAC rules
   flc flc * [YOUR_DEVICE_MAC_ADDRESS]
       # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
       [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
   ```

4. **Restart your LMS container** for changes to take effect

### For Traditional LMS Installation

Add the same rule to one of these locations (choose the first that exists):
- `custom-convert.conf` in your LMS root directory
- `custom-convert.conf` in your Plugins directory  
- `/etc/slimserver/custom-convert.conf` (Debian/Ubuntu)
- Edit the main `convert.conf` file directly (will be overwritten on updates)

### Why This Works

This configuration forces FLAC files to be transcoded with proper headers on every seek operation:
- **Decodes** the FLAC file from the seek position
- **Re-encodes** it as 16-bit FLAC with complete headers
- **Enables** perfect seeking without StreamingKit errors
- **Only affects** your specific iOS device (other players use passthrough)

**Performance Impact**: Minimal - transcoding happens in real-time with efficient compression.

## Development

Built with:
- SwiftUI for iOS interface
- StreamingKit for native FLAC support
- CocoaAsyncSocket for SlimProto communication
- WebKit for Material web interface integration

### Building

```bash
# Install dependencies
pod install

# Build from command line
xcodebuild -workspace LyrPlay.xcworkspace -scheme LyrPlay -configuration Debug build
```

## Support

Report issues or request features through [GitHub Issues](https://github.com/mtxmiller/LyrPlay/issues).

**App Store Support URL:** https://github.com/mtxmiller/LyrPlay/issues

## License

Copyright 2025 Eric Miller. All rights reserved.

---

🎵 Professional audio streaming for iOS
