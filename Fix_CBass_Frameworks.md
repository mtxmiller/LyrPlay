# Fix CBass Frameworks for App Store Submission

This script fixes the missing `CFBundleVersion` keys in CBass framework Info.plist files that are required for App Store submission.

## 🔧 Step 1: Run the Fix Script

Copy and paste this entire script into Terminal and press Enter:

```bash
#!/bin/bash

echo "🔧 Fixing CBass Frameworks for App Store..."

# Find the DerivedData path for LMS_StreamTest
DERIVED_DATA_PATH=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -name "*LMS_StreamTest*" -type d | head -1)

if [ -z "$DERIVED_DATA_PATH" ]; then
    echo "❌ Could not find LMS_StreamTest DerivedData path"
    echo "Make sure you've built the project at least once in Xcode"
    exit 1
fi

echo "📍 Found DerivedData: $DERIVED_DATA_PATH"

# Function to fix a framework's Info.plist
fix_framework() {
    local framework_name="$1"
    echo "🔍 Looking for $framework_name frameworks..."
    
    # Find all instances of this framework
    find "$DERIVED_DATA_PATH" -name "$framework_name.framework" -type d | while read framework_path; do
        info_plist="$framework_path/Info.plist"
        
        if [ -f "$info_plist" ]; then
            echo "📝 Processing: $framework_path"
            
            # Make file writable
            chmod 644 "$info_plist" 2>/dev/null || sudo chmod 644 "$info_plist"
            
            # Check if CFBundleVersion exists
            if ! plutil -extract CFBundleVersion xml1 -o - "$info_plist" >/dev/null 2>&1; then
                echo "  ➕ Adding CFBundleVersion to $framework_name"
                
                # Add CFBundleVersion using the same value as CFBundleShortVersionString
                VERSION=$(plutil -extract CFBundleShortVersionString xml1 -o - "$info_plist" 2>/dev/null | grep -o '<string>[^<]*</string>' | sed 's/<[^>]*>//g')
                
                if [ -n "$VERSION" ]; then
                    plutil -insert CFBundleVersion -string "$VERSION" "$info_plist" 2>/dev/null || sudo plutil -insert CFBundleVersion -string "$VERSION" "$info_plist"
                    echo "  ✅ Added CFBundleVersion: $VERSION"
                else
                    # Fallback to default version
                    plutil -insert CFBundleVersion -string "24.17" "$info_plist" 2>/dev/null || sudo plutil -insert CFBundleVersion -string "24.17" "$info_plist"
                    echo "  ✅ Added CFBundleVersion: 24.17 (default)"
                fi
            else
                echo "  ✅ CFBundleVersion already exists in $framework_name"
            fi
        fi
    done
}

# Fix all BASS frameworks mentioned in the error
fix_framework "bass"
fix_framework "bassflac"  
fix_framework "bassopus"

echo ""
echo "🎉 Framework fixes completed!"
echo ""
echo "📋 Next Steps:"
echo "1. Clean Build Folder in Xcode (Product → Clean Build Folder)"
echo "2. Archive your project again"
echo "3. The CFBundleVersion errors should be resolved"
echo ""
echo "💡 If you still get dSYM errors, those are warnings and won't prevent App Store submission"
```

## 🔧 Step 2: Alternative Quick Fix (If Step 1 Doesn't Work)

If the above script has permission issues, try this simpler approach:

```bash
# Navigate to project directory
cd /Users/ericmiller/Documents/Documents-Mac-Mini/LMS_StreamTest

# Clean all build data first
rm -rf ~/Library/Developer/Xcode/DerivedData/*LMS_StreamTest*

# Force rebuild in Xcode, then run this after build:
find ~/Library/Developer/Xcode/DerivedData -name "bass.framework" -exec sudo plutil -insert CFBundleVersion -string "24.17" {}/Info.plist \;
find ~/Library/Developer/Xcode/DerivedData -name "bassflac.framework" -exec sudo plutil -insert CFBundleVersion -string "24.17" {}/Info.plist \;
find ~/Library/Developer/Xcode/DerivedData -name "bassopus.framework" -exec sudo plutil -insert CFBundleVersion -string "24.17" {}/Info.plist \;
```

## 🔧 Step 3: Verification

After running the fix, verify it worked:

```bash
# Check if CFBundleVersion was added
find ~/Library/Developer/Xcode/DerivedData -name "bass.framework" -exec plutil -p {}/Info.plist \; | grep CFBundleVersion
```

You should see output like:
```
"CFBundleVersion" => "24.17"
```

## 📱 Step 4: Re-Archive

1. Open Xcode
2. Product → Clean Build Folder
3. Product → Archive
4. The CFBundleVersion validation errors should be gone!

## ⚠️ Notes

- The dSYM upload warnings are not critical - they won't prevent App Store submission
- You may need to enter your admin password when prompted
- If frameworks get regenerated, you may need to run this script again