# LyrPlay

<img width="2880" height="1100" alt="image" src="https://github.com/user-attachments/assets/eb77fa7f-3e40-4d72-af53-4840fa07e22b" />



A Squeezebox player for iOS devices that transforms your iPhone or iPad into a high-quality network audio player for Lyrion Media Server (LMS).

---

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
- Lyrion Media Server (LMS/Lyrion Music Server)
- **Material Skin plugin** (install from LMS Settings → Plugins)
- Network connection to your LMS server

### Remote Access

For remote access outside your home network, you'll need a secure VPN solution:

- **WireGuard** - Modern, fast VPN protocol
- **Tailscale** - Zero-config mesh VPN built on WireGuard
- **OpenVPN** - Traditional VPN solution

**Important**: Direct internet exposure of LMS servers is not recommended due to security risks. Always use a VPN for remote access to maintain security while enjoying your music collection anywhere.

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

Add the same rule to `custom-convert.conf` in your LMS root directory. Common locations:
- **Most installations**: `[LMS_ROOT]/custom-convert.conf`
- **Debian/Ubuntu**: `/etc/slimserver/custom-convert.conf`

**Note**: The file must be in the LMS root directory to be loaded properly, not in a subdirectory.

### Why This Works

This configuration forces FLAC files to be transcoded with proper headers on every seek operation:
- **Decodes** the FLAC file from the seek position
- **Re-encodes** it as 16-bit FLAC with complete headers
- **Enables** perfect seeking without StreamingKit errors
- **Only affects** your specific iOS device (other players use passthrough)

**Performance Impact**: Minimal - transcoding happens in real-time with efficient compression.

## Usage

### Material Skin Integration

LyrPlay is designed specifically for the **Material Skin** by [CDrummond](https://github.com/CDrummond/lms-material). Make sure you have installed the Material Skin plugin in LMS:

1. **Install Material Skin**: LMS Settings → Plugins → Material Skin → Install
2. **Access App Settings**: In Material web interface, go to Settings → Application
3. **LyrPlay Configuration**: App-specific settings appear in the Material settings menu

### Performance Optimization

For slower network connections or to reduce bandwidth usage, you can force MP3 transcoding:

1. **Open LMS Web Interface** (Material Skin)
2. **Go to Player Options** for your LyrPlay device
3. **Navigate to Extra Settings**
4. **Select Audio dropdown**
5. **Choose Bitrate Limiting** and select your preferred bitrate (e.g., 320kbps, 192kbps, 128kbps)

This will transcode all audio formats to MP3 at your chosen bitrate, significantly reducing network usage while maintaining good audio quality.

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
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -configuration Debug build
```

## Support

Report issues or request features through [GitHub Issues](https://github.com/mtxmiller/LyrPlay/issues).

**App Store Support URL:** https://github.com/mtxmiller/LyrPlay/issues

## 💖 Support LyrPlay Development

LyrPlay is free and open source. If it's been useful to you, consider supporting continued development:

- ⭐ **Star this repository** (helps with visibility)
- ☕ **[Buy me a coffee](https://ko-fi.com/mtxmiller)** (one-time support)
- 🐛 **Report issues** and suggest features
- 🤝 **Contribute code** if you're a developer

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/mtxmiller)

Your support helps maintain LyrPlay and add community-requested features!

## License

See MIT License. 

Copyright 2025 Eric Miller. All rights reserved.

---
