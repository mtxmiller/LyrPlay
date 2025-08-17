ContentView initializing with Material Settings Integration
Loading settings from UserDefaults
Settings loaded - Host: ser5, Player: iOS Player, Configured: YES, FLAC: NO
Saving settings to UserDefaults
Settings saved successfully
🔍 Checking BASSFLAC plugin availability...
❌ No BASS plugins detected
✅ BASS initialized - Version: 02041100
🔍 Testing BASSFLAC plugin availability...
❌ FLAC format not found in loaded plugins!
CBassAudioPlayer initialized with BASS audio library
AudioPlayer initialized with CBass audio engine
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to setup initial audio session: The operation couldn’t be completed. (OSStatus error -50.)
✅ Background observers configured
✅ Interruption observers configured
📱 Current audio route captured: Speaker
InterruptionManager initialized
✅ Interruption manager integrated
Enhanced AudioSessionManager initialized
✅ Initial now playing info configured
✅ Remote Command Center configured with track skip controls
✅ Component delegation configured with interruption handling
✅ Refactored AudioManager initialized with modular architecture
Settings loaded - Host: ser5, Port: 3483
Socket initialized
SlimProtoClient initialized - Host: ser5:3483
SlimProtoCommandHandler initialized with FLAC support
✅ Enhanced background observers configured
✅ Network monitoring started
Enhanced SlimProtoConnectionManager initialized
SimpleTimeTracker initialized with Material-style logic
SlimProtoCoordinator initialized with Material-style time tracking
✅ FIXED: Single AudioManager and SlimProtoCoordinator instances created
Creating WebView Coordinator with Material integration
Coordinator initialized with Material settings handler
Creating WKWebView with Material Integration for URL: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755352472
Could not create a sandbox extension for '/var/containers/Bundle/Application/E5024EA7-A6D9-46EC-8A8E-7DE066CEDE13/LMS_StreamTest.app'
WKWebView load request started with Material appSettings integration
Connecting to LMS server with Material Integration: ser5
🔗 AudioManager.setSlimClient called
✅ SlimProto client reference set for lock screen commands
✅ SlimClient reference set for AudioManager and NowPlayingManager
Server settings updated - Host: ser5, Port: 3483
Server settings updated and tracked - Host: ser5, Port: 3483
Starting connection to Primary server...
🔄 Connection attempt starting
🔄 Cannot connect - network unavailable
Server settings updated - Host: ser5, Port: 3483
Settings loaded - Host: ser5, Port: 3483
Attempting to connect to ser5:3483
🔄 shouldReloadWebView changed to: false
✅ Connected to LMS at 100.80.183.77:3483
Sending HELO message as LyrPlay for iOS
Added capabilities: Model=squeezelite,AccuratePlayPoints=1,HasDigitalOut=1,HasPolarityInversion=1,Balance=1,Firmware=v1.0.0-iOS,ModelName=SqueezeLite,MaxSampleRate=48000,aac,mp3
✅ HELO sent as squeezelite with player name: 'iOS Player', MAC: 02:70:68:8C:51:41
Read data initiated after connect - expecting 2-byte length header
✅ Connection established
✅ Connection established
💓 Health monitoring started (15 sec intervals)
🔄 Using simplified SlimProto time tracking
✅ SlimProto client reference set for lock screen commands
✅ Simplified time tracking connected via AudioManager
⚠️ Legacy app open recovery removed - using custom position banking instead
nw_connection_copy_connected_path_block_invoke [C1] Client called nw_connection_copy_connected_path on unconnected nw_connection
tcp_connection_is_cellular No connected path
Server message length: 5 bytes
📨 Received: setd (1 bytes)
📛 SETD command received - ID: 0, payload length: 1
📛 Server requesting player name - sending: 'iOS Player'
📤 Raw message sent (19 bytes)
✅ SETD player name sent: 'iOS Player' (11 bytes)
Server message length: 5 bytes
📨 Received: setd (1 bytes)
📛 SETD command received - ID: 4, payload length: 1
📛 SETD command with unsupported ID: 4
Server message length: 6 bytes
📨 Received: aude (2 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📱 App became active
📱 App became active but network unavailable
🌐 Network status: Wi-Fi (expensive: NO)
🌐 Network restored
🌐 Network change - Available: YES, Expensive: NO
✅ WebView reference set for Material UI refresh
GPU process (0x113002400) took 1.124341 seconds to launch
Networking process (0x113009020) took 1.113542 seconds to launch
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
App is being debugged, do not track this hang
Hang detected: 0.81s (debugger attached, not reporting)
WebContent process (0x113000c80) took 2.402554 seconds to launch
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
🔄 Requested initial status to detect existing streams
🔍 Checking for custom position recovery from server preferences
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "?"]], "method": "slim.request", "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📍 Responding to status request with TIMER status
App is being debugged, do not track this hang
Hang detected: 0.44s (debugger attached, not reporting)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 Navigation decision for URL: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755352472
✅ Allowing navigation within LMS server: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755352472
Started loading Material interface
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
    "_p2" = "70.64";
}, "params": <__NSArrayI 0x1076d0540>(
02:70:68:8c:51:41,
<__NSArrayI 0x1076800c0>(
playerpref,
lyrPlayLastPosition,
?
)

)
, "id": 1, "method": slim.request]
🎯 Found custom saved position: 70.64 seconds - starting recovery
🔄 Custom recovery: server-muted play → seek → pause sequence to 70.64
🔇 Saving current server volume and muting for silent recovery
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["mixer", "volume", "?"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
    "_volume" = 93;
}, "params": <__NSArrayI 0x1076d1dc0>(
02:70:68:8c:51:41,
<__NSArrayI 0x1076820d0>(
mixer,
volume,
?
)

)
, "id": 1, "method": slim.request]
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySavedVolume", "93"]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sent JSON-RPC play command to LMS
App is being debugged, do not track this hang
Hang detected: 0.32s (debugger attached, not reporting)
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "params": <__NSArrayI 0x1076d2080>(
02:70:68:8c:51:41,
<__NSArrayI 0x107680060>(
playerpref,
lyrPlaySavedVolume,
93
)

)
, "id": 1, "method": slim.request]
💾 Saved current volume: 93
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["mixer", "volume", "0"]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
Server message length: 28 bytes
📨 Received: strm (24 bytes)
🎵 Server strm - command: 'q' (113), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
⚠️ Stream command 'q' has no HTTP data - handling as control command
⏹️ Server stop command
⏹️ Server stop command
⏹️ Stopped periodic server time fetching
📤 Sending STAT: STMf
STAT packet: STMf, position: 0.00, size: 61 bytes
📤 Sending STAT: STMf
STAT packet: STMf, position: 0.00, size: 61 bytes
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 SKIPPING lock screen update: 0.00s (timeDiff: 0.0s < 2.0s threshold)
⏹️ CBass playback stopped
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 81 bytes
📨 Received: strm (77 bytes)
🎵 Server strm - command: 's' (115), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
HTTP request for MP3: GET /stream.mp3?player=02:70:68:8c:51:41 HTTP/1.0
🔍 Extracted stream URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
✅ Accepting MP3 stream: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
▶️ Starting MP3 stream from 0.00
📤 Sending STAT: STMf
STAT packet: STMf, position: 0.00, size: 61 bytes
🎵 Starting stream: MP3 from 0.00
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 SKIPPING lock screen update: 0.00s (timeDiff: 0.0s < 2.0s threshold)
⏹️ CBass playback stopped
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
⚠️ Audio session setup warning: The operation couldn’t be completed. (OSStatus error -50.) (continuing anyway)
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Configured for MP3 streaming
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "params": <__NSArrayI 0x1076d1e80>(
02:70:68:8c:51:41,
<__NSArrayI 0x107682250>(
mixer,
volume,
0
)

)
, "id": 1, "method": slim.request]
🔇 Server volume muted for silent recovery
✅ JSON-RPC play command sent successfully
🔧 Ensuring SlimProto connection for audio streaming...
✅ SlimProto already connected
📤 Sending STAT: STMt
🎵 Stream Info: Freq=44100Hz, Channels=2, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=104573379102661.86 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 176400 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
STAT packet: STMt, position: 0.00, size: 61 bytes
🌐 Sending seek command to 70.64 seconds
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📍 Server time updated: 0.00 (duration: 190.89, playing: YES)
📍 Updated from SlimProto: 0.00 (playing: YES)
📍 Updated server time: 0.00 (playing: YES) [Material-style]
📡 Real server time fetched: 0.00 (playing: YES)
📤 Sending STAT: STMt
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483647
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMt, position: 0.00, size: 61 bytes
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 28 bytes
📨 Received: strm (24 bytes)
🎵 Server strm - command: 'q' (113), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
⚠️ Stream command 'q' has no HTTP data - handling as control command
⏹️ Server stop command
⏹️ Server stop command
⏹️ Stopped periodic server time fetching
📤 Sending STAT: STMf
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 SKIPPING lock screen update: 0.00s (timeDiff: 0.0s < 2.0s threshold)
⏹️ CBass playback stopped
STAT packet: STMf, position: 0.00, size: 61 bytes
📤 Sending STAT: STMf
STAT packet: STMf, position: 0.00, size: 61 bytes
✅ Seek command sent successfully to 70.64
✅ Custom recovery: Seek successful - pausing at recovered position
🔒 Pause command - getting current server position first
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 81 bytes
📨 Received: strm (77 bytes)
🎵 Server strm - command: 's' (115), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
HTTP request for MP3: GET /stream.mp3?player=02:70:68:8c:51:41 HTTP/1.0
🔍 Extracted stream URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
✅ Accepting MP3 stream: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
▶️ Starting MP3 stream from 0.00
📤 Sending STAT: STMf
STAT packet: STMf, position: 0.00, size: 61 bytes
🎵 Starting stream: MP3 from 0.00
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 SKIPPING lock screen update: 0.00s (timeDiff: 0.0s < 2.0s threshold)
⏹️ CBass playback stopped
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
⚠️ Audio session setup warning: The operation couldn’t be completed. (OSStatus error -50.) (continuing anyway)
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Configured for MP3 streaming
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
🧹 CBass stream and callbacks cleaned up
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
📍 Server time updated: 70.64 (duration: 190.89, playing: YES)
📍 Updated from SlimProto: 70.64 (playing: YES)
📍 Updated server time: 70.64 (playing: YES) [Material-style]
📡 Real server time fetched: 70.64 (playing: YES)
🎵 Stream Info: Freq=44100Hz, Channels=2, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=104573379102661.86 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 176400 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483643
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
STAT packet: STMt, position: 0.00, size: 61 bytes
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
🔍 Interpolated time: 70.64 + 0.40 = 71.04
🔒 Using SlimProto time: 71.04 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 71.04s (Server Time, playing: YES)
🔒 TIME SOURCE CHANGED: Server → Server Time
🌐 Sent JSON-RPC pause command to LMS
🔊 Restoring server volume after recovery
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySavedVolume", "?"]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🗑️ Clearing custom position recovery preferences
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", ""]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", ""]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["method": "slim.request", "id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", ""]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.15, size: 61 bytes
Server message length: 28 bytes
📨 Received: strm (24 bytes)
🎵 Server strm - command: 'p' (112), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
⚠️ Stream command 'p' has no HTTP data - handling as control command
⏸️ Server pause command (last known position: 0.00)
⏸️ Server pause command
🔍 Interpolated time: 70.64 + 0.54 = 71.18
📍 Server time updated: 71.18 (duration: 0.00, playing: NO)
⏸️ Audio player paused
🔒 Audio player reports pause time: 0.15 (NOT using - server is master)
📤 Sending STAT: STMp
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 SKIPPING lock screen update: 0.00s (timeDiff: 0.0s < 2.0s threshold)
⏸️ CBass playback paused
STAT packet: STMp, position: 0.16, size: 61 bytes
📍 Server time updated: 70.64 (duration: 190.89, playing: YES)
📍 Updated from SlimProto: 70.64 (playing: YES)
📍 Updated server time: 70.64 (playing: YES) [Material-style]
📡 Real server time fetched: 70.64 (playing: YES)
✅ JSON-RPC pause command sent successfully
🌐 JSON-RPC response status: 200
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d28a0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752e490>(
playerpref,
lyrPlaySavedVolume,
?
)

)
, "result": {
    "_p2" = 93;
}, "id": 1, "method": slim.request]
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["mixer", "volume", "93"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d28a0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752d110>(
playerpref,
lyrPlayLastPosition,

)

)
, "result": {
}, "id": 1, "method": slim.request]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d1fc0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752e760>(
playerpref,
lyrPlayLastState,

)

)
, "result": {
}, "id": 1, "method": slim.request]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d35a0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752e700>(
playerpref,
lyrPlaySaveTime,

)

)
, "result": {
}, "id": 1, "method": slim.request]
🎵 Server-muted custom position recovery complete
Server message length: 26 bytes
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d31e0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752e4c0>(
mixer,
volume,
93
)

)
, "result": {
}, "id": 1, "method": slim.request]
🔊 Server volume restored to: 93
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySavedVolume", ""]], "id": 1]
📨 Received: audg (22 bytes)
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
✅ Material UI refreshed after recovery
✅ Material UI refresh JavaScript executed
🎵 Metadata duration updated: 191 seconds
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
📍 Server time updated: 70.64 (duration: 190.89, playing: NO)
📍 Updated from SlimProto: 70.64 (playing: NO)
📍 Updated server time: 70.64 (playing: NO) [Material-style]
📡 Real server time fetched: 70.64 (playing: NO)
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x1076d22c0>(
02:70:68:8c:51:41,
<__NSArrayI 0x10752fde0>(
playerpref,
lyrPlaySavedVolume,

)

)
, "result": {
}, "id": 1, "method": slim.request]
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
✅ Artwork loaded successfully
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
✅ Artwork loaded successfully
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
📍 Server time updated: 70.64 (duration: 190.89, playing: NO)
📍 Updated from SlimProto: 70.64 (playing: NO)
📍 Updated server time: 70.64 (playing: NO) [Material-style]
📡 Real server time fetched: 70.64 (playing: NO)
📍 Server time updated: 70.64 (duration: 190.89, playing: NO)
📍 Updated from SlimProto: 70.64 (playing: NO)
📍 Updated server time: 70.64 (playing: NO) [Material-style]
📡 Real server time fetched: 70.64 (playing: NO)
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
✅ Track end detection enabled
Finished loading Material interface
✅ Track end detection enabled
❌ Failed to inject settings handler: A JavaScript exception occurred
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Not playing, returning stored time: 70.64
🔒 Using SlimProto time: 70.64 (playing: NO)
⏰ NowPlayingManager TIMER UPDATE: 70.64s (Server Time, playing: NO)
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 28 bytes
📨 Received: strm (24 bytes)
🎵 Server strm - command: 'u' (117), format: 109 (0x6d)
✅ Server offering MP3 - acceptable fallback
⚠️ Stream command 'u' has no HTTP data - handling as control command
▶️ Server unpause command
▶️ Server unpause command
🔍 Not playing, returning stored time: 70.64
📍 Server time updated: 70.64 (duration: 0.00, playing: YES)
📤 Sending STAT: STMr
App is being debugged, do not track this hang
Hang detected: 0.25s (debugger attached, not reporting)
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.17, size: 61 bytes
📍 Audio start event logged
▶️ CBass playback resumed
STAT packet: STMr, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.17, size: 61 bytes
✅ FLAC Playing: 0.3s | Downloaded: 147209 | Buffer: CRITICAL (2% = 0s)
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.29, size: 61 bytes
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.29, size: 61 bytes
🔍 Interpolated time: 70.64 + 0.54 = 71.18
🔒 Using SlimProto time: 71.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 71.18s (Server Time, playing: YES)
✅ FLAC Playing: 0.8s | Downloaded: 163091 | Buffer: CRITICAL (0% = 0s)
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
🔄 AudioManager state: playing=YES
🔄 NowPlayingManager received update: 1.00s, playing=YES
🔒 SKIPPING lock screen update: 1.00s (timeDiff: 1.0s < 2.0s threshold)
📍 Local time update only: 1.00
🔍 Interpolated time: 70.64 + 1.55 = 72.19
🔒 Using SlimProto time: 72.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 72.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 2.54 = 73.18
🔒 Using SlimProto time: 73.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 73.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 3.55 = 74.19
🔒 Using SlimProto time: 74.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 74.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 3.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 3.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 4.54 = 75.18
🔒 Using SlimProto time: 75.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 75.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 5.54 = 76.18
🔒 Using SlimProto time: 76.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 76.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 6.55 = 77.19
🔒 Using SlimProto time: 77.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 77.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 7.55 = 78.19
🔒 Using SlimProto time: 78.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 78.19s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 8.55 = 79.19
🔒 Using SlimProto time: 79.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 79.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.69, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.69, size: 61 bytes
📍 Responding to status request with TIMER status
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 8.72 = 79.36
🔒 Using SlimProto time: 79.36 (playing: YES)
🔍 Interpolated time: 70.64 + 9.55 = 80.19
🔒 Using SlimProto time: 80.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 80.19s (Server Time, playing: YES)
✅ FLAC Playing: 10.3s | Downloaded: 313974 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 10.55 = 81.19
🔒 Using SlimProto time: 81.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 81.19s (Server Time, playing: YES)
✅ FLAC Playing: 10.8s | Downloaded: 321916 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 11.55 = 82.19
🔒 Using SlimProto time: 82.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 82.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 12.55 = 83.19
🔒 Using SlimProto time: 83.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 83.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 13.55 = 84.19
🔒 Using SlimProto time: 84.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 84.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 14.55 = 85.19
🔒 Using SlimProto time: 85.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 85.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 15.55 = 86.19
🔒 Using SlimProto time: 86.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 86.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 16.55 = 87.19
🔒 Using SlimProto time: 87.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 87.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 17.55 = 88.19
🔒 Using SlimProto time: 88.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 88.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 18.55 = 89.19
🔒 Using SlimProto time: 89.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 89.19s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 5, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 70.64 + 18.86 = 89.50
🔍 Position sources - Server: 89.50, Audio: 18.92
✅ Using SimpleTimeTracker time: 89.50
💾 Saved position locally: 89.50 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 70.64 + 18.86 = 89.50
💾 Saving position to server preferences: 89.50 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "89.50"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755352503"]], "id": 1, "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
Snapshot request 0x125070ae0 complete with error: <NSError: 0x125072220; domain: BSActionErrorDomain; code: 6 ("anulled")>
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x125053300>(
02:70:68:8c:51:41,
<__NSArrayI 0x125070690>(
playerpref,
lyrPlayLastPosition,
89.50
)

)
, "method": slim.request, "result": {
}, "id": 1]
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 19.01s, playing=YES
🔒 UPDATING LOCK SCREEN: 19.01s (timeDiff: 19.0s)
📍 Updated from audio manager: 19.01 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 5)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x125053720>(
02:70:68:8c:51:41,
<__NSArrayI 0x125070540>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "method": slim.request, "result": {
}, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x125052c20>(
02:70:68:8c:51:41,
<__NSArrayI 0x125073180>(
playerpref,
lyrPlaySaveTime,
1755352503
)

)
, "method": slim.request, "id": 1, "result": {
}]
📱 App became active
🔍 Interpolated time: 70.64 + 19.54 = 90.18
🔒 Using SlimProto time: 90.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 90.18s (Server Time, playing: YES)
✅ FLAC Playing: 20.3s | Downloaded: 472799 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 20.55 = 91.19
🔒 Using SlimProto time: 91.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 91.19s (Server Time, playing: YES)
✅ FLAC Playing: 20.8s | Downloaded: 480740 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 21.55 = 92.19
🔒 Using SlimProto time: 92.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 92.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 22.55 = 93.19
🔒 Using SlimProto time: 93.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 93.19s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 23.55 = 94.19
🔒 Using SlimProto time: 94.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 94.19s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 23.68 = 94.32
🔒 Using SlimProto time: 94.32 (playing: YES)
🔍 Interpolated time: 70.64 + 24.55 = 95.19
🔒 Using SlimProto time: 95.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 95.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 25.54 = 96.18
🔒 Using SlimProto time: 96.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 96.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 25.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 25.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 26.55 = 97.19
🔒 Using SlimProto time: 97.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 97.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 27.55 = 98.19
🔒 Using SlimProto time: 98.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 98.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 28.55 = 99.19
🔒 Using SlimProto time: 99.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 99.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 29.55 = 100.19
🔒 Using SlimProto time: 100.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 100.19s (Server Time, playing: YES)
✅ FLAC Playing: 30.3s | Downloaded: 631623 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 30.55 = 101.19
🔒 Using SlimProto time: 101.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 101.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 30.70, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 30.70, size: 61 bytes
📍 Responding to status request with TIMER status
✅ FLAC Playing: 30.8s | Downloaded: 639565 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 31.55 = 102.19
🔒 Using SlimProto time: 102.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 102.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 32.54 = 103.18
🔒 Using SlimProto time: 103.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 103.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 33.55 = 104.19
🔒 Using SlimProto time: 104.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 104.19s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 34.54 = 105.18
🔒 Using SlimProto time: 105.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 105.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 34.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 34.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 35.55 = 106.19
🔒 Using SlimProto time: 106.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 106.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 36.54 = 107.18
🔒 Using SlimProto time: 107.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 107.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 37.55 = 108.19
🔒 Using SlimProto time: 108.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 108.19s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 38.55 = 109.19
🔒 Using SlimProto time: 109.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 109.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 38.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 38.63, size: 61 bytes
📍 Responding to status request with TIMER status
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 38.73 = 109.37
🔒 Using SlimProto time: 109.37 (playing: YES)
🔍 Interpolated time: 70.64 + 39.55 = 110.19
🔒 Using SlimProto time: 110.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 110.19s (Server Time, playing: YES)
✅ FLAC Playing: 40.3s | Downloaded: 790448 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 40.55 = 111.19
🔒 Using SlimProto time: 111.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 111.19s (Server Time, playing: YES)
✅ FLAC Playing: 40.8s | Downloaded: 798389 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 70.64 + 41.55 = 112.19
🔒 Using SlimProto time: 112.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 112.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 42.55 = 113.19
🔒 Using SlimProto time: 113.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 113.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 43.55 = 114.19
🔒 Using SlimProto time: 114.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 114.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 43.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 43.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 44.55 = 115.19
🔒 Using SlimProto time: 115.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 115.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 45.55 = 116.19
🔒 Using SlimProto time: 116.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 116.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 46.55 = 117.19
🔒 Using SlimProto time: 117.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 117.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 47.55 = 118.19
🔒 Using SlimProto time: 118.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 118.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 47.63, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 47.63, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 48.55 = 119.19
🔒 Using SlimProto time: 119.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 119.19s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 49.55 = 120.19
🔒 Using SlimProto time: 120.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 120.19s (Server Time, playing: YES)
✅ FLAC Playing: 50.3s | Downloaded: 949272 | Buffer: CRITICAL (0% = 0s)
📞 Defaulting to phone call for interruption
🚫 Interruption began: Phone Call
🚫 Interruption began: Phone Call (shouldPause: YES)
🚫 Audio interrupted - was playing: YES
⏸️ Audio player paused
🔒 Audio player reports pause time: 50.35 (NOT using - server is master)
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (timeDiff: 19.0s)
📍 Updated from audio manager: 0.00 (state: paused)
⏸️ CBass playback paused
🔍 Interpolated time: 70.64 + 50.55 = 121.19
🔒 Using SlimProto time: 121.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 121.19s (Server Time, playing: YES)
🔀 Route change detected - reason: Category Change
🔀 Route change type: Unknown Route Change
⏱️ Using grace period for route change
🔍 Interpolated time: 70.64 + 51.55 = 122.19
🔒 Using SlimProto time: 122.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 122.19s (Server Time, playing: YES)
🔀 Processing route change: Unknown Route Change (shouldPause: NO)
🔀 Route changed: Unknown Route Change (shouldPause: NO)
🔍 Current Audio Session State:
  Category: AVAudioSessionCategoryPlayback
  Mode: AVAudioSessionModeDefault
  Options: AVAudioSessionCategoryOptions(rawValue: 1)
  Sample Rate: 44100 Hz
  Preferred Sample Rate: 0 Hz
  IO Buffer Duration: 23.220 ms
  Preferred IO Buffer Duration: 10.000 ms
  Other Audio Playing: YES
  Current Route: Unknown
  Interruption Status: Interrupted: Phone Call
🔀 Route change detected: Unknown Route Change (shouldPause: NO)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 52.55 = 123.19
🔒 Using SlimProto time: 123.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 123.19s (Server Time, playing: YES)
🔀 Route change detected - reason: Category Change
🔀 Route change type: Unknown Route Change
⏱️ Using grace period for route change
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 53.55 = 124.19
🔒 Using SlimProto time: 124.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 124.19s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 53.78 = 124.42
🔒 Using SlimProto time: 124.42 (playing: YES)
🔀 Processing route change: Unknown Route Change (shouldPause: NO)
🔀 Route changed: Unknown Route Change (shouldPause: NO)
🔍 Current Audio Session State:
  Category: AVAudioSessionCategoryPlayback
  Mode: AVAudioSessionModeDefault
  Options: AVAudioSessionCategoryOptions(rawValue: 1)
  Sample Rate: 32000 Hz
  Preferred Sample Rate: 0 Hz
  IO Buffer Duration: 20.000 ms
  Preferred IO Buffer Duration: 10.000 ms
  Other Audio Playing: YES
  Current Route: Receiver
  Interruption Status: Interrupted: Phone Call
🔀 Route change detected: Unknown Route Change (shouldPause: NO)
🔍 Interpolated time: 70.64 + 54.54 = 125.18
🔒 Using SlimProto time: 125.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 125.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 55.55 = 126.19
🔒 Using SlimProto time: 126.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 126.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 56.55 = 127.19
🔒 Using SlimProto time: 127.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 127.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 57.54 = 128.18
🔒 Using SlimProto time: 128.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 128.18s (Server Time, playing: YES)
🔀 Route change detected - reason: Override
🔀 Route change type: Speaker Change
⏱️ Using grace period for route change
🔍 Interpolated time: 70.64 + 58.55 = 129.19
🔒 Using SlimProto time: 129.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 129.19s (Server Time, playing: YES)
🔀 Processing route change: Speaker Change (shouldPause: NO)
🔀 Route changed: Speaker Change (shouldPause: NO)
🔍 Current Audio Session State:
  Category: AVAudioSessionCategoryPlayback
  Mode: AVAudioSessionModeDefault
  Options: AVAudioSessionCategoryOptions(rawValue: 1)
  Sample Rate: 48000 Hz
  Preferred Sample Rate: 0 Hz
  IO Buffer Duration: 20.000 ms
  Preferred IO Buffer Duration: 10.000 ms
  Other Audio Playing: YES
  Current Route: Speaker
  Interruption Status: Interrupted: Phone Call
🔀 Route change detected: Speaker Change (shouldPause: NO)
🔍 Interpolated time: 70.64 + 59.55 = 130.19
🔒 Using SlimProto time: 130.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 130.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 60.55 = 131.19
🔒 Using SlimProto time: 131.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 131.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 61.55 = 132.19
🔒 Using SlimProto time: 132.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 132.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 62.55 = 133.19
🔒 Using SlimProto time: 133.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 133.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 63.55 = 134.19
🔒 Using SlimProto time: 134.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 134.19s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 64.54 = 135.18
🔒 Using SlimProto time: 135.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 135.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 65.55 = 136.19
🔒 Using SlimProto time: 136.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 136.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 66.55 = 137.19
🔒 Using SlimProto time: 137.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 137.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 67.55 = 138.19
🔒 Using SlimProto time: 138.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 138.19s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 68.55 = 139.19
🔒 Using SlimProto time: 139.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 139.19s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 68.73 = 139.37
🔒 Using SlimProto time: 139.37 (playing: YES)
🔍 Interpolated time: 70.64 + 69.55 = 140.19
🔒 Using SlimProto time: 140.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 140.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 70.55 = 141.19
🔒 Using SlimProto time: 141.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 141.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 71.54 = 142.18
🔒 Using SlimProto time: 142.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 142.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 72.55 = 143.19
🔒 Using SlimProto time: 143.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 143.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 73.55 = 144.19
🔒 Using SlimProto time: 144.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 144.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 74.55 = 145.19
🔒 Using SlimProto time: 145.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 145.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 75.55 = 146.19
🔒 Using SlimProto time: 146.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 146.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 76.55 = 147.19
🔒 Using SlimProto time: 147.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 147.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 77.55 = 148.19
🔒 Using SlimProto time: 148.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 148.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 78.54 = 149.18
🔒 Using SlimProto time: 149.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 149.18s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 79.55 = 150.19
🔒 Using SlimProto time: 150.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 150.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 80.55 = 151.19
🔒 Using SlimProto time: 151.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 151.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 81.55 = 152.19
🔒 Using SlimProto time: 152.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 152.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 82.55 = 153.19
🔒 Using SlimProto time: 153.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 153.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 83.55 = 154.19
🔒 Using SlimProto time: 154.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 154.19s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 83.74 = 154.38
🔒 Using SlimProto time: 154.38 (playing: YES)
🔍 Interpolated time: 70.64 + 84.55 = 155.19
🔒 Using SlimProto time: 155.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 155.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 85.55 = 156.19
🔒 Using SlimProto time: 156.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 156.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 86.55 = 157.19
🔒 Using SlimProto time: 157.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 157.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 87.55 = 158.19
🔒 Using SlimProto time: 158.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 158.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 88.55 = 159.19
🔒 Using SlimProto time: 159.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 159.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 89.55 = 160.19
🔒 Using SlimProto time: 160.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 160.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 90.55 = 161.19
🔒 Using SlimProto time: 161.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 161.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 91.55 = 162.19
🔒 Using SlimProto time: 162.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 162.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 92.55 = 163.19
🔒 Using SlimProto time: 163.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 163.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 93.55 = 164.19
🔒 Using SlimProto time: 164.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 164.19s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 94.55 = 165.19
🔒 Using SlimProto time: 165.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 165.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 95.55 = 166.19
🔒 Using SlimProto time: 166.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 166.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 96.55 = 167.19
🔒 Using SlimProto time: 167.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 167.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 97.55 = 168.19
🔒 Using SlimProto time: 168.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 168.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 98.55 = 169.19
🔒 Using SlimProto time: 169.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 169.19s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 98.80 = 169.44
🔒 Using SlimProto time: 169.44 (playing: YES)
🔍 Interpolated time: 70.64 + 99.54 = 170.18
🔒 Using SlimProto time: 170.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 170.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 100.54 = 171.18
🔒 Using SlimProto time: 171.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 171.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 101.55 = 172.19
🔒 Using SlimProto time: 172.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 172.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 102.55 = 173.19
🔒 Using SlimProto time: 173.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 173.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 103.55 = 174.19
🔒 Using SlimProto time: 174.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 174.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 104.55 = 175.19
🔒 Using SlimProto time: 175.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 175.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 105.55 = 176.19
🔒 Using SlimProto time: 176.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 176.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 106.54 = 177.18
🔒 Using SlimProto time: 177.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 177.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 107.55 = 178.19
🔒 Using SlimProto time: 178.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 178.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 108.55 = 179.19
🔒 Using SlimProto time: 179.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 179.19s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 70.64 + 109.55 = 180.19
🔒 Using SlimProto time: 180.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 180.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 110.55 = 181.19
🔒 Using SlimProto time: 181.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 181.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.35, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 111.55 = 182.19
🔒 Using SlimProto time: 182.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 182.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 112.55 = 183.19
🔒 Using SlimProto time: 183.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 183.19s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'illicit affairs' by Taylor Swift [artwork]
🎵 Updated track metadata: illicit affairs - Taylor Swift (191 sec)
🎵 Updating track metadata: illicit affairs - Taylor Swift (191 sec)
🖼️ Loading artwork from: http://ser5:9000/music/718b9728/cover.jpg
🔍 Interpolated time: 70.64 + 113.54 = 184.18
🔒 Using SlimProto time: 184.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 184.18s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 70.64 + 113.75 = 184.39
🔒 Using SlimProto time: 184.39 (playing: YES)
🔀 Route change detected - reason: Override
🔀 Route change type: Speaker Change
⏱️ Using grace period for route change
🔀 Route change detected - reason: Override
🔀 Route change type: Speaker Change
⏱️ Using grace period for route change
🔀 Route change detected - reason: Category Change
🔀 Route change type: Unknown Route Change
⏱️ Using grace period for route change
✅ Interruption ended: Phone Call (duration: 63.9s, shouldResume: YES)
✅ Interruption ended: Phone Call (shouldResume: YES)
🔄 Reconfiguring audio session after interruption
✅ Audio session reconfigured successfully
✅ Interruption ended - should resume: YES
▶️ Resumed playback - server maintains position
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 50.35, size: 61 bytes
📍 Audio start event logged
▶️ CBass playback resumed
🔍 Interpolated time: 70.64 + 114.55 = 185.19
🔒 Using SlimProto time: 185.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 185.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.57, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 50.57, size: 61 bytes
📍 Responding to status request with TIMER status
✅ FLAC Playing: 50.7s | Downloaded: 957214 | Buffer: CRITICAL (0% = 0s)
🔀 Processing route change: Unknown Route Change (shouldPause: NO)
🔀 Route changed: Unknown Route Change (shouldPause: NO)
🔍 Current Audio Session State:
  Category: AVAudioSessionCategoryPlayback
  Mode: AVAudioSessionModeDefault
  Options: AVAudioSessionCategoryOptions(rawValue: 1)
  Sample Rate: 48000 Hz
  Preferred Sample Rate: 0 Hz
  IO Buffer Duration: 10.000 ms
  Preferred IO Buffer Duration: 10.000 ms
  Other Audio Playing: NO
  Current Route: Speaker
  Interruption Status: Normal
🔀 Route change detected: Unknown Route Change (shouldPause: NO)
🔍 Interpolated time: 70.64 + 115.55 = 186.19
🔒 Using SlimProto time: 186.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 186.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 116.54 = 187.18
🔒 Using SlimProto time: 187.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 187.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 117.55 = 188.19
🔒 Using SlimProto time: 188.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 188.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 118.55 = 189.19
🔒 Using SlimProto time: 189.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 189.19s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 119.55 = 190.19
🔒 Using SlimProto time: 190.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 190.19s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 55.54, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 55.54, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 70.64 + 120.54 = 191.18
🔒 Using SlimProto time: 191.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 191.18s (Server Time, playing: YES)
🔍 Interpolated time: 70.64 + 121.55 = 192.19
🔒 Using SlimProto time: 192.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 192.19s (Server Time, playing: YES)
Message from debugger: killed