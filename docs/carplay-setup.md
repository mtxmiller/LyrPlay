# CarPlay Setup Guide

**Date:** January 14, 2025
**Status:** ✅ Approved by Apple - Ready for Configuration

## Step 1: Entitlements File Created ✅

The entitlements file has been created at:
```
LMS_StreamTest/LMS_StreamTest.entitlements
```

**Contents:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.carplay-audio</key>
	<true/>
</dict>
</plist>
```

## Step 2: Add Entitlements File to Xcode Project

1. Open `LMS_StreamTest.xcworkspace` in Xcode
2. In the Project Navigator (left sidebar), right-click on the `LMS_StreamTest` folder
3. Select **"Add Files to LMS_StreamTest..."**
4. Navigate to `LMS_StreamTest/LMS_StreamTest.entitlements`
5. Make sure **"Copy items if needed"** is UNCHECKED (file is already in correct location)
6. Make sure **"Add to targets: LMS_StreamTest"** is CHECKED
7. Click **Add**

## Step 3: Configure Build Settings

1. Select the **LMS_StreamTest project** in the Project Navigator (top item)
2. Select the **LMS_StreamTest target** (under TARGETS)
3. Go to the **"Signing & Capabilities"** tab
4. Under **"Signing"** section, verify your Team and Bundle Identifier are correct
5. Look for **"Code Signing Entitlements"** field
   - If it's not set, it should automatically pick up `LMS_StreamTest/LMS_StreamTest.entitlements`
   - If not, manually set it to: `LMS_StreamTest/LMS_StreamTest.entitlements`

## Step 4: Add CarPlay Capability in Xcode (Optional Check)

While on the **"Signing & Capabilities"** tab:

1. Click the **"+ Capability"** button (top left)
2. Search for **"CarPlay"**
3. If it appears, add it (it will create/update the entitlements file)
4. Make sure **"Audio"** checkbox is enabled under CarPlay capability

**Note:** If you don't see CarPlay in the capabilities list, that's okay - the entitlements file we created manually contains the necessary key.

## Step 5: Apple Developer Portal Configuration ✅

You mentioned you've already done this, but to confirm these steps were completed:

1. ✅ Log in to [Apple Developer Account](https://developer.apple.com/account)
2. ✅ Go to **Certificates, Identifiers & Profiles**
3. ✅ Select **Identifiers** → Find your App ID (`elm.LMS-StreamTest`)
4. ✅ Enable **CarPlay** capability
5. ✅ Click **Save**
6. ✅ Go to **Profiles** → Recreate your provisioning profiles (Development & Distribution)

## Step 6: Download & Install New Provisioning Profile

1. In Xcode, go to **Xcode** → **Settings** (or **Preferences**)
2. Select **Accounts** tab
3. Select your Apple ID
4. Click **Download Manual Profiles** button (bottom right)
5. Close Settings
6. In your project's **Signing & Capabilities** tab:
   - If using **Automatically manage signing**: Xcode will download the new profile
   - If using **Manual signing**: Select the new provisioning profile with CarPlay

## Step 7: Verify Configuration

1. Build the project (⌘B)
2. Check for any signing/entitlement errors
3. If errors appear, check:
   - Bundle ID matches Apple Developer Portal
   - Provisioning profile includes CarPlay entitlement
   - Team is selected correctly

## Step 8: Update Info.plist for CarPlay Audio

Check that `Info.plist` has the required background mode (should already be there):

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

**Location:** This is in your `LMS_StreamTest/Info.plist` file and enables background audio (which CarPlay requires).

## Step 9: Testing CarPlay

### Simulator Testing:
1. In Xcode, select **I/O** → **External Displays** → **CarPlay**
2. Run your app in the simulator
3. CarPlay display should appear

### Device Testing:
1. Connect iPhone to CarPlay-enabled vehicle or CarPlay head unit
2. Launch LyrPlay
3. Start playing audio
4. CarPlay should show Now Playing interface with playback controls

## Current LyrPlay CarPlay Implementation Status

**Phase 1 (Completed):**
- ✅ Basic CarPlay connectivity
- ✅ Now Playing screen with album art
- ✅ Playback controls (play/pause/next/previous)
- ✅ Progress bar and time display

**Phase 2 (In Progress ~35%):**
- ⏳ Browse interface for playlists
- ⏳ Search functionality
- ⏳ Full navigation structure

**Phase 3 (Planned):**
- 📋 Advanced browsing (albums, artists, genres)
- 📋 Voice control optimization
- 📋 Enhanced metadata display

## Troubleshooting

### "Provisioning profile doesn't include the CarPlay entitlement"
- Recreate your provisioning profile in Apple Developer Portal after enabling CarPlay
- Download the new profile in Xcode (Xcode → Settings → Accounts → Download Manual Profiles)

### "CarPlay capability not available"
- Verify CarPlay entitlement was approved by Apple (check your email)
- Wait 24 hours after approval for systems to sync
- Make sure you're logged in with the correct Apple Developer account

### "Build fails with entitlement error"
- Check CODE_SIGN_ENTITLEMENTS in Build Settings points to correct file
- Verify entitlements file is added to target (check Target Membership in File Inspector)

### "App doesn't appear in CarPlay"
- Check UIBackgroundModes includes "audio" in Info.plist
- Verify app is playing audio before connecting to CarPlay
- Check CarPlay settings on device (Settings → General → CarPlay)

## Next Steps After Configuration

1. Test basic CarPlay connectivity with current implementation
2. Continue Phase 2 development (browse interface)
3. Submit app update to TestFlight/App Store with CarPlay capability

## Resources

- [CarPlay Audio Apps Programming Guide](https://developer.apple.com/carplay/documentation/CarPlay-Audio-Apps.pdf)
- [WWDC Videos on CarPlay](https://developer.apple.com/videos/carplay)
- [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay)

---

**Configuration Created:** January 14, 2025
**Apple Approval:** Received
**Status:** Ready for Xcode configuration and testing
