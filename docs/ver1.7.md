### LyrPlay Version 1.7 - Changes:

Improvements: 
- Enabled Gapless audio for all audio formats
- Added Basic CarPlay Resume Playback feature - can open App from CarPlay screen now
- Added Stream Information in Settings view to confirm file format / bitrate
- Updated Capabilities Strings Options — FLC->WAV for Lossless Seeking and AAC Preferred
- Added Ability to turn on / off App-Open Position Recovery (totally disabled for FLAC ONLY due to header issue with seek)

Fixes:
- Fixed ICY Metadata Issue with duration 0 causing crash
- Removed Material Interface ‘Show Lock Screen Player Setting’ - caused playback issue
- Fixed ContentView Settings pop-up on server connection issue
- Fixed Backup server failover / persistent connection details - attempts each server 6X then will pop-up dialog

### Need to FIX
- FLAC Seeking / Headers

### Features to Add
- Player Sync w/ others
- Server Authentication