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

# Premium Quality Opus Transcoding
flc ops * <YOUR_MAC_ADDRESS>
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=192 --vbr - -
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

# Premium Quality Opus
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=192 --vbr - -
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
- **Bitrate**: `192 kbps VBR` (premium quality)
- **Mode**: Variable bitrate (`--vbr`) for optimal efficiency  
- **Quality**: Superior to OGG Vorbis at same bitrate
- **Use Case**: Mobile streaming, bandwidth-constrained networks

## Quality Adjustment Options

You can adjust quality levels by modifying the transcoding commands:

### Opus Bitrate Options:
```bash
# High quality (recommended)
--bitrate=192 --vbr

# Maximum quality
--bitrate=256 --vbr  

# Balanced quality/bandwidth
--bitrate=160 --vbr

# Mobile/low bandwidth  
--bitrate=128 --vbr
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
# Test Opus transcoding manually:
docker exec <container_name> bash -c "/lms/Bin/x86_64-linux/flac -dcs /path/to/test.flac | opusenc --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=192 --vbr - /tmp/test.opus"

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

1. **No sound with Opus**: Check that `--vbr` flag is included in opusenc command
2. **Transcoding fails**: Verify opus-tools is properly installed
3. **Wrong MAC address**: Use the exact MAC address shown in LyrPlay settings
4. **Permission errors**: Ensure LMS has write access to custom-convert.conf location

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

**Note**: This configuration provides device-specific transcoding rules that only apply to your LyrPlay device, ensuring other Squeezebox players on your network are unaffected.

**Compatibility**: Tested with LyrPlay v1.6+ and Lyrion Music Server 8.3+