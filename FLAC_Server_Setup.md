# FLAC Server Transcoding Setup for AVPlayer

## Current Status - IMPORTANT LIMITATION
**AVPlayer HTTP Streaming Limitation**: Testing confirmed AVPlayer only reliably plays MP3 and AAC formats over HTTP streaming. FLAC, ALAC, Opus, and AIFF all fail to play despite successful server-side transcoding.

**Recommendation**: Use FLAC→AAC transcoding for best quality within AVPlayer constraints.

## Docker Commands for Server Transcoding

### RECOMMENDED: FLAC to AAC (Works with AVPlayer)
```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay FLAC to high-quality AAC transcoding for AVPlayer
flc aac * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [lame] -r -s $SAMPLERATE$ -q 0 --vbr-new -V 0 - -
EOF'
```

## Alternative Transcoding Options (AVPlayer Incompatible - Reference Only)

### Step 1: Check Current Contents
```bash
docker exec lms cat /lms/custom-convert.conf
```

### FLAC to Opus Transcoding (CBass Compatible)
```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay FLAC to high-quality Opus transcoding for CBass
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -
EOF'
```

### Step 3: Restart LMS Server
```bash
docker restart lms
```

### Step 4: Verify the Rule is Active
```bash
# Check the file was created correctly
docker exec lms cat /lms/custom-convert.conf

# Check if LMS is running
docker ps | grep lms
```

## What This Rule Does

- **Target**: Only affects device with MAC address `02:70:68:8c:51:41` (your iOS device)
- **Process**: Decodes FLAC file from seek position → Encodes as Opus in OGG container
- **Output**: OGG/Opus stream that CBass can handle natively
- **Quality**: Near-lossless quality (-C 10 = maximum quality setting)
- **Performance**: Real-time transcoding using sox with x86_64 architecture

## Client-Side Settings

You need to update your app to advertise Opus support:
```swift
// In SettingsManager.swift, update this line:
let formats = flacEnabled ? "ops,aac,mp3" : "aac,mp3"  // ops = Opus format
```

## Testing

1. Run the Docker commands above
2. Build and test your iOS app with a FLAC file
3. Check server logs - should show successful Opus transcoding
4. CBass should accept the OGG/Opus stream without errors

## Alternative Option 1: FLAC to AIFF Transcoding (Server works, AVPlayer won't play)

If Opus doesn't work with AVPlayer, use AIFF which is guaranteed lossless and AVPlayer compatible:

```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay FLAC to AIFF transcoding for AVPlayer (lossless)
flc aif * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t aiff -
EOF'

docker restart lms
```

**Client-side capability update for AIFF:**
```swift
// In SettingsManager.swift, update this line:
let formats = flacEnabled ? "aif,aac,mp3" : "aac,mp3"  // aif = AIFF format
```

**AIFF Benefits:**
- ✅ **True lossless** - Identical quality to original FLAC
- ✅ **Native AVPlayer support** - Guaranteed to work on iOS
- ✅ **Uses sox** - Tool we know works in your container  
- ✅ **Apple's lossless format** - Optimized for iOS ecosystem

## CBass Implementation: Combined FLAC and Opus Support

For CBass implementation with user-selectable formats in iOS settings:

```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay CBass implementation - Multiple format support
# Replace 02:70:68:8c:51:41 with your device MAC address

# FLAC seeking support - FLAC to FLAC with proper headers for native playback
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# Option A: High-quality OGG Vorbis (Current - Known Working)
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

# Option B: True Opus Maximum Quality (Experimental - Test with CBass)
# flc ops * 02:70:68:8c:51:41
#     # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
#     [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -r 48000 -t opus -C 10 -
EOF'
```

This configuration provides:
- **Native FLAC**: For highest quality and native seeking capability  
- **Option A**: High-quality OGG Vorbis (~320kbps) - guaranteed CBass compatibility
- **Option B**: True Opus codec (~256-320kbps) - requires CBass raw Opus support
- **Both rules active**: User can select format preference in iOS app settings

### Testing True Opus Support

To test if CBass supports raw Opus streams, try Option B by replacing Option A:

```bash
# Test raw Opus transcoding - replace your current rule with this:
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay CBass implementation - True Opus Maximum Quality Test
# Replace 02:70:68:8c:51:41 with your device MAC address

# FLAC seeking support - FLAC to FLAC with proper headers
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# True Opus Maximum Quality (48kHz, ~256-320kbps VBR)
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -r 48000 -t opus -C 10 -

EOF'
```

**Expected Results:**
- ✅ **If it works**: You get true Opus codec with maximum quality
- ❌ **If CBass errors**: Fall back to Option A (OGG Vorbis) which is guaranteed to work

**To revert back to OGG Vorbis if Opus fails:**
```bash
# Fallback to proven OGG Vorbis transcoding
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay CBass implementation - Proven OGG Vorbis
# Replace 02:70:68:8c:51:41 with your device MAC address

# FLAC seeking support
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -

# High-quality OGG Vorbis (~320kbps)
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -

EOF'
```

## Alternative Option 2: Original FLAC-Only Transcoding (if simpler setup needed)

Fall back to FLAC-to-FLAC transcoding only:

```bash
docker exec lms bash -c 'cat > /lms/custom-convert.conf << "EOF"
# LyrPlay FLAC seeking support - FLAC to FLAC with proper headers
flc flc * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
EOF'
```


## Expected Results

With combined FLAC and Opus transcoding setup, you should see in LMS logs:
- ✅ No "couldn't find binary" errors for sox
- ✅ Successful FLAC→FLAC conversion with proper headers (native seeking)
- ✅ Successful FLAC→Opus conversion for bandwidth efficiency
- ✅ CBass plays both FLAC and Opus formats without errors
- ✅ iOS app can switch between formats based on user preference

## Opus Quality Benefits

- **Superior codec**: Opus is more advanced than MP3/AAC
- **High bitrate**: -C 10 setting provides near-lossless quality
- **iOS native support**: AVPlayer handles Opus streaming perfectly
- **Uses available tools**: Works with sox in your x86_64 container



