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

# High-quality Opus in OGG container for CBass compatibility
flc ops * 02:70:68:8c:51:41
    # IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
    [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 10 -
EOF'
```

This configuration provides:
- **Native FLAC**: For highest quality and native seeking capability  
- **Opus transcoding**: For efficient streaming with near-lossless quality
- **Both rules active**: User can select format preference in iOS app settings

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



