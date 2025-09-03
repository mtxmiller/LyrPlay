// File: AudioPlayer.swift
// Updated to use CBass for minimal native FLAC support
import Foundation
import Bass
import MediaPlayer
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
    
    // CRITICAL: Track end detection protection from REFERENCE
    private var trackEndDetectionEnabled = false
    private var trackStartTime: Date = Date()
    private let minimumTrackDuration: TimeInterval = 5.0 // Minimum 5 seconds before allowing track end detection
    
    // MARK: - Delegation
    weak var delegate: AudioPlayerDelegate?
    
    // MARK: - State Tracking
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 1.0  // Max 1 update per second
    
    // MARK: - Lock Screen Controls (avoid duplicate setup)
    private var lockScreenControlsConfigured = false
    
    weak var commandHandler: SlimProtoCommandHandler?

    // MARK: - Initialization
    override init() {
        super.init()
        setupCBass()
        os_log(.info, log: logger, "AudioPlayer initialized with CBass")
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
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(15000))    // 15s timeout
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(65536))     // 64KB network buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(2000))          // 2s playback buffer
        
        // Configure iOS audio session for background and lock screen
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true)
            os_log(.info, log: logger, "✅ iOS audio session configured for lock screen")
        } catch {
            os_log(.error, log: logger, "❌ Audio session setup failed: %{public}s", error.localizedDescription)
        }
        
        os_log(.info, log: logger, "✅ CBass configured - Version: %08X", BASS_GetVersion())
    }

    
    private func bufferSizeToSeconds(_ bufferSizeBytes: Int) -> TimeInterval {
        // FLAC-aware calculation based on actual bitrates
        let estimatedBitrate: Double
        
        // Use higher bitrate estimate since FLAC is prioritized
        if bufferSizeBytes >= 2_097_152 { // 2MB+
            estimatedBitrate = 1_200_000 // 1.2 Mbps - high quality FLAC
        } else if bufferSizeBytes >= 1_048_576 { // 1MB+
            estimatedBitrate = 900_000 // 900 kbps - mixed FLAC/AAC
        } else {
            estimatedBitrate = 600_000 // 600 kbps - mostly compressed
        }
        
        let bytesPerSecond = estimatedBitrate / 8.0
        let bufferSeconds = Double(bufferSizeBytes) / bytesPerSecond
        
        // FLAC needs longer buffer times, minimum 2 seconds
        return max(2.0, min(30.0, bufferSeconds))
    }
    
    // MARK: - Stream Playback (MINIMAL CBASS)
    func playStream(urlString: String) {
        guard !urlString.isEmpty else {
            os_log(.error, log: logger, "Empty URL provided")
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with CBass: %{public}s", urlString)
        
        prepareForNewStream()
        
        // Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // MINIMAL CBASS: Create and play stream
        currentStream = BASS_StreamCreateURL(
            urlString,
            0,                           // offset
            DWORD(BASS_STREAM_STATUS) |  // enable status info
            DWORD(BASS_STREAM_AUTOFREE), // auto-free when stopped
            nil, nil                     // no callbacks yet
        )
        
        guard currentStream != 0 else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_StreamCreateURL failed: %d", errorCode)
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
        guard currentStream != 0 else { return }
        
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
    
    // MARK: - Track End Detection (MINIMAL CBASS)
    func checkIfTrackEnded() -> Bool {
        // BASS handles track end detection via callbacks
        return false
    }
    
    // MARK: - Private Helpers
    private func prepareForNewStream() {
        cleanup() // Clean up any existing stream
        
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        
        // CRITICAL: Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
    }
    
    private func cleanup() {
        if currentStream != 0 {
            BASS_ChannelStop(currentStream)
            BASS_StreamFree(currentStream)
            currentStream = 0
        }
    }
    
    // MARK: - Lock Screen Integration
    private func setupLockScreenControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play command - maps to existing play() method
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            self?.play()
            return .success
        }
        
        // Pause command - maps to existing pause() method  
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            self?.pause()
            return .success
        }
        
        // Disable commands we don't need (server handles seeking)
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        
        os_log(.info, log: logger, "✅ Lock screen controls configured")
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
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = getPlayerState() == "Playing" ? 1.0 : 0.0
        
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
        
        // Track end detection - CRITICAL for SlimProto integration
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_END), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                if player.trackEndDetectionEnabled && !player.isIntentionallyPaused && !player.isIntentionallyStopped {
                    os_log(.info, log: player.logger, "🎵 Track ended naturally")
                    player.commandHandler?.notifyTrackEnded()
                    player.delegate?.audioPlayerDidReachEnd()
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
    
    // MARK: - Format Configuration (OPTIMIZED FOR FLAC)  
    private func configureForFormat(_ format: String) {
        switch format.uppercased() {
        case "FLAC":
            // OPTIMIZED: Use settings from successful CBass implementation
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(20000))        // 20s buffer for stability
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(524288))   // 512KB network chunks  
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(15))       // 15% pre-buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(250))    // Slow updates for stability
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(120000))  // 2min timeout
            os_log(.info, log: logger, "🎵 FLAC optimized: 20s buffer, 512KB network, stable config")
            
        case "AAC", "MP3":
            // Compressed formats - smaller buffer for responsiveness
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))         // 1.5s buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(65536))    // 64KB network
            os_log(.info, log: logger, "🎵 Compressed format optimized")
            
        default:
            // Use defaults from setupCBass()
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
        BASS_Free()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}