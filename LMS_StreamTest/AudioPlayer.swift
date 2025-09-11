// File: AudioPlayer.swift
// Updated to use CBass for minimal native FLAC support
import Foundation
import Bass
import BassFLAC
import BassOpus
import MediaPlayer
import AVFoundation
import os.log

protocol AudioPlayerDelegate: AnyObject {
    func audioPlayerDidStartPlaying()
    func audioPlayerDidPause()
    func audioPlayerDidStop()
    func audioPlayerDidReachEnd()
    func audioPlayerTimeDidUpdate(_ time: Double)
    func audioPlayerDidStall()
    func audioPlayerDidReceiveMetadataUpdate()
}

class AudioPlayer: NSObject, ObservableObject {
    
    // MARK: - Core Components (MINIMAL CBASS)
    private var currentStream: HSTREAM = 0
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioPlayer")
    private let settings = SettingsManager.shared
    
    // MARK: - State Management (UPDATED with track end protection)
    private var lastReportedTime: Double = 0
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
    private var metadataDuration: TimeInterval = 0.0
    
    // Track timing (for reference only - track end detection now handled by NowPlayingManager with server time)
    private var trackStartTime: Date = Date()
    
    // MARK: - Delegation
    weak var delegate: AudioPlayerDelegate?
    
    // MARK: - State Tracking
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 1.0  // Max 1 update per second
    
    // MARK: - Lock Screen Controls (avoid duplicate setup)
    private var lockScreenControlsConfigured = false
    
    // MARK: - CarPlay Audio Route Integration
    private var currentStreamURL: String = ""
    private var audioRouteObserver: NSObjectProtocol?
    
    weak var commandHandler: SlimProtoCommandHandler?

    // MARK: - Initialization
    override init() {
        super.init()
        setupCBass()
        setupAudioRouteMonitoring()
        os_log(.info, log: logger, "AudioPlayer initialized with CBass and CarPlay route monitoring")
    }
    
    // MARK: - Core Setup (MINIMAL CBASS)
    private func setupCBass() {
        // Minimal BASS initialization - keep it simple
        let result = BASS_Init(-1, 44100, 0, nil, nil)
        
        if result == 0 {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS initialization failed: %d", errorCode)
            return
        }
        
        // Basic network configuration for LMS streaming  
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(15000))    // 15s connection timeout
        //BASS_SetConfig(DWORD(BASS_CONFIG_NET_READTIMEOUT), DWORD(8000)) // 8s read timeout for streaming reliability
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(5000))      // 5s network buffer (milliseconds)
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(2000))          // 2s playback buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(25))        // 75% pre-buffer (BASS default) for stable streaming
        
        // Enable stream verification for proper format detection (FLAC headers now handled by server transcoding)
        BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY), 1)                    // Enable file verification
        BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY_NET), 1)               // Enable network stream verification  
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_META), 0)                 // Disable Shoutcast metadata requests
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PLAYLIST), 0)             // Don't process playlist URLs
        // REMOVED: Aggressive DSP settings that may interfere with iOS integration
        // BASS_SetConfig(DWORD(BASS_CONFIG_FLOATDSP), 1)                 // Enable float processing
        // BASS_SetConfig(DWORD(BASS_CONFIG_SRC), 4)                      // High-quality sample rate conversion
        
        // Configure BASS iOS session for CarPlay support
        let iosSessionFlags = BASS_IOS_SESSION_MIX |        // Allow other apps to be heard
                             BASS_IOS_SESSION_BTHFP |       // Allow Bluetooth HFP devices
                             BASS_IOS_SESSION_BTA2DP |      // Allow Bluetooth A2DP devices (CarPlay!)
                             BASS_IOS_SESSION_AIRPLAY       // Allow AirPlay devices (CarPlay wireless!)
        BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(iosSessionFlags))

        // ORIGINAL WORKING CODE: Configure iOS audio session AFTER BASS flags
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            os_log(.info, log: logger, "✅ iOS audio session configured for lock screen")
        } catch {
            os_log(.error, log: logger, "❌ Audio session setup failed: %{public}s", error.localizedDescription)
        }

        os_log(.info, log: logger, "✅ BASS iOS session configured for CarPlay - letting BASS handle AVAudioSession")

        os_log(.info, log: logger, "✅ CBass iOS session configured for CarPlay (A2DP + AirPlay)")
        
        
        os_log(.info, log: logger, "✅ CBass configured - Version: %08X", BASS_GetVersion())
    }
    
    // MARK: - CarPlay Audio Route Integration
    private func setupAudioRouteMonitoring() {
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioRouteChange(notification)
        }
        
        os_log(.info, log: logger, "✅ Audio route monitoring setup for CarPlay integration")
    }
    
    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let routeChangeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else {
            return
        }
        
        let reasonString = routeChangeReasonString(routeChangeReason)
        os_log(.info, log: logger, "🔀 Audio route change: %{public}s (handled by InterruptionManager)", reasonString)
        
        // CarPlay detection and management removed - now handled by AudioManager
        // This maintains general route change logging for debugging purposes
    }
    
    // MARK: - Public BASS Configuration (called by AudioManager)
    func reconfigureBassForCarPlay() {
        os_log(.info, log: logger, "🚗 CarPlay detected - updating BASS session configuration")

        // Update BASS iOS session flags for CarPlay (ensure all flags are set)
        let carPlayFlags = BASS_IOS_SESSION_MIX | BASS_IOS_SESSION_BTHFP |
                          BASS_IOS_SESSION_BTA2DP | BASS_IOS_SESSION_AIRPLAY
        BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(carPlayFlags))

        // Let BASS handle the route change internally - don't stop/free streams
        // This prevents audio gaps and ensures smooth CarPlay handoff
        os_log(.info, log: logger, "🚗 BASS session updated for CarPlay - maintaining current stream")

        // Verify the configuration was applied
        let currentFlags = BASS_GetConfig(DWORD(BASS_CONFIG_IOS_SESSION))
        os_log(.info, log: logger, "🚗 BASS iOS session flags: 0x%08X", currentFlags)
    }
    
    func reconfigureBassForStandardRoute() {
        // Standard route handling - currently no special action needed
        // Could be extended for other route types in the future
        os_log(.info, log: logger, "📱 Standard audio route - no reconfiguration needed")
    }
    
    private func routeChangeReasonString(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "Unknown"
        case .newDeviceAvailable: return "New Device Available"
        case .oldDeviceUnavailable: return "Old Device Unavailable"
        case .categoryChange: return "Category Change"
        case .override: return "Override"
        case .wakeFromSleep: return "Wake From Sleep"
        case .noSuitableRouteForCategory: return "No Suitable Route"
        case .routeConfigurationChange: return "Route Configuration Change"
        @unknown default: return "Unknown Route Change"
        }
    }

    
    // MARK: - Stream Playback (MINIMAL CBASS)
    func playStream(urlString: String) {
        guard !urlString.isEmpty else {
            os_log(.error, log: logger, "Empty URL provided")
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with CBass: %{public}s", urlString)
        
        // Store current URL for CarPlay route recovery
        currentStreamURL = urlString
        
        prepareForNewStream()
        
        // Track timing for reference
        trackStartTime = Date()
        
        // CBass configured for streaming FLAC tolerance (like squeezelite)
        let streamFlags = DWORD(BASS_STREAM_STATUS) |    // enable status info
                         DWORD(BASS_STREAM_AUTOFREE) |   // auto-free when stopped  
                         DWORD(BASS_SAMPLE_FLOAT) |      // use float samples (like squeezelite)
                         DWORD(BASS_STREAM_BLOCK)        // force streaming mode (tolerates incomplete data)
        
        // CBass stream creation with tolerance for incomplete data
        currentStream = BASS_StreamCreateURL(
            urlString,
            0,                           // offset
            streamFlags,                 // streaming tolerance flags
            nil, nil                     // no callbacks
        )
        
        guard currentStream != 0 else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_StreamCreateURL failed: %d for URL: %{public}s", errorCode, urlString)
            
            // Specific handling for error 41 (unsupported format)
            if errorCode == 41 {
                os_log(.error, log: logger, "❌ Error 41: Unsupported audio format - may need plugin support")
            }
            return
        }
        
        setupCallbacks()
        
        let playResult = BASS_ChannelPlay(currentStream, 0)
        if playResult != 0 {
            os_log(.info, log: logger, "✅ CBass playback started - Handle: %d", currentStream)
            
            // Setup lock screen controls once only
            if !lockScreenControlsConfigured {
                setupLockScreenControls()
                lockScreenControlsConfigured = true
            }
            updateNowPlayingInfo(title: "LyrPlay Stream", artist: "Lyrion Music Server")
            
            commandHandler?.handleStreamConnected()
            delegate?.audioPlayerDidStartPlaying()
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_ChannelPlay failed: %d", errorCode)
        }
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        os_log(.info, log: logger, "🎵 Playing %{public}s stream: %{public}s", format, urlString)
        
        // Format-specific configuration could go here
        configureForFormat(format)
        
        // Use the main playStream method
        playStream(urlString: urlString)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        playStream(urlString: urlString)
        
        if startTime > 0 {
            seekToPosition(startTime)
        }
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        playStreamWithFormat(urlString: urlString, format: format)
        
        if startTime > 0 {
            seekToPosition(startTime)
        }
    }
    
    // MARK: - Playback Control (MINIMAL CBASS)
    func play() {
        guard currentStream != 0 else {
            os_log(.info, log: logger, "⚠️ PLAY command with no active stream - stream may have ended or failed")
            return
        }
        
        isIntentionallyPaused = false
        let result = BASS_ChannelPlay(currentStream, 0)
        
        if result != 0 {
            delegate?.audioPlayerDidStartPlaying()
            os_log(.info, log: logger, "▶️ CBass resumed playback")
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ CBass resume failed: %d", errorCode)
        }
    }
    
    func pause() {
        guard currentStream != 0 else { return }
        
        isIntentionallyPaused = true
        let result = BASS_ChannelPause(currentStream)
        
        if result != 0 {
            delegate?.audioPlayerDidPause()
            os_log(.info, log: logger, "⏸️ CBass paused playback")
        }
    }
    
    func stop() {
        isIntentionallyStopped = true
        isIntentionallyPaused = false
        
        if currentStream != 0 {
            BASS_ChannelStop(currentStream)
            currentStream = 0
        }
        
        delegate?.audioPlayerDidStop()
        os_log(.debug, log: logger, "⏹️ CBass stopped playback")
    }
    
    // MARK: - Time and State (MINIMAL CBASS)
    func getCurrentTime() -> Double {
        guard currentStream != 0 else { return 0.0 }
        let bytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
        return BASS_ChannelBytes2Seconds(currentStream, bytes)
    }
    
    func getDuration() -> Double {
        // Prefer metadata duration if available
        if metadataDuration > 0 {
            return metadataDuration
        }
        
        guard currentStream != 0 else { return 0.0 }
        let bytes = BASS_ChannelGetLength(currentStream, DWORD(BASS_POS_BYTE))
        let duration = BASS_ChannelBytes2Seconds(currentStream, bytes)
        return duration.isFinite && duration > 0 ? duration : 0.0
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        return duration > 0 ? Float(currentTime / duration) : 0.0
    }
    
    func getPlayerState() -> String {
        guard currentStream != 0 else { return "No Stream" }
        
        let state = BASS_ChannelIsActive(currentStream)
        switch state {
        case DWORD(BASS_ACTIVE_STOPPED): return "Stopped"
        case DWORD(BASS_ACTIVE_PLAYING): return "Playing"  
        case DWORD(BASS_ACTIVE_PAUSED): return "Paused"
        case DWORD(BASS_ACTIVE_STALLED): return "Buffering"
        default: return "Unknown"
        }
    }
    
    // MARK: - Volume Control (MINIMAL CBASS)
    func setVolume(_ volume: Float) {
        guard currentStream != 0 else { return }
        
        let clampedVolume = max(0.0, min(1.0, volume))
        BASS_ChannelSetAttribute(currentStream, DWORD(BASS_ATTRIB_VOL), clampedVolume)
    }

    func getVolume() -> Float {
        guard currentStream != 0 else { return 1.0 }
        
        var volume: Float = 1.0
        BASS_ChannelGetAttribute(currentStream, DWORD(BASS_ATTRIB_VOL), &volume)
        return volume
    }
    
    // MARK: - Seeking (🎵 NATIVE FLAC SEEKING - KEY BENEFIT!)
    func seekToPosition(_ time: Double) {
        guard currentStream != 0 else { return }
        
        let bytes = BASS_ChannelSeconds2Bytes(currentStream, time)
        let result = BASS_ChannelSetPosition(currentStream, bytes, DWORD(BASS_POS_BYTE))
        
        if result != 0 {
            lastReportedTime = time
            os_log(.info, log: logger, "🔄 CBass NATIVE FLAC SEEK to position: %.2f seconds", time)
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ CBass seek failed: %d", errorCode)
        }
    }
    
    // MARK: - Track End Detection (Server-Time Based)
    func checkIfTrackEnded() -> Bool {
        // Track end detection now handled by NowPlayingManager using server time
        return false
    }
    
    // MARK: - Private Helpers
    private func prepareForNewStream() {
        cleanup() // Clean up any existing stream
        
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        
        // Reset track timing
        trackStartTime = Date()
    }
    
    private func cleanup() {
        if currentStream != 0 {
            BASS_ChannelStop(currentStream)
            BASS_StreamFree(currentStream)
            currentStream = 0
        }
    }
    
    // MARK: - Lock Screen Integration (DISABLED - NowPlayingManager handles this)
    private func setupLockScreenControls() {
        // CRITICAL FIX: AudioPlayer should NOT set up MPRemoteCommandCenter
        // NowPlayingManager already handles lock screen/CarPlay commands via SlimProto
        // This duplicate setup was causing conflicts and CarPlay issues
        
        os_log(.info, log: logger, "⚠️ AudioPlayer MPRemoteCommandCenter setup DISABLED - handled by NowPlayingManager")
    }
    
    private func updateNowPlayingInfo(title: String? = nil, artist: String? = nil) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        
        // Update track info
        if let title = title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }
        if let artist = artist {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        
        // Use SimpleTimeTracker time for consistency with Material web interface
        // Note: Time updates are handled by NowPlayingManager's timer - this just sets initial metadata
        // CRITICAL FIX: Do NOT set PlaybackRate here - NowPlayingManager controls this via SlimProto
        // This was causing conflicts where CBass state overrode SlimProto state
        // nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = getPlayerState() == "Playing" ? 1.0 : 0.0
        
        // Set duration from metadata if available, otherwise use CBass duration  
        if metadataDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = metadataDuration
        } else {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = getDuration()
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // MARK: - BASS Callbacks (MINIMAL)
    private func setupCallbacks() {
        guard currentStream != 0 else { return }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        // Track end detection with data parameter filtering - CRITICAL for SlimProto integration
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_END), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                // CRITICAL: Only treat data=0 as natural track completion (fixes cellular false positives)
                if data == 0 && !player.isIntentionallyPaused && !player.isIntentionallyStopped {
                    // Natural track end detected
                    let currentPos = BASS_ChannelBytes2Seconds(player.currentStream, BASS_ChannelGetPosition(player.currentStream, DWORD(BASS_POS_BYTE)))
                    let totalLength = BASS_ChannelBytes2Seconds(player.currentStream, BASS_ChannelGetLength(player.currentStream, DWORD(BASS_POS_BYTE)))
                    
                    os_log(.info, log: player.logger, "🎵 Track ended naturally (data=0, pos: %.2f, length: %.2f)", currentPos, totalLength)
                    player.delegate?.audioPlayerDidReachEnd()
                } else if data != 0 {
                    // Network/stream issue - ignore (fixes cellular FLAC premature skipping)
                    os_log(.info, log: player.logger, "⚠️ BASS_SYNC_END data=%d (ignoring - not natural track end)", data)
                }
            }
        }, selfPtr)
        
        // Stream stall detection
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_STALL), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                player.delegate?.audioPlayerDidStall()
            }
        }, selfPtr)
        
        // Position updates for UI
        let oneSecondBytes = BASS_ChannelSeconds2Bytes(currentStream, 1.0)
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_POS), oneSecondBytes, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            let currentTime = player.getCurrentTime()
            DispatchQueue.main.async {
                player.delegate?.audioPlayerTimeDidUpdate(currentTime)
            }
        }, selfPtr)
    }
    
    // MARK: - Format Configuration (USER-CONFIGURABLE CBass BUFFERS)  
    private func configureForFormat(_ format: String) {
        switch format.uppercased() {
        case "FLAC":
            // Use user-configurable CBass buffer settings
            let flacBufferMS = settings.flacBufferSeconds * 1000     // Playback buffer in milliseconds
            let networkBufferMS = settings.networkBufferKB * 1000   // Network buffer in milliseconds (using KB setting as seconds)
            
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(flacBufferMS))        // User FLAC buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(networkBufferMS))   // Network buffer in milliseconds
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(10))       // 75% pre-buffer (BASS default)
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))    // Slow updates for stability
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(120000))  // 2min timeout
            
            os_log(.info, log: logger, "🎵 FLAC configured with user settings: %ds buffer, %ds network", settings.flacBufferSeconds, settings.networkBufferKB)
            
        case "AAC", "MP3", "OGG":
            // Compressed formats that work well - smaller buffer for responsiveness
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))         // 1.5s buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(50000))     // 50s network buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(15))       // 15% prebuf = 7.5s startup (faster than default)
            
            
            os_log(.info, log: logger, "🎵 Compressed format with reliable buffering: %{public}s (1.5s playback, 50s network)", format)
            
        case "OPUS":
            // Opus - larger network buffer for reliability  
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(5000))         // 5s playback buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(120000))   // 120s network buffer (~4MB memory)
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(10))       // 10% prebuf = 12s startup (same as FLAC)
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(200))    // Moderate update rate
            
            
            os_log(.info, log: logger, "🎵 Opus configured with reliable buffering: 5s playback, 120s network")
            
        default:
            // Use defaults from setupCBass() - 2s buffer, 64KB network
            os_log(.info, log: logger, "🎵 Using default CBass configuration for format: %{public}s", format)
            break
        }
    }
    
    // MARK: - Metadata
    func setMetadataDuration(_ duration: TimeInterval) {
        // CRITICAL FIX: Don't overwrite existing duration with 0.0
        if duration > 0.0 {
            // Only log if duration actually changes to avoid spam
            if abs(metadataDuration - duration) > 1.0 {
                os_log(.info, log: logger, "🎵 Metadata duration updated: %.0f seconds", duration)
            }
            metadataDuration = duration
        } else if metadataDuration > 0.0 {
            // Keep existing duration, don't overwrite with 0.0
            os_log(.debug, log: logger, "🎵 Preserving existing duration %.0f seconds (ignoring 0.0)", metadataDuration)
        }
    }
    
    // MARK: - Cleanup
    deinit {
        cleanup()
        
        // Clean up audio route observer
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        BASS_Free()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}
