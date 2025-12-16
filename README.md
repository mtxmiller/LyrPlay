# LyrPlay

<img width="2880" height="1100" alt="image" src="https://github.com/user-attachments/assets/eb77fa7f-3e40-4d72-af53-4840fa07e22b" />



A Squeezebox player for iOS devices that transforms your iPhone or iPad into a high-quality network audio player for Lyrion Media Server (LMS).

---

## Features

- **Gapless Playback** - True gapless transitions between tracks using BASS push streams
- **Native FLAC / Opus Support** - High-quality lossless or efficiently compressed audio streaming with native decoding
- **Material Web Interface** - Embedded Material skin for full LMS control
- **Background Audio** - Continuous playback with lock screen integration and position recovery
- **Interruption Handling** - Smart pause/resume for phone calls and other app interruptions
- **Server Discovery** - Automatic LMS server detection with failover support
- **iOS Optimized** - Native SwiftUI app with BASS-managed audio sessions
- **Custom CarPlay Interface** - Native CarPlay interface with similar layout to Material Skin

## Audio Format Support

- **FLAC, AAC, M4A, Opus, OGG Vorbis, WAV** - All formats supported with native BASS codecs
- **Gapless Playback** - Supported across all formats using push stream architecture
- **Maximum Bitrate Selection for Transcoding** - Adjustable in App Settings

## Requirements

- **iOS 15.6 or later** (iPad app also runs on macOS via "Designed for iPad")
- **Lyrion Media Server** (LMS/Lyrion Music Server)
- **Material Skin plugin** (install from LMS Settings → Plugins)
- Network connection to your LMS server

## Remote Access

For remote access outside your home network, you'll need a secure VPN solution like Tailscale Etc. 

1. Install Tailscale on your iOS device and your server.
2. Enable MagicDNS - ensure server and iOS device have MagicDNS enabled.
3. Enter the MagicDNS name of your server into LyrPlay during app setup.
4. Listen to LyrPlay on cellular!

**Important**: Direct internet exposure of LMS servers is not recommended due to security risks. 

## Enabling Mobile Transcode (Required for Opus / WAV)

LyrPlay can play MP3/AAC/WAV and FLAC without additional plugins, but the MobileTranscode Plugin makes app more capable. For full functionality, use the [Mobile Transcode](https://github.com/mtxmiller/MobileTranscode) plugin to convert FLAC to Opus.

**To install it go to Server Settings -> Manage Plugins -> 3rd Party -> Mobile Transcode**

**Mobile Transcode Plugin URL:** https://raw.githubusercontent.com/mtxmiller/MobileTranscode/main/repo.xml

**NOT REQ'd** with plugin but if you want to **manually** configure your custom-convert.conf please see reference here: https://github.com/mtxmiller/MobileTranscode/blob/main/custom-convert.conf

**Benefits:**
- **Opus 256kbps** - Bandwidth efficient modern codec with working seek/scrub support
- **Lower Data Usage** - Smaller file sizes for mobile streaming
- **Full Seeking** - For manual seek and auto position reccovery on App-open

### NOTE — Install Opus Tools (required for Opus transcoding):

```bash
# Install opus-tools in your LMS container
docker exec -it lms bash -c "apt-get update && apt-get install -y opus-tools"
```

### Enabling Opus on Docker Container startup

- Create a script in your /"container folder"/config named **custom-init.sh** with below code
- This will ensure Opus-tools are always enabled on your Lyrion Container

```
#!/bin/bash
# Install opus-tools for Opus transcoding support
apt-get update -qq
apt-get install --no-install-recommends -qy opus-tools
```

## Usage

### Material Skin Integration

LyrPlay is designed specifically for the **Material Skin** by [CDrummond](https://github.com/CDrummond/lms-material). Make sure you have installed the Material Skin plugin in LMS:

1. **Install Material Skin**: LMS Settings → Plugins → Material Skin → Install
2. **Access App Settings**: In Material web interface, go to Settings → Application
3. **LyrPlay Configuration**: App-specific settings appear in the Material settings menu under **‘Application’**

## Development

Built with:
- **SwiftUI** for iOS interface
- **BASS audio library** for streaming playback with gapless support - [Un4Seen](https://www.un4seen.com)
- **CocoaAsyncSocket** for SlimProto communication (via CocoaPods)
- **WebKit** for Material web interface integration
- **BASS integration** via Swift bridging header (libbass, libbassmix, libbassflac, libbassopus)

## Support

Report issues or request features through [GitHub Issues](https://github.com/mtxmiller/LyrPlay/issues).

**App Store Support URL:** https://github.com/mtxmiller/LyrPlay/issues

## Support LyrPlay Development

LyrPlay is free and open source. If it's been useful to you, consider supporting continued development:

- ⭐ **Star this repository** (helps with visibility)
- 💖 **[Sponsor me on GitHub](https://github.com/sponsors/mtxmiller)** (monthly or one-time support)
- 🐛 **Report issues** and suggest features
- 🤝 **Contribute code** if you're a developer

[![Sponsor](https://img.shields.io/github/sponsors/mtxmiller?style=for-the-badge&logo=github&label=Sponsor)](https://github.com/sponsors/mtxmiller)

Your support helps maintain LyrPlay and add community-requested features!

### PayPal Donations

<div id="paypal-container-WWXW56JQE4GR4"></div>
<script>
  paypal.HostedButtons({
    hostedButtonId: "WWXW56JQE4GR4",
  }).render("#paypal-container-WWXW56JQE4GR4")
</script>

## License

See MIT License. 

Copyright 2025 Eric Miller. All rights reserved.

---
