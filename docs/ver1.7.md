### LyrPlay Version 1.7 - Changes:
- Enabled gapless audio for all audio formats
- Fixed ICY Metadata Issue with duration 0 causing crash
- Removed Material Interface ‘Lock Screen Player Setting’ - caused playback issue
- FLAC Playback at Native Freq. / Bitrate (**Update Your Mobile Transcode Plugin or playback wont work - Removed all FLC->FLC transcode**)
- Ability to turn on / off App-Open Position Recovery (totally disabled for FLAC due to header issue with seek)
- FLAC will no longer seek if scrubbed on interface (sorry but can’t find good solution here and not sure how often people are seeking mid track anyway)
- Fixed ContentView Settings pop-up on server connection issue
- Fixed Backup server failover / persistent connection details - attempts each server 6X then will pop-up dialog

### Need to FIX
- FLAC Seeking / Headers

### Features to Add
- Player Sync w/ others
- Server Authentication