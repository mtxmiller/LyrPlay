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

- FLAC, AAC, M4A, Opus, OGG Vorbis
- Note: Gapless playback not currently supported

## Requirements

- iOS 15.4 or later
- Lyrion Media Server (LMS/Lyrion Music Server)
- **Material Skin plugin** (install from LMS Settings → Plugins)
- Network connection to your LMS server

### Remote Access

For remote access outside your home network, you'll need a secure VPN solution: Wireguard, Tailscale Etc. 

**Important**: Direct internet exposure of LMS servers is not recommended due to security risks. 

## Enabling FLAC Seek / Opus

LyrPlay can play MP3/AAC and FLAC without additional plugins, but for an improved experience a transcoding rules plugin has been developed [Mobile Transcode](https://github.com/mtxmiller/MobileTranscode) for ease of setup.  

To install it add below URL to “Additional repositories” on your “Manage Plug-ins page” in server configuration (at bottom).  Be sure to RESTART server after install. 

**Mobile Transcode Plugin URL:** https://raw.githubusercontent.com/mtxmiller/MobileTranscode/main/repo.xml

If you want to **manually** configure your custom-convert.conf please see reference here: https://github.com/mtxmiller/LyrPlay/blob/main/custom-convert.conf

**Benefits:**
- **Opus 256kbps** - Bandwidth efficient modern codec for mobile devices.
- Scrub / seek for FLAC files improves recovery / state transitions with app

**NOTE — Install Opus Tools** (required for Opus transcoding):

```bash
# Install opus-tools in your LMS container
docker exec -it lms bash -c "apt-get update && apt-get install -y opus-tools"
```

## Usage

### Material Skin Integration

LyrPlay is designed specifically for the **Material Skin** by [CDrummond](https://github.com/CDrummond/lms-material). Make sure you have installed the Material Skin plugin in LMS:

1. **Install Material Skin**: LMS Settings → Plugins → Material Skin → Install
2. **Access App Settings**: In Material web interface, go to Settings → Application
3. **LyrPlay Configuration**: App-specific settings appear in the Material settings menu under **‘Application’**

## Development

Built with:
- SwiftUI for iOS interface
- Bass for streaming playback - [Un4Seen](https://www.un4seen.com)
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
