ContentView initializing with Material Settings Integration
Loading settings from UserDefaults
Settings loaded - Host: ser5, Player: iOS Player, Configured: YES, FLAC: NO
Saving settings to UserDefaults
Settings saved successfully
✅ iOS audio session configured for CBass BEFORE BASS_Init
  Category: AVAudioSessionCategoryPlayback
  Sample Rate: 48000 Hz
  Buffer Duration: 5.0 ms
🔍 Checking BASSFLAC plugin availability...
❌ No BASS plugins detected
✅ BASS initialized - Version: 02041100
🔍 Testing BASSFLAC plugin availability...
❌ FLAC format not found in loaded plugins!
CBassAudioPlayer initialized with BASS audio library
AudioPlayer initialized with CBass audio engine
✅ Audio session setup deferred to CBass - preventing OSStatus -50 conflicts
   CBass will handle audio session configuration during BASS_Init
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
Creating WKWebView with Material Integration for URL: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755479010
Could not create a sandbox extension for '/var/containers/Bundle/Application/FC2D130A-67FC-489A-87F9-62745B8A6C02/LMS_StreamTest.app'
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
🌐 Network status: Wi-Fi (expensive: NO)
🌐 Network restored
🌐 Network change - Available: YES, Expensive: NO
🌐 Network available - attempting connection
Starting connection to Primary server...
🔄 Connection attempt starting
Server settings updated - Host: ser5, Port: 3483
Settings loaded - Host: ser5, Port: 3483
Attempting to connect to ser5:3483
Connection error: Attempting to connect while connected or accepting connections. Disconnect first.
📱 App became active
✅ WebView reference set for Material UI refresh
GPU process (0x114002300) took 1.266163 seconds to launch
Networking process (0x1140090b0) took 1.025584 seconds to launch
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
Server message length: 5 bytes
📨 Received: setd (1 bytes)
📛 SETD command received - ID: 0, payload length: 1
📛 Server requesting player name - sending: 'iOS Player'
📤 Raw message sent (19 bytes)
✅ SETD player name sent: 'iOS Player' (11 bytes)
tcp_connection_is_cellular No connected path
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
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
App is being debugged, do not track this hang
Hang detected: 1.59s (debugger attached, not reporting)
WebContent process (0x114000c80) took 3.186791 seconds to launch
🔍 Navigation decision for URL: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755479010
✅ Allowing navigation within LMS server: http://ser5:9000/material/?appSettings=lmsstream://settings&appSettingsName=iOS%20App%20Settings&_t=1755479010
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
🔄 Requested initial status to detect existing streams
🔍 Checking for custom position recovery from server preferences
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "?"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
App is being debugged, do not track this hang
Hang detected: 0.82s (debugger attached, not reporting)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
Started loading Material interface
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x120ed1e20>(
02:70:68:8c:51:41,
<__NSArrayI 0x120ecc3f0>(
playerpref,
lyrPlayLastPosition,
?
)

)
, "result": {
    "_p2" = "";
}, "method": slim.request, "id": 1]
ℹ️ No custom position found in server preferences
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📍 Responding to status request with TIMER status
App is being debugged, do not track this hang
Hang detected: 0.47s (debugger attached, not reporting)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
Finished loading Material interface
❌ Failed to inject settings handler: A JavaScript exception occurred
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
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
🎵 Format: MP3 - CBass handles audio session configuration
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Optimized MP3: 1.5s buffer, 32KB network, 3% prebuffer
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
App is being debugged, do not track this hang
Hang detected: 0.32s (debugger attached, not reporting)
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
🔍 No server time available, returning 0.0
⏰ NowPlayingManager TIMER UPDATE: 0.00s (Last Known, playing: NO)
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
📍 Server time updated: 0.00 (duration: 165.18, playing: YES)
📍 Updated from SlimProto: 0.00 (playing: YES)
📍 Updated server time: 0.00 (playing: YES) [Material-style]
📡 Real server time fetched: 0.00 (playing: YES)
🔍 Interpolated time: 0.00 + 0.62 = 0.62
🔒 Using SlimProto time: 0.62 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 0.62s (Server Time, playing: YES)
🔒 TIME SOURCE CHANGED: Server → Server Time
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Metadata duration updated: 165 seconds
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ Artwork loaded successfully
🔍 Interpolated time: 0.00 + 1.93 = 1.93
🔒 Using SlimProto time: 1.93 (playing: YES)
App is being debugged, do not track this hang
Hang detected: 0.34s (debugger attached, not reporting)
🔍 Interpolated time: 0.00 + 1.93 = 1.93
🔒 Using SlimProto time: 1.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 1.93s (Server Time, playing: YES)
📍 Server time updated: 0.00 (duration: 165.18, playing: YES)
📍 Updated from SlimProto: 0.00 (playing: YES)
📍 Updated server time: 0.00 (playing: YES) [Material-style]
📡 Real server time fetched: 0.00 (playing: YES)
🎵 Stream Info: Freq=44100Hz, Channels=1, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=209146758205323.72 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 88200 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483647
STAT packet: STMt, position: 0.00, size: 61 bytes
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.00, size: 61 bytes
📍 Responding to status request with TIMER status
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to register with iOS MediaPlayer framework: OSStatus -50
   Lock screen controls may not appear
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
🔍 Interpolated time: 0.00 + 0.56 = 0.56
🔒 Using SlimProto time: 0.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 0.56s (Server Time, playing: YES)
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ FLAC Playing: 0.4s | Downloaded: 416911 | Buffer: EXCELLENT (100% = 3s)
✅ Lock screen controls configured for CBass audio playback
🔍 Lock Screen Setup Verification:
  Now Playing Info: SET
  Play Command Enabled: YES
  Audio Session Category: AVAudioSessionCategoryPlayback
  Audio Session Active: YES
✅ FLAC Playing: 0.9s | Downloaded: 556307 | Buffer: EXCELLENT (100% = 4s)
🔍 Interpolated time: 0.00 + 1.56 = 1.56
🔒 Using SlimProto time: 1.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 1.56s (Server Time, playing: YES)
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
📍 CBass time update ignored - NowPlayingManager uses server time only
🔍 Interpolated time: 0.00 + 2.56 = 2.56
🔒 Using SlimProto time: 2.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 2.56s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 3.56 = 3.56
🔒 Using SlimProto time: 3.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 3.56s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 4.56 = 4.56
🔒 Using SlimProto time: 4.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 4.56s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 4.17, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 4.17, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 5.56 = 5.56
🔒 Using SlimProto time: 5.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 5.56s (Server Time, playing: YES)
✅ Track end detection enabled
🔍 Interpolated time: 0.00 + 6.56 = 6.56
🔒 Using SlimProto time: 6.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 6.56s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 5, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 0.00 + 6.99 = 6.99
🔍 Position sources - Server: 6.99, Audio: 6.41
✅ Using SimpleTimeTracker time: 6.99
💾 Saved position locally: 6.99 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 0.00 + 6.99 = 6.99
💾 Saving position to server preferences: 6.99 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "6.99"]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]], "id": 1, "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479036"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x124829c00>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483c060>(
playerpref,
lyrPlayLastPosition,
6.99
)

)
, "result": {
}, "method": slim.request, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x124829340>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483cea0>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "id": 1, "result": {
}, "method": slim.request]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["params": <__NSArrayI 0x124829340>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483ce10>(
playerpref,
lyrPlaySaveTime,
1755479036
)

)
, "id": 1, "result": {
}, "method": slim.request]
🔍 Interpolated time: 0.00 + 7.56 = 7.56
🔒 Using SlimProto time: 7.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 7.56s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 8.56 = 8.56
🔒 Using SlimProto time: 8.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 8.56s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.17, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.17, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 9.56 = 9.56
🔒 Using SlimProto time: 9.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 9.56s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 10.56 = 10.56
🔒 Using SlimProto time: 10.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 10.56s (Server Time, playing: YES)
✅ FLAC Playing: 10.4s | Downloaded: 715132 | Buffer: CRITICAL (0% = 0s)
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 10.69s, playing=YES
🔒 UPDATING LOCK SCREEN: 10.69s (timeDiff: 10.7s)
📍 Updated from audio manager: 10.69 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 5)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
✅ FLAC Playing: 10.9s | Downloaded: 723073 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 0.00 + 11.56 = 11.56
🔒 Using SlimProto time: 11.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 11.56s (Server Time, playing: YES)
📱 App became active
🔍 Interpolated time: 0.00 + 12.56 = 12.56
🔒 Using SlimProto time: 12.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 12.56s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.17, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.17, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 13.56 = 13.56
🔒 Using SlimProto time: 13.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 13.56s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ Artwork loaded successfully
🔍 Interpolated time: 0.00 + 14.49 = 14.49
🔒 Using SlimProto time: 14.49 (playing: YES)
🔍 Interpolated time: 0.00 + 14.56 = 14.56
🔒 Using SlimProto time: 14.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 14.56s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 15.56 = 15.56
🔒 Using SlimProto time: 15.56 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 15.56s (Server Time, playing: YES)
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
🎵 Format: MP3 - CBass handles audio session configuration
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Optimized MP3: 1.5s buffer, 32KB network, 3% prebuffer
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
🧹 CBass stream and callbacks cleaned up
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
📍 Server time updated: 114.00 (duration: 165.18, playing: YES)
📍 Updated from SlimProto: 114.00 (playing: YES)
📍 Updated server time: 114.00 (playing: YES) [Material-style]
📡 Real server time fetched: 114.00 (playing: YES)
🎵 Stream Info: Freq=44100Hz, Channels=1, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=209146758205323.72 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 88200 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
⚠️ Stream stalled - notifying delegate
STAT packet: STMt, position: 0.00, size: 61 bytes
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483643
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to register with iOS MediaPlayer framework: OSStatus -50
   Lock screen controls may not appear
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
🔍 Interpolated time: 114.00 + 0.37 = 114.37
🔒 Using SlimProto time: 114.37 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 114.37s (Server Time, playing: YES)
✅ FLAC Playing: 0.4s | Downloaded: 409502 | Buffer: EXCELLENT (100% = 3s)
✅ Lock screen controls configured for CBass audio playback
🔍 Lock Screen Setup Verification:
  Now Playing Info: SET
  Play Command Enabled: YES
  Audio Session Category: AVAudioSessionCategoryPlayback
  Audio Session Active: YES
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ FLAC Playing: 0.9s | Downloaded: 564248 | Buffer: EXCELLENT (100% = 4s)
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
📍 CBass time update ignored - NowPlayingManager uses server time only
🔍 Interpolated time: 114.00 + 1.37 = 115.37
🔒 Using SlimProto time: 115.37 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 115.37s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 1.42, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 1.42, size: 61 bytes
📍 Responding to status request with TIMER status
✅ Artwork loaded successfully
🔍 Interpolated time: 114.00 + 1.70 = 115.70
🔒 Using SlimProto time: 115.70 (playing: YES)
📍 Server time updated: 115.93 (duration: 165.18, playing: YES)
📍 Updated from SlimProto: 115.93 (playing: YES)
📍 Updated server time: 115.93 (playing: YES) [Material-style]
📡 Real server time fetched: 115.93 (playing: YES)
🔍 Interpolated time: 115.93 + 0.24 = 116.17
🔒 Using SlimProto time: 116.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 116.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 1.24 = 117.17
🔒 Using SlimProto time: 117.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 117.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 2.24 = 118.17
🔒 Using SlimProto time: 118.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 118.17s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 11, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 115.93 + 2.81 = 118.74
🔍 Position sources - Server: 118.74, Audio: 4.79
✅ Using SimpleTimeTracker time: 118.74
💾 Saved position locally: 118.74 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 115.93 + 2.81 = 118.74
💾 Saving position to server preferences: 118.74 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "118.74"]], "id": 1, "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479050"]], "method": "slim.request", "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbf60>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483fab0>(
playerpref,
lyrPlayLastPosition,
118.74
)

)
, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbde0>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483fc60>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbde0>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483f990>(
playerpref,
lyrPlaySaveTime,
1755479050
)

)
, "id": 1]
✅ Track end detection enabled
🔍 Interpolated time: 115.93 + 3.24 = 119.17
🔒 Using SlimProto time: 119.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 119.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 5.41, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 5.41, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 4.24 = 120.17
🔒 Using SlimProto time: 120.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 120.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 5.24 = 121.17
🔒 Using SlimProto time: 121.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 121.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 6.24 = 122.17
🔒 Using SlimProto time: 122.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 122.17s (Server Time, playing: YES)
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 8.28s, playing=YES
🔒 UPDATING LOCK SCREEN: 8.28s (timeDiff: 8.3s)
📍 Updated from audio manager: 8.28 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 11)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
📱 App became active
🔍 Interpolated time: 115.93 + 7.24 = 123.17
🔒 Using SlimProto time: 123.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 123.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 9.06, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 9.06, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 8.24 = 124.17
🔒 Using SlimProto time: 124.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 124.17s (Server Time, playing: YES)
✅ FLAC Playing: 10.1s | Downloaded: 715132 | Buffer: CRITICAL (0% = 0s)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 17, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 115.93 + 8.72 = 124.65
🔍 Position sources - Server: 124.65, Audio: 10.35
✅ Using SimpleTimeTracker time: 124.65
💾 Saved position locally: 124.65 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 115.93 + 8.72 = 124.65
💾 Saving position to server preferences: 124.65 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "124.65"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479056"]], "method": "slim.request", "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "result": {
}, "params": <__NSArrayI 0x120d32d40>(
02:70:68:8c:51:41,
<__NSArrayI 0x120ecea30>(
playerpref,
lyrPlayLastPosition,
124.65
)

)
]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "result": {
}, "params": <__NSArrayI 0x120d32c40>(
02:70:68:8c:51:41,
<__NSArrayI 0x120ece730>(
playerpref,
lyrPlayLastState,
Playing
)

)
]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "result": {
}, "params": <__NSArrayI 0x120d32c40>(
02:70:68:8c:51:41,
<__NSArrayI 0x120eceaf0>(
playerpref,
lyrPlaySaveTime,
1755479056
)

)
]
✅ FLAC Playing: 10.6s | Downloaded: 723073 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 115.93 + 9.26 = 125.19
🔒 Using SlimProto time: 125.19 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 125.19s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 10.24 = 126.17
🔒 Using SlimProto time: 126.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 126.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 11.24 = 127.17
🔒 Using SlimProto time: 127.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 127.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 13.06, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 13.06, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 12.24 = 128.17
🔒 Using SlimProto time: 128.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 128.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 13.24 = 129.18
🔒 Using SlimProto time: 129.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 129.18s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
🔍 Interpolated time: 115.93 + 14.24 = 130.17
🔒 Using SlimProto time: 130.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 130.17s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 115.93 + 14.55 = 130.48
🔒 Using SlimProto time: 130.48 (playing: YES)
🔍 Interpolated time: 115.93 + 15.24 = 131.18
🔒 Using SlimProto time: 131.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 131.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.05, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.05, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 16.24 = 132.18
🔒 Using SlimProto time: 132.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 132.18s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 17.24 = 133.17
🔒 Using SlimProto time: 133.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 133.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 18.24 = 134.17
🔒 Using SlimProto time: 134.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 134.17s (Server Time, playing: YES)
✅ FLAC Playing: 20.1s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 20.6s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 115.93 + 19.24 = 135.17
🔒 Using SlimProto time: 135.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 135.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.06, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.06, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 20.24 = 136.17
🔒 Using SlimProto time: 136.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 136.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 21.24 = 137.17
🔒 Using SlimProto time: 137.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 137.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 22.24 = 138.17
🔒 Using SlimProto time: 138.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 138.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 23.24 = 139.17
🔒 Using SlimProto time: 139.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 139.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 24.24 = 140.17
🔒 Using SlimProto time: 140.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 140.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 26.05, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 26.05, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 25.24 = 141.17
🔒 Using SlimProto time: 141.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 141.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 26.24 = 142.18
🔒 Using SlimProto time: 142.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 142.18s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 27.24 = 143.17
🔒 Using SlimProto time: 143.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 143.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 28.24 = 144.17
🔒 Using SlimProto time: 144.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 144.17s (Server Time, playing: YES)
✅ FLAC Playing: 30.1s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 30.13, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 30.13, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ FLAC Playing: 30.6s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 115.93 + 29.24 = 145.17
🔒 Using SlimProto time: 145.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 145.17s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 115.93 + 29.64 = 145.57
🔒 Using SlimProto time: 145.57 (playing: YES)
🔍 Interpolated time: 115.93 + 30.24 = 146.17
🔒 Using SlimProto time: 146.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 146.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 31.24 = 147.17
🔒 Using SlimProto time: 147.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 147.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 32.24 = 148.17
🔒 Using SlimProto time: 148.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 148.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 34.11, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 34.11, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 33.24 = 149.17
🔒 Using SlimProto time: 149.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 149.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 34.24 = 150.17
🔒 Using SlimProto time: 150.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 150.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 35.24 = 151.17
🔒 Using SlimProto time: 151.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 151.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 36.24 = 152.17
🔒 Using SlimProto time: 152.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 152.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 38.06, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 38.06, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 37.24 = 153.17
🔒 Using SlimProto time: 153.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 153.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 38.24 = 154.18
🔒 Using SlimProto time: 154.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 154.18s (Server Time, playing: YES)
✅ FLAC Playing: 40.1s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
💓 Health check requested
✅ FLAC Playing: 40.6s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 115.93 + 39.24 = 155.17
🔒 Using SlimProto time: 155.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 155.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 40.24 = 156.17
🔒 Using SlimProto time: 156.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 156.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 42.06, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 42.06, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 41.24 = 157.17
🔒 Using SlimProto time: 157.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 157.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 42.24 = 158.17
🔒 Using SlimProto time: 158.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 158.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 43.24 = 159.17
🔒 Using SlimProto time: 159.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 159.17s (Server Time, playing: YES)
Background Task 16 ("AVPlayerBackgroundPlayback"), was created over 30 seconds ago. In applications running in the background, this creates a risk of termination. Remember to call UIApplication.endBackgroundTask(_:) for your task in a timely manner to avoid this.
Background Task 17 ("SlimProtoConnectionExtended"), was created over 30 seconds ago. In applications running in the background, this creates a risk of termination. Remember to call UIApplication.endBackgroundTask(_:) for your task in a timely manner to avoid this.
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
🔍 Interpolated time: 115.93 + 44.24 = 160.17
🔒 Using SlimProto time: 160.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 160.17s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 115.93 + 44.56 = 160.49
🔒 Using SlimProto time: 160.49 (playing: YES)
🔍 Interpolated time: 115.93 + 45.24 = 161.17
🔒 Using SlimProto time: 161.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 161.17s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 47.11, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 47.11, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 115.93 + 46.24 = 162.17
🔒 Using SlimProto time: 162.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 162.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 47.24 = 163.17
🔒 Using SlimProto time: 163.17 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 163.17s (Server Time, playing: YES)
🔍 Interpolated time: 115.93 + 48.24 = 164.18
🔒 Using SlimProto time: 164.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 164.18s (Server Time, playing: YES)
✅ FLAC Playing: 50.1s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 50.6s | Downloaded: 819617 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 115.93 + 49.24 = 165.18
🔒 Using SlimProto time: 165.18 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 165.18s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 51.10, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 51.10, size: 61 bytes
📍 Responding to status request with TIMER status
⚠️ Stream stopped unexpectedly at 51.2s/165.2s - likely starvation, NOT track end
🚨 Stream starvation detected - notifying server (squeezelite-style)
⚠️ Audio player stalled
❌ FLAC Stream STOPPED at 51.2s | Buffer: CRITICAL (0% = 0s)
🚨 Reporting stream disconnection: 51.2s/165.2s (reason: Network starvation)
📡 Sending STMd (stream disconnected) to server at position 51.2s
📤 Sending STAT: STMd
STAT packet: STMd, position: 0.00, size: 61 bytes
📡 Notified server: Stream disconnected at 51.2s (reason: starvation)
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
🎵 Format: MP3 - CBass handles audio session configuration
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Optimized MP3: 1.5s buffer, 32KB network, 3% prebuffer
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
🧹 CBass stream and callbacks cleaned up
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
📤 Sending STAT: STMt
🎵 Stream Info: Freq=44100Hz, Channels=1, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=209146758205323.72 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 88200 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
STAT packet: STMt, position: 0.00, size: 61 bytes
STAT packet: STMt, position: 0.00, size: 61 bytes
🔍 Interpolated time: 115.93 + 52.42 = 168.35
🔒 Using SlimProto time: 168.35 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 168.35s (Server Time, playing: YES)
📍 Server time updated: 114.00 (duration: 165.18, playing: YES)
📍 Updated from SlimProto: 114.00 (playing: YES)
📍 Updated server time: 114.00 (playing: YES) [Material-style]
📡 Real server time fetched: 114.00 (playing: YES)
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483639
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to register with iOS MediaPlayer framework: OSStatus -50
   Lock screen controls may not appear
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
🎵 Material-style: 'Enough Is Enough' by Post Malone [artwork]
🎵 Updated track metadata: Enough Is Enough - Post Malone (165 sec)
🎵 Updating track metadata: Enough Is Enough - Post Malone (165 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
📍 Server time updated: 0.00 (duration: 139.36, playing: YES)
📍 Updated from SlimProto: 0.00 (playing: YES)
📍 Updated server time: 0.00 (playing: YES) [Material-style]
📡 Real server time fetched: 0.00 (playing: YES)
✅ FLAC Playing: 0.5s | Downloaded: 462758 | Buffer: EXCELLENT (100% = 3s)
✅ Lock screen controls configured for CBass audio playback
🔍 Lock Screen Setup Verification:
  Now Playing Info: SET
  Play Command Enabled: YES
  Audio Session Category: AVAudioSessionCategoryPlayback
  Audio Session Active: YES
🔍 Interpolated time: 0.00 + 0.55 = 0.55
🔒 Using SlimProto time: 0.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 0.55s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 0.00 + 0.58 = 0.58
🔒 Using SlimProto time: 0.58 (playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.93, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
📍 CBass time update ignored - NowPlayingManager uses server time only
🔍 Interpolated time: 0.00 + 1.55 = 1.55
🔒 Using SlimProto time: 1.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 1.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 2.55 = 2.55
🔒 Using SlimProto time: 2.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 2.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 3.55 = 3.55
🔒 Using SlimProto time: 3.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 3.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 4.55 = 4.55
🔒 Using SlimProto time: 4.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 4.55s (Server Time, playing: YES)
✅ Track end detection enabled
🔍 Interpolated time: 0.00 + 5.55 = 5.55
🔒 Using SlimProto time: 5.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 5.55s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 5.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 5.93, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 6.55 = 6.55
🔒 Using SlimProto time: 6.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 6.55s (Server Time, playing: YES)
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 7.17s, playing=YES
🔒 UPDATING LOCK SCREEN: 7.17s (timeDiff: 7.2s)
📍 Updated from audio manager: 7.17 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 17)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
📱 App became active
🔍 Interpolated time: 0.00 + 7.55 = 7.55
🔒 Using SlimProto time: 7.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 7.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 8.55 = 8.55
🔒 Using SlimProto time: 8.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 8.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 9.55 = 9.55
🔒 Using SlimProto time: 9.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 9.55s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 9.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 9.93, size: 61 bytes
📍 Responding to status request with TIMER status
✅ FLAC Playing: 10.0s | Downloaded: 715132 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 10.5s | Downloaded: 723073 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 0.00 + 10.55 = 10.55
🔒 Using SlimProto time: 10.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 10.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 11.55 = 11.55
🔒 Using SlimProto time: 11.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 11.55s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 23, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 0.00 + 12.55 = 12.55
🔍 Position sources - Server: 12.55, Audio: 12.74
✅ Using SimpleTimeTracker time: 12.55
💾 Saved position locally: 12.55 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 0.00 + 12.55 = 12.55
💾 Saving position to server preferences: 12.55 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "12.55"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]], "id": 1, "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479112"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "params": <__NSArrayI 0x120d32c80>(
02:70:68:8c:51:41,
<__NSArrayI 0x120ffc450>(
playerpref,
lyrPlayLastPosition,
12.55
)

)
, "result": {
}]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "params": <__NSArrayI 0x120d32ca0>(
02:70:68:8c:51:41,
<__NSArrayI 0x120ffc330>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "result": {
}]
🔍 Interpolated time: 0.00 + 12.67 = 12.67
🔒 Using SlimProto time: 12.67 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 12.67s (Server Time, playing: YES)
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "id": 1, "params": <__NSArrayI 0x12482a520>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483dbf0>(
playerpref,
lyrPlaySaveTime,
1755479112
)

)
, "result": {
}]
🔍 Interpolated time: 0.00 + 13.55 = 13.55
🔒 Using SlimProto time: 13.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 13.55s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 13.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 13.93, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 14.55 = 14.55
🔒 Using SlimProto time: 14.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 14.55s (Server Time, playing: YES)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Texas Tea' by Post Malone [artwork]
🎵 Metadata duration updated: 139 seconds
🎵 Updated track metadata: Texas Tea - Post Malone (139 sec)
🎵 Updating track metadata: Texas Tea - Post Malone (139 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ Artwork loaded successfully
🔍 Interpolated time: 0.00 + 15.49 = 15.49
🔒 Using SlimProto time: 15.49 (playing: YES)
🔍 Interpolated time: 0.00 + 15.55 = 15.55
🔒 Using SlimProto time: 15.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 15.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 16.55 = 16.55
🔒 Using SlimProto time: 16.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 16.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 17.55 = 17.55
🔒 Using SlimProto time: 17.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 17.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 18.55 = 18.55
🔒 Using SlimProto time: 18.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 18.55s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 18.99, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 18.99, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 19.55 = 19.55
🔒 Using SlimProto time: 19.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 19.55s (Server Time, playing: YES)
✅ FLAC Playing: 20.0s | Downloaded: 873956 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 20.5s | Downloaded: 881897 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 0.00 + 20.55 = 20.55
🔒 Using SlimProto time: 20.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 20.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 21.55 = 21.55
🔒 Using SlimProto time: 21.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 21.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 22.55 = 22.55
🔒 Using SlimProto time: 22.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 22.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 23.55 = 23.55
🔒 Using SlimProto time: 23.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 23.55s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 23.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 23.93, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 24.55 = 24.55
🔒 Using SlimProto time: 24.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 24.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 25.55 = 25.55
🔒 Using SlimProto time: 25.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 25.55s (Server Time, playing: YES)
🔍 Interpolated time: 0.00 + 26.55 = 26.55
🔒 Using SlimProto time: 26.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 26.55s (Server Time, playing: YES)
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 27.17s, playing=YES
🔒 UPDATING LOCK SCREEN: 27.17s (timeDiff: 20.0s)
📍 Updated from audio manager: 27.17 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 23)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
📱 App became active
🔍 Interpolated time: 0.00 + 27.54 = 27.54
🔒 Using SlimProto time: 27.54 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 27.54s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 27.93, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 27.93, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 0.00 + 28.55 = 28.55
🔒 Using SlimProto time: 28.55 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 28.55s (Server Time, playing: YES)
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
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
STAT packet: STMf, position: 0.00, size: 61 bytes
📤 Sending STAT: STMf
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
STAT packet: STMf, position: 0.00, size: 61 bytes
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
🎵 Format: MP3 - CBass handles audio session configuration
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Optimized MP3: 1.5s buffer, 32KB network, 3% prebuffer
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🧹 CBass stream and callbacks cleaned up
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
📍 Server time updated: 106.00 (duration: 139.36, playing: YES)
📍 Updated from SlimProto: 106.00 (playing: YES)
📍 Updated server time: 106.00 (playing: YES) [Material-style]
📡 Real server time fetched: 106.00 (playing: YES)
🎵 Stream Info: Freq=44100Hz, Channels=1, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=209146758205323.72 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 88200 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483635
STAT packet: STMt, position: 0.00, size: 61 bytes
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to register with iOS MediaPlayer framework: OSStatus -50
   Lock screen controls may not appear
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
🔍 Interpolated time: 106.00 + 0.44 = 106.44
🔒 Using SlimProto time: 106.44 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 106.44s (Server Time, playing: YES)
✅ FLAC Playing: 0.3s | Downloaded: 289544 | Buffer: EXCELLENT (100% = 2s)
✅ Lock screen controls configured for CBass audio playback
🔍 Lock Screen Setup Verification:
  Now Playing Info: SET
  Play Command Enabled: YES
  Audio Session Category: AVAudioSessionCategoryPlayback
  Audio Session Active: YES
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
🎵 Material-style: 'Texas Tea' by Post Malone [artwork]
🎵 Updated track metadata: Texas Tea - Post Malone (139 sec)
🎵 Updating track metadata: Texas Tea - Post Malone (139 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ FLAC Playing: 0.8s | Downloaded: 534569 | Buffer: EXCELLENT (100% = 4s)
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
📍 CBass time update ignored - NowPlayingManager uses server time only
🔍 Interpolated time: 106.00 + 1.44 = 107.44
🔒 Using SlimProto time: 107.44 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 107.44s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 106.00 + 1.64 = 107.64
🔒 Using SlimProto time: 107.64 (playing: YES)
📍 Server time updated: 106.00 (duration: 139.36, playing: YES)
📍 Updated from SlimProto: 106.00 (playing: YES)
📍 Updated server time: 106.00 (playing: YES) [Material-style]
📡 Real server time fetched: 106.00 (playing: YES)
🔍 Interpolated time: 106.00 + 0.41 = 106.41
🔒 Using SlimProto time: 106.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 106.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 1.41 = 107.41
🔒 Using SlimProto time: 107.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 107.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 3.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 3.38, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 2.41 = 108.41
🔒 Using SlimProto time: 108.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 108.41s (Server Time, playing: YES)
✅ Track end detection enabled
🔍 Interpolated time: 106.00 + 3.41 = 109.41
🔒 Using SlimProto time: 109.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 109.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 4.41 = 110.41
🔒 Using SlimProto time: 110.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 110.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 5.41 = 111.41
🔒 Using SlimProto time: 111.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 111.41s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 29, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 106.00 + 5.58 = 111.58
🔍 Position sources - Server: 111.58, Audio: 7.36
✅ Using SimpleTimeTracker time: 111.58
💾 Saved position locally: 111.58 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 106.00 + 5.58 = 111.58
💾 Saving position to server preferences: 111.58 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["id": 1, "method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "111.58"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["method": "slim.request", "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]], "id": 1]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["method": "slim.request", "id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479137"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 7.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 7.38, size: 61 bytes
📍 Responding to status request with TIMER status
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "params": <__NSArrayI 0x120ed2400>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483e1c0>(
playerpref,
lyrPlayLastPosition,
111.58
)

)
, "id": 1, "result": {
}]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "params": <__NSArrayI 0x120ed2a40>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483e190>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "id": 1, "result": {
}]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["method": slim.request, "params": <__NSArrayI 0x120ed1bc0>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483e5e0>(
playerpref,
lyrPlaySaveTime,
1755479137
)

)
, "id": 1, "result": {
}]
🔍 Interpolated time: 106.00 + 6.41 = 112.41
🔒 Using SlimProto time: 112.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 112.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 7.41 = 113.41
🔒 Using SlimProto time: 113.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 113.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 8.41 = 114.41
🔒 Using SlimProto time: 114.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 114.41s (Server Time, playing: YES)
✅ FLAC Playing: 10.3s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 10.8s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 9.41 = 115.41
🔒 Using SlimProto time: 115.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 115.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 11.46, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 11.46, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 10.41 = 116.41
🔒 Using SlimProto time: 116.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 116.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 11.41 = 117.41
🔒 Using SlimProto time: 117.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 117.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 12.41 = 118.41
🔒 Using SlimProto time: 118.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 118.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 13.41 = 119.41
🔒 Using SlimProto time: 119.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 119.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 15.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 15.38, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🎵 Material-style: 'Texas Tea' by Post Malone [artwork]
🎵 Updated track metadata: Texas Tea - Post Malone (139 sec)
🎵 Updating track metadata: Texas Tea - Post Malone (139 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
🔍 Interpolated time: 106.00 + 14.41 = 120.41
🔒 Using SlimProto time: 120.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 120.41s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 106.00 + 14.60 = 120.60
🔒 Using SlimProto time: 120.60 (playing: YES)
🔍 Interpolated time: 106.00 + 15.41 = 121.41
🔒 Using SlimProto time: 121.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 121.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 16.41 = 122.41
🔒 Using SlimProto time: 122.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 122.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 17.41 = 123.41
🔒 Using SlimProto time: 123.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 123.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 19.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 19.38, size: 61 bytes
📍 Responding to status request with TIMER status
📱 App entering foreground
🏁 Background task ended
📱 Audio session entered foreground
🔄 NowPlayingManager received update: 19.68s, playing=YES
🔒 UPDATING LOCK SCREEN: 19.68s (timeDiff: 19.7s)
📍 Updated from audio manager: 19.68 (state: playing)
✅ Audio session maintained proper configuration in background
📱 App entering foreground
🏁 Ending enhanced background task (ID: 29)
💓 Health monitoring started (15 sec intervals)
📱 App foregrounded - cleared lock screen recovery flag
⚠️ Foreground recovery disabled - too unreliable
📱 Foreground transition complete
🔍 Interpolated time: 106.00 + 18.41 = 124.41
🔒 Using SlimProto time: 124.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 124.41s (Server Time, playing: YES)
📱 App became active
✅ FLAC Playing: 20.3s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
✅ FLAC Playing: 20.8s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 19.41 = 125.41
🔒 Using SlimProto time: 125.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 125.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 20.41 = 126.41
🔒 Using SlimProto time: 126.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 126.41s (Server Time, playing: YES)
📱 App entering background
🎯 Background task started
📱 Audio session entered background
📱 App entering background
🎯 Enhanced background task started (ID: 35, time: 179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368 sec)
💓 Health monitoring started (30 sec intervals)
📱 App backgrounded - saving position for potential recovery
🔍 Pause state - lockScreen: NO, player: Playing
💾 Saving position for potential recovery
🔍 Interpolated time: 106.00 + 20.69 = 126.69
🔍 Position sources - Server: 126.69, Audio: 22.47
✅ Using SimpleTimeTracker time: 126.69
💾 Saved position locally: 126.69 seconds (from SimpleTimeTracker)
🔍 Interpolated time: 106.00 + 20.69 = 126.69
💾 Saving position to server preferences: 126.69 seconds (state: Playing)
🌐 Sending JSON-RPC command: ["method": "slim.request", "id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastPosition", "126.69"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlayLastState", "Playing"]], "method": "slim.request"]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
🌐 Sending JSON-RPC command: ["method": "slim.request", "id": 1, "params": ["02:70:68:8c:51:41", ["playerpref", "lyrPlaySaveTime", "1755479152"]]]
🌐 JSON-RPC URL: http://ser5:9000/material/jsonrpc.js
▶️ App backgrounded while playing - maintaining connection for background audio
📱 Background transition complete
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbd40>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483cb10>(
playerpref,
lyrPlayLastPosition,
126.69
)

)
, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbd40>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483e190>(
playerpref,
lyrPlayLastState,
Playing
)

)
, "id": 1]
🌐 JSON-RPC response status: 200
✅ JSON-RPC response: ["result": {
}, "method": slim.request, "params": <__NSArrayI 0x1201fbf80>(
02:70:68:8c:51:41,
<__NSArrayI 0x12483ec10>(
playerpref,
lyrPlaySaveTime,
1755479152
)

)
, "id": 1]
🔍 Interpolated time: 106.00 + 21.41 = 127.41
🔒 Using SlimProto time: 127.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 127.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 23.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 23.38, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 22.41 = 128.41
🔒 Using SlimProto time: 128.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 128.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 23.41 = 129.41
🔒 Using SlimProto time: 129.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 129.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 24.41 = 130.41
🔒 Using SlimProto time: 130.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 130.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 25.41 = 131.41
🔒 Using SlimProto time: 131.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 131.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 26.41 = 132.41
🔒 Using SlimProto time: 132.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 132.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 28.38, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 28.38, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 27.41 = 133.41
🔒 Using SlimProto time: 133.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 133.41s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 28.41 = 134.41
🔒 Using SlimProto time: 134.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 134.41s (Server Time, playing: YES)
✅ FLAC Playing: 30.3s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
✅ FLAC Playing: 30.8s | Downloaded: 534569 | Buffer: CRITICAL (0% = 0s)
🎵 Material-style: 'Texas Tea' by Post Malone [artwork]
🎵 Updated track metadata: Texas Tea - Post Malone (139 sec)
🎵 Updating track metadata: Texas Tea - Post Malone (139 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
🔍 Interpolated time: 106.00 + 29.41 = 135.41
🔒 Using SlimProto time: 135.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 135.41s (Server Time, playing: YES)
✅ Artwork loaded successfully
🔍 Interpolated time: 106.00 + 29.67 = 135.67
🔒 Using SlimProto time: 135.67 (playing: YES)
🔍 Interpolated time: 106.00 + 30.41 = 136.41
🔒 Using SlimProto time: 136.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 136.41s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 32.43, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 32.43, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 31.41 = 137.41
🔒 Using SlimProto time: 137.41 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 137.41s (Server Time, playing: YES)
⚠️ Stream stopped unexpectedly at 33.4s/139.4s - likely starvation, NOT track end
🚨 Stream starvation detected - notifying server (squeezelite-style)
⚠️ Audio player stalled
❌ FLAC Stream STOPPED at 33.4s | Buffer: CRITICAL (0% = 0s)
🚨 Reporting stream disconnection: 33.4s/139.4s (reason: Network starvation)
📡 Sending STMd (stream disconnected) to server at position 33.4s
📤 Sending STAT: STMd
STAT packet: STMd, position: 0.00, size: 61 bytes
📡 Notified server: Stream disconnected at 33.4s (reason: starvation)
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
🎵 Format: MP3 - CBass handles audio session configuration
🎵 Playing MP3 stream via CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Playing MP3 stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🎵 Optimized MP3: 1.5s buffer, 32KB network, 3% prebuffer
⏹️ Audio player stopped
🔄 NowPlayingManager received update: 0.00s, playing=NO
🔒 UPDATING LOCK SCREEN: 0.00s (NEW TRACK - forcing update)
🎵 Playing stream with CBass: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
⏹️ Stopped periodic server time fetching
📍 Updated from audio manager: 0.00 (state: paused)
⏹️ CBass playback stopped
🧹 CBass stream and callbacks cleaned up
🔧 Creating BASS stream for URL: http://ser5:9000/stream.mp3?player=02:70:68:8c:51:41
🔄 Started periodic server time fetching
Server message length: 26 bytes
📨 Received: audg (22 bytes)
📤 Sending STAT: STMt
📍 Server time updated: 106.00 (duration: 139.36, playing: YES)
📍 Updated from SlimProto: 106.00 (playing: YES)
📍 Updated server time: 106.00 (playing: YES) [Material-style]
📡 Real server time fetched: 106.00 (playing: YES)
🔍 Interpolated time: 106.00 + 0.04 = 106.04
🔒 Using SlimProto time: 106.04 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 106.04s (Server Time, playing: YES)
🌐 Requesting enhanced track metadata
🎵 Started metadata refresh for radio stream
🔍 Interpolated time: 106.00 + 1.04 = 107.04
🔒 Using SlimProto time: 107.04 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 107.04s (Server Time, playing: YES)
🎵 Material-style: 'Texas Tea' by Post Malone [artwork]
🎵 Updated track metadata: Texas Tea - Post Malone (139 sec)
🎵 Updating track metadata: Texas Tea - Post Malone (139 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ Artwork loaded successfully
🔍 Interpolated time: 106.00 + 1.68 = 107.68
🔒 Using SlimProto time: 107.68 (playing: YES)
🔍 Interpolated time: 106.00 + 2.04 = 108.04
🔒 Using SlimProto time: 108.04 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 108.04s (Server Time, playing: YES)
📍 Server time updated: 106.00 (duration: 139.36, playing: YES)
📍 Updated from SlimProto: 106.00 (playing: YES)
📍 Updated server time: 106.00 (playing: YES) [Material-style]
📡 Real server time fetched: 106.00 (playing: YES)
🎵 Stream Info: Freq=44100Hz, Channels=1, Type=00010005, Flags=00140010
✅ Confirmed FLAC stream type
🎵 FLAC Details: Length=-1 bytes, Duration=209146758205323.72 seconds
🎵 Initial position: 0 bytes
🔧 Setting up BASS_SYNC_POS at 88200 bytes (1.0 second mark)
✅ CBass callbacks configured: track end, stall detection, position updates, metadata
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ CBass stream started successfully - Handle: -2147483631
STAT packet: STMt, position: 0.00, size: 61 bytes
AVAudioSessionClient_Common.mm:600   Failed to set properties, error: -50
❌ Failed to register with iOS MediaPlayer framework: OSStatus -50
   Lock screen controls may not appear
🔗 Stream connected
📤 Sending STAT: STMc
STAT packet: STMc, position: 0.00, size: 61 bytes
▶️ Audio player started playing
🎵 Audio playback actually started - sending STMs
📤 Sending STAT: STMs
STAT packet: STMs, position: 0.00, size: 61 bytes
📍 Audio start event logged
⚠️ Stream stalled - notifying delegate
⚠️ Audio player stalled
✅ FLAC Playing: 0.4s | Downloaded: 420999 | Buffer: EXCELLENT (100% = 3s)
🔍 Interpolated time: 106.00 + 0.93 = 106.93
🔒 Using SlimProto time: 106.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 106.93s (Server Time, playing: YES)
✅ Lock screen controls configured for CBass audio playback
🔍 Lock Screen Setup Verification:
  Now Playing Info: SET
  Play Command Enabled: YES
  Audio Session Category: AVAudioSessionCategoryPlayback
  Audio Session Active: YES
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.64, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 0.64, size: 61 bytes
📍 Responding to status request with TIMER status
✅ FLAC Playing: 0.9s | Downloaded: 564248 | Buffer: EXCELLENT (100% = 4s)
🔄 CBass Position Sync: 1.00s → delegate?.audioPlayerTimeDidUpdate()
🔄 AudioManager received time update: 1.00s from audioPlayer
📍 CBass time update ignored - NowPlayingManager uses server time only
🔍 Interpolated time: 106.00 + 1.93 = 107.93
🔒 Using SlimProto time: 107.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 107.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 2.93 = 108.93
🔒 Using SlimProto time: 108.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 108.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 3.94 = 109.94
🔒 Using SlimProto time: 109.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 109.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 4.93 = 110.93
🔒 Using SlimProto time: 110.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 110.93s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 4.64, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 4.64, size: 61 bytes
📍 Responding to status request with TIMER status
✅ Track end detection enabled
🔍 Interpolated time: 106.00 + 5.94 = 111.94
🔒 Using SlimProto time: 111.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 111.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 6.93 = 112.93
🔒 Using SlimProto time: 112.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 112.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 7.93 = 113.93
🔒 Using SlimProto time: 113.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 113.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 8.93 = 114.93
🔒 Using SlimProto time: 114.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 114.93s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.64, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 8.64, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 9.93 = 115.93
🔒 Using SlimProto time: 115.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 115.93s (Server Time, playing: YES)
✅ FLAC Playing: 10.4s | Downloaded: 723073 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 10.93 = 116.93
🔒 Using SlimProto time: 116.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 116.93s (Server Time, playing: YES)
✅ FLAC Playing: 10.9s | Downloaded: 723073 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 11.94 = 117.94
🔒 Using SlimProto time: 117.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 117.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 12.93 = 118.93
🔒 Using SlimProto time: 118.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 118.93s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.69, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 12.69, size: 61 bytes
📍 Responding to status request with TIMER status
🔄 Timer triggered metadata refresh
🌐 Requesting enhanced track metadata
🔍 Interpolated time: 106.00 + 13.93 = 119.93
🔒 Using SlimProto time: 119.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 119.93s (Server Time, playing: YES)
🎵 Material-style: 'Buyer Beware' by Post Malone [artwork]
🎵 Metadata duration updated: 173 seconds
🎵 Updated track metadata: Buyer Beware - Post Malone (173 sec)
🎵 Updating track metadata: Buyer Beware - Post Malone (173 sec)
🖼️ Loading artwork from: http://ser5:9000/music/fd4936fc/cover.jpg
✅ Artwork loaded successfully
🔍 Interpolated time: 106.00 + 14.57 = 120.57
🔒 Using SlimProto time: 120.57 (playing: YES)
🔍 Interpolated time: 106.00 + 14.93 = 120.93
🔒 Using SlimProto time: 120.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 120.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 15.93 = 121.93
🔒 Using SlimProto time: 121.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 121.93s (Server Time, playing: YES)
💓 Health check requested
🔍 Interpolated time: 106.00 + 16.94 = 122.94
🔒 Using SlimProto time: 122.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 122.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 17.93 = 123.93
🔒 Using SlimProto time: 123.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 123.93s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.72, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 17.72, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 18.94 = 124.94
🔒 Using SlimProto time: 124.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 124.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 19.93 = 125.93
🔒 Using SlimProto time: 125.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 125.93s (Server Time, playing: YES)
✅ FLAC Playing: 20.4s | Downloaded: 881897 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 20.93 = 126.93
🔒 Using SlimProto time: 126.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 126.93s (Server Time, playing: YES)
Background Task 35 ("SlimProtoConnectionExtended"), was created over 30 seconds ago. In applications running in the background, this creates a risk of termination. Remember to call UIApplication.endBackgroundTask(_:) for your task in a timely manner to avoid this.
Background Task 34 ("AVPlayerBackgroundPlayback"), was created over 30 seconds ago. In applications running in the background, this creates a risk of termination. Remember to call UIApplication.endBackgroundTask(_:) for your task in a timely manner to avoid this.
✅ FLAC Playing: 20.9s | Downloaded: 889839 | Buffer: CRITICAL (0% = 0s)
🔍 Interpolated time: 106.00 + 21.93 = 127.93
🔒 Using SlimProto time: 127.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 127.93s (Server Time, playing: YES)
Server message length: 28 bytes
📨 Received: strm (24 bytes)
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.64, size: 61 bytes
📤 Sending STAT: STMt
STAT packet: STMt, position: 21.64, size: 61 bytes
📍 Responding to status request with TIMER status
🔍 Interpolated time: 106.00 + 22.94 = 128.94
🔒 Using SlimProto time: 128.94 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 128.94s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 23.93 = 129.93
🔒 Using SlimProto time: 129.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 129.93s (Server Time, playing: YES)
🔍 Interpolated time: 106.00 + 24.93 = 130.93
🔒 Using SlimProto time: 130.93 (playing: YES)
⏰ NowPlayingManager TIMER UPDATE: 130.93s (Server Time, playing: YES)
Message from debugger: killed