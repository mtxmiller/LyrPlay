# CBass Dependency Setup Instructions

## Step 1: Add CBass Swift Package

1. **Open Xcode**
2. **File → Add Package Dependencies...**
3. **Enter Repository URL**: `https://github.com/Treata11/CBass`
4. **Choose Version**: Use "Up to Next Major" (latest stable)
5. **Select Products**: 
   - ✅ Bass
   - ✅ BassFLAC (if available)
6. **Add to Target**: LMS_StreamTest

## Step 2: Verify Import Works

After adding the package, the AudioPlayer.swift imports should work:
```swift
import Bass         // ✅ Should work now  
```

## Step 3: Build Test

Try building the project:
```bash
# From terminal in project directory
xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme LMS_StreamTest -configuration Debug build
```

## Expected Results

- ✅ Project builds successfully
- ✅ No import errors for `import Bass`
- ✅ BASS functions available (BASS_Init, BASS_StreamCreateURL, etc.)

## If Build Fails

Common issues:
1. **"No such module 'Bass'"**: Package dependency not added correctly
2. **BASS function not found**: May need to import additional Bass modules
3. **Architecture issues**: CBass should handle iOS architectures automatically

## Next Steps After Setup

1. Test basic initialization (BASS_Init)
2. Try creating a simple test stream
3. Verify FLAC support works

## Troubleshooting

If CBass package has issues, alternative approaches:
1. **Manual BASS Integration**: Download BASS SDK directly
2. **Different CBass Fork**: Try other Swift BASS wrappers
3. **Fallback**: Continue with AVPlayer approach

---
**Note**: This is a minimal setup. The CBass implementation in AudioPlayer.swift is designed to be simple and focused on core functionality.