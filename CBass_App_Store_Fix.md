# CBass App Store Submission Fix

This document describes the **permanent solution** for fixing CBass framework validation errors during App Store submission.

## 🚨 Problem

When archiving for App Store submission, validation fails with:

```
This bundle Payload/LMS_StreamTest.app/Frameworks/bass.framework is invalid. 
The Info.plist file is missing the required key: CFBundleVersion.
```

Similar errors occur for `bassflac.framework` and `bassopus.framework`.

## ✅ Root Cause

The CBass Swift Package frameworks are missing the required `CFBundleVersion` key in their Info.plist files. Apple requires this key for App Store validation, but the third-party CBass package doesn't include it.

## 🎯 Permanent Solution: Run Script Build Phase

The solution is to add a **Run Script Build Phase** in Xcode that automatically fixes the frameworks during the build process.

### Step 1: Add Run Script Phase in Xcode

1. **Open Xcode**
2. **Select your target** (LMS_StreamTest)
3. **Build Phases tab**
4. **Click "+" → New Run Script Phase**
5. **Drag it to be AFTER "Embed Frameworks" phase**
6. **Name it**: "Fix CBass Frameworks"

### Step 2: Add the Fix Script

Paste this script into the run script phase:

```bash
# Fix CBass Framework Info.plist files during build
echo "🔧 Fixing CBass frameworks during build..."

# Fix frameworks in the built app
if [ -d "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Frameworks" ]; then
  cd "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Frameworks"

  for framework in bass.framework bassflac.framework bassopus.framework; do
      if [ -d "$framework" ]; then
          info_plist="$framework/Info.plist"
          if [ -f "$info_plist" ]; then
              echo "Fixing $framework"
              # Add CFBundleVersion if missing
              if ! /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$info_plist" >/dev/null 2>&1; then
                  /usr/libexec/PlistBuddy -c "Add CFBundleVersion string 24.17" "$info_plist"
                  echo "✅ Added CFBundleVersion to $framework"
              else
                  echo "✅ CFBundleVersion already exists in $framework"
              fi
          fi
      fi
  done
fi

echo "🎉 Framework fixes completed during build"
```

### Step 3: Archive Successfully

After adding this build phase:

1. **Product → Archive** in Xcode
2. **The script runs automatically** during archive
3. **App Store validation passes** ✅

## 🔧 How It Works

1. **During Archive**: Xcode builds the app and embeds the CBass frameworks
2. **Run Script Executes**: Our script runs after frameworks are embedded
3. **Frameworks Fixed**: Script adds missing `CFBundleVersion` to each framework
4. **Validation Passes**: App Store submission succeeds

## 📋 Build Phase Order

Make sure the build phases are in this order:

1. Sources
2. Frameworks  
3. Resources
4. **[CP] Embed Pods Frameworks**
5. **Fix CBass Frameworks** ← Our custom script
6. Any other phases

## 🎯 What Gets Fixed

The script automatically adds `CFBundleVersion` to:
- `bass.framework` (main BASS audio library)
- `bassflac.framework` (FLAC plugin)
- `bassopus.framework` (Opus plugin)

## ✅ Verification

After archiving, you should see in the build log:
```
🔧 Fixing CBass frameworks during build...
Fixing bass.framework
✅ Added CFBundleVersion to bass.framework
✅ CFBundleVersion already exists in bassflac.framework
✅ CFBundleVersion already exists in bassopus.framework
🎉 Framework fixes completed during build
```

## 🚨 Important Notes

- **This fix is permanent** - once added, it works for all future archives
- **No manual intervention required** - runs automatically during build
- **Safe to use** - only adds missing keys, doesn't modify existing ones
- **Version agnostic** - uses version "24.17" which matches CBass package

## 🔄 Troubleshooting

If App Store validation still fails:

1. **Check build log** - Verify the script ran during archive
2. **Build phase order** - Ensure script runs AFTER "Embed Frameworks"
3. **Clean and archive** - Try Product → Clean Build Folder → Archive

## 📱 Final Result

With this fix in place:
- ✅ **App Store submission succeeds**
- ✅ **No manual steps required**
- ✅ **Works for all future releases**
- ✅ **Universal platform support maintained** (iOS/iPadOS/macOS)

---

**Status**: ✅ **WORKING SOLUTION** - Successfully implemented and tested
**Date**: January 2025
**LyrPlay Version**: 1.6 with CBass migration