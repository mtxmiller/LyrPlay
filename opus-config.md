# Opus Configuration for LMS Custom Convert

## Add These Lines to Your Script

Add the following Opus transcoding rules to your custom-convert.conf script, right after the OGG sections and before the `EOF`:

```bash
# High-quality Opus transcoding for superior bandwidth efficiency
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-rate=44100 --raw-channels=2 --bitrate=160 --vbr - -

flc ops * 02:0a:52:87:96:0f
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-rate=44100 --raw-channels=2 --bitrate=160 --vbr - -
```

## Complete Updated Script

Here's your complete script with Opus support added:

```bash
#!/bin/bash

# Script to write LMS custom convert configuration
# Usage: ./get-lms-convert-conf.sh

echo "=== Writing LMS Custom Convert Configuration ==="
echo ""

docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay CBass implementation - Multiple format support
# Replace 02:70:68:8c:51:41 with your device MAC address

# FLAC seeking support - FLAC to FLAC with proper headers for native playback
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

flc flc * 02:0a:52:87:96:0f
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# High-quality OGG Vorbis transcoding for bandwidth-efficient streaming  
flc ogg * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

flc ogg * 02:0a:52:87:96:0f
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

# High-quality Opus transcoding for superior bandwidth efficiency
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-rate=44100 --raw-channels=2 --bitrate=160 --vbr - -

flc ops * 02:0a:52:87:96:0f
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-rate=44100 --raw-channels=2 --bitrate=160 --vbr - -
EOF'

if [ $? -eq 0 ]; then
    echo "✅ Configuration written successfully!"
else
    echo "❌ Failed to write configuration!"
fi

echo ""
```

## Opus Quality Settings

You can adjust the Opus quality by changing the `--bitrate` parameter:

- `--bitrate=128 --vbr` - Good quality, smaller files
- `--bitrate=160 --vbr` - High quality (recommended) ⭐
- `--bitrate=192 --vbr` - Very high quality  
- `--bitrate=256` - Maximum quality (no VBR needed)

## After Running the Script

1. **Restart LMS container**: `docker restart lms`
2. **Test in iOS app**: Select "Premium Quality (Opus)" in audio format settings
3. **Monitor LMS logs**: `docker logs -f lms` to see transcoding activity
4. **Verify format**: Check that streams show "Server offering Opus" in app logs

## Troubleshooting

If Opus doesn't work:

1. **Check opusenc availability**:
   ```bash
   docker exec lms which opusenc
   docker exec lms opusenc --version
   ```

2. **Check LMS logs for errors**:
   ```bash
   docker logs lms | grep -i opus
   ```

3. **Test transcoding manually**:
   ```bash
   docker exec lms bash -c "flac -dcs /path/to/test.flac | opusenc --raw --raw-rate=44100 --raw-channels=2 --bitrate=160 --vbr - /tmp/test.opus"
   ```