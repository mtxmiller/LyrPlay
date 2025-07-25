# LyrPlay

A professional-grade Squeezebox player for iOS devices that transforms your iPhone or iPad into a high-quality network audio player for Logitech Media Server (LMS).

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

## FLAC Setup

For optimal FLAC seeking, add this rule to your LMS server's `convert.conf` file BEFORE existing FLAC rules:

```
flc flc * [YOUR_DEVICE_MAC_ADDRESS]
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
```

Replace `[YOUR_DEVICE_MAC_ADDRESS]` with your device's MAC address shown in LMS web interface.

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