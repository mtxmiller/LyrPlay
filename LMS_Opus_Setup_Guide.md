# LMS Opus Support Setup Guide

This guide shows how to add Opus transcoding support to your Lyrion Music Server (LMS) Docker container for use with LyrPlay.

## Prerequisites

- LMS running in Docker container
- LyrPlay iOS app with Opus support (v1.6+)

## Step 1: Install Opus Tools

Connect to your LMS Docker container and install opus-tools:

```bash
# Connect to your LMS container
docker exec -it <container_name> /bin/bash

# Update package list and install opus-tools
apt-get update
apt-get install -y opus-tools

# Verify installation
opusenc --version
which opusenc

# Exit container
exit
```

**Alternative one-liner:**
```bash
docker exec -it <container_name> bash -c "apt-get update && apt-get install -y opus-tools"
```

## Step 2: Create Custom Convert Configuration

Create a custom transcoding configuration file. Replace `<YOUR_MAC_ADDRESS>` with your device's MAC address (found in LyrPlay settings or LMS web interface).

```bash
# Create custom-convert.conf in your LMS container
docker exec <container_name> bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay Multi-Format Transcoding Configuration
# Replace <YOUR_MAC_ADDRESS> with your device MAC address

# FLAC Seeking Support - FLAC to FLAC with proper headers
flc flc * <YOUR_MAC_ADDRESS>
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# High Quality OGG Vorbis Transcoding
flc ogg * <YOUR_MAC_ADDRESS>
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

# Premium Quality Opus Transcoding - Handles all sample rates/bit depths
flc ops * <YOUR_MAC_ADDRESS>
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=160 --complexity=5 - -
EOF'
```

### Example with Real MAC Address:
```bash
# Example configuration for device 02:70:68:8c:51:41
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay Multi-Format Transcoding Configuration

# FLAC Seeking Support
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# High Quality OGG Vorbis
flc ogg * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

# Premium Quality Opus - Handles all sample rates/bit depths
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=160 --complexity=5 - -
EOF'
```

## Step 3: Restart LMS

Restart your LMS container to load the new transcoding rules:

```bash
docker restart <container_name>
```

## Step 4: Configure LyrPlay

1. Open LyrPlay on your iOS device
2. Go to **Settings** → **Audio Format**
3. Choose your preferred format:
   - **Lossless (FLAC)** - Highest quality, largest bandwidth
   - **Premium Quality (Opus)** - Superior quality, efficient bandwidth
   - **High Quality (OGG Vorbis)** - Near-lossless quality, good compatibility
   - **Compressed (AAC/MP3)** - Smallest bandwidth, universal compatibility

## Quality Settings Explained

### FLAC Settings
- **Purpose**: Native lossless playback with seeking support
- **Quality**: Bit-perfect lossless audio
- **Use Case**: High-end audio systems, unlimited bandwidth

### OGG Vorbis Settings  
- **Compression**: `-C 10` (high quality, ~160-320 kbps)
- **Quality**: Near-transparent, excellent for most use cases
- **Use Case**: Balanced quality vs bandwidth

### Opus Settings
- **Bitrate**: `160 kbps CBR` (premium quality, optimized for performance)
- **Complexity**: `5` (medium complexity for faster encoding)  
- **Quality**: Superior to OGG Vorbis at same bitrate
- **Use Case**: Mobile streaming, bandwidth-constrained networks, real-time transcoding

## Quality Adjustment Options

You can adjust quality levels by modifying the transcoding commands:

### Opus Performance Options:
```bash
# Optimized for performance (recommended)
--bitrate=160 --complexity=5

# Maximum quality (slower encoding)
--bitrate=192 --complexity=10

# Fast encoding (lower quality)
--bitrate=128 --complexity=3

# Legacy VBR mode (slowest, highest CPU usage)
--bitrate=160 --vbr --complexity=10
```

### OGG Vorbis Quality Options:
```bash
# Maximum quality
-C 10

# High quality
-C 8

# Balanced quality
-C 6

# Lower bandwidth
-C 4
```

## Troubleshooting

### Test Manual Transcoding
```bash
# Test Opus transcoding manually (use actual sample rate/bit depth of your test file):
docker exec <container_name> bash -c "/lms/Bin/x86_64-linux/flac -dcs /path/to/test.flac | opusenc --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=160 --complexity=5 - /tmp/test.opus"

# Check output:
docker exec <container_name> ls -la /tmp/test.opus
docker exec <container_name> file /tmp/test.opus
```

### Check LMS Logs
```bash
# Monitor transcoding activity:
docker logs -f <container_name> | grep -i opus
docker logs -f <container_name> | grep -i transcode
```

### Verify Tool Installation
```bash
# Check installed tools:
docker exec <container_name> which opusenc
docker exec <container_name> opusenc --version
docker exec <container_name> /lms/Bin/x86_64-linux/flac --version
docker exec <container_name> /lms/Bin/x86_64-linux/sox --version
```

### Common Issues

1. **No sound with Opus**: Verify opusenc parameters are correct (bitrate and complexity settings)
2. **Transcoding fails**: Verify opus-tools is properly installed
3. **Wrong MAC address**: Use the exact MAC address shown in LyrPlay settings
4. **Permission errors**: Ensure LMS has write access to custom-convert.conf location
5. **Crashes with high-resolution audio (24-bit/96kHz)**: Ensure you're using `$SAMPLESIZE$`, `$SAMPLERATE$`, and `$CHANNELS$` variables instead of hardcoded values

### High-Resolution Audio Support

**IMPORTANT**: The Opus transcoding rule uses LMS variables to handle any audio format:

- `$SAMPLESIZE$` - Automatically detects source bit depth (16, 24, 32-bit)
- `$SAMPLERATE$` - Automatically detects source sample rate (44.1, 48, 96, 192 kHz)
- `$CHANNELS$` - Automatically detects channel count (mono, stereo, surround)

**Old (problematic) rule** that crashes on 24-bit/96kHz:
```bash
[opusenc] --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=192 --vbr - -
```

**New (optimized) rule** that handles all resolutions with fast encoding:
```bash
[opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=160 --complexity=5 - -
```

### Performance Optimization Explained

The optimized Opus configuration uses:

- **CBR (Constant Bitrate)**: Removed `--vbr` flag to eliminate CPU-intensive analysis
- **Lower bitrate**: `160 kbps` instead of `192 kbps` reduces encoding workload  
- **Medium complexity**: `--complexity=5` balances quality vs encoding speed
- **Real-time friendly**: Optimized for streaming scenarios requiring fast transcoding

**Performance comparison**:
- **Old VBR rule**: High CPU usage, variable encoding time, potential bottlenecks
- **New CBR rule**: Consistent low CPU usage, predictable encoding time, smooth streaming

**Quality impact**: Minimal - Opus at 160 kbps CBR is still superior to most other codecs at similar bitrates.

## Finding Your Device MAC Address

Your device MAC address can be found in:
- **LyrPlay**: Settings → Device Information
- **LMS Web Interface**: Settings → Players → [Your Device] → Player ID

The MAC address format is: `02:70:68:8c:51:41` (example)

## Benefits Summary

| Format | Quality | Bandwidth | Seeking | Use Case |
|--------|---------|-----------|---------|----------|
| **FLAC** | Lossless | Highest | Instant | Audiophile setups |
| **Opus** | Superior | Efficient | Fast | Mobile, modern streaming |
| **OGG Vorbis** | Excellent | Moderate | Fast | Balanced performance |
| **Compressed** | Good | Lowest | Fast | Limited bandwidth |

## Advanced Configuration

For multiple devices, add additional rules:
```bash
# Device 1
flc ops * 02:70:68:8c:51:41
    [transcoding_command_here]

# Device 2  
flc ops * 02:0a:52:87:96:0f
    [transcoding_command_here]

# All other devices (fallback)
flc ops * *
    [transcoding_command_here]
```

---

## Alternative: FLAC Header Fix for CBass Architecture

### Background

LyrPlay v1.6+ uses CBass (BASS audio library) which requires complete FLAC file structure with proper headers. After server-side seeking, LMS sends headerless FLAC frames that CBass cannot decode, resulting in seeking failures.

### Minimal FLAC Header Transcoding

For users who want **native FLAC seeking support** with minimal CPU impact, add this rule:

```bash
# FLAC seeking support - minimal transcoding with fresh headers
flc flc * <YOUR_MAC_ADDRESS>
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ -- $FILE$ | [flac] --stdin --stdout --compression-level-0 --no-padding --no-seektable -
```

### Complete Configuration Example

```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay Multi-Format Configuration with FLAC Seeking

# FLAC Seeking Support - Minimal header transcoding
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ -- $FILE$ | [flac] --stdin --stdout --compression-level-0 --no-padding --no-seektable -

# High Quality OGG Vorbis
flc ogg * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

# Optimized Opus - Fast encoding
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=160 --complexity=5 - -
EOF'
```

### Benefits of FLAC Header Transcoding

- **Enables seeking** in high-resolution FLAC files (24-bit/96kHz+)
- **Minimal CPU usage** - compression level 0 with no padding or seektables
- **Preserves audio quality** - no unnecessary re-compression
- **CBass compatibility** - provides complete FLAC headers that BASS library requires
- **Real-time performance** - efficient enough for on-demand transcoding

### Technical Details

**Why this is needed**: CBass/BASS architecture requires complete FLAC file structure, but LMS sends headerless FLAC frames after seeking. This rule:

1. **Decodes source FLAC** from seek position with proper timing
2. **Re-encodes with fresh headers** using minimal compression (level 0)
3. **Provides complete FLAC structure** that CBass can decode properly
4. **Maintains high quality** while enabling full seeking functionality

**Performance**: Compression level 0 provides near-passthrough performance while adding the file structure headers that CBass requires.

---

**Note**: This configuration provides device-specific transcoding rules that only apply to your LyrPlay device, ensuring other Squeezebox players on your network are unaffected.

**Compatibility**: Tested with LyrPlay v1.6+ and Lyrion Music Server 8.3+