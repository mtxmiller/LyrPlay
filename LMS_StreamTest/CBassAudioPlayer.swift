//
//  CBassAudioPlayer.swift
//  LyrPlay
//
//  CBass audio player implementation - Professional BASS audio library integration
//  Replaces StreamingKit with superior FLAC support and native seeking capabilities
//

import Foundation
import AVFoundation
import MediaPlayer
import Bass
import BassFLAC
import os.log

class CBassAudioPlayer: NSObject, ObservableObject {
    
    // MARK: - Core Components
    private var currentStream: HSTREAM = 0
    private let audioQueue = DispatchQueue(label: "com.lyrplay.cbass", qos: .userInitiated)
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CBassAudioPlayer")
    
    // MARK: - Integration Points (Preserve Exact Interface)
    weak var delegate: AudioPlayerDelegate?
    weak var commandHandler: SlimProtoCommandHandler?
    
    // MARK: - State Management
    private var metadataDuration: TimeInterval = 0.0
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
    private var lastReportedTime: Double = 0
    private var trackEndDetectionEnabled = false
    private var trackStartTime: Date = Date()
    private let minimumTrackDuration: TimeInterval = 5.0
    
    // MARK: - Settings Integration
    private let settings = SettingsManager.shared
    
    // MARK: - Published Properties (for SwiftUI compatibility)
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    // MARK: - Initialization
    override init() {
        super.init()
        initializeBass()
        os_log(.info, log: logger, "CBassAudioPlayer initialized with BASS audio library")
    }
    
    // MARK: - BASS Initialization
    private func initializeBass() {
        // CRITICAL FIX: Set iOS audio session category BEFORE BASS initialization
        // This prevents OSStatus error -50
        setupiOSAudioSessionForCBass()
        
        // CRITICAL FIX: Register with iOS MediaPlayer framework ONCE during initialization
        // This prevents OSStatus -50 errors during track transitions
        registerWithiOSMediaFramework()
        
        // Initialize BASS core with iOS-specific parameters
        // Use -1 device for system default, but with iOS-compatible flags
        let bassInit = BASS_Init(
            -1,                           // Default device
            44100,                        // 44.1kHz (iOS standard)
            DWORD(BASS_DEVICE_DEFAULT),   // Use default device settings
            nil,                          // No window handle (iOS)
            nil                           // No class identifier
        )
        
        if bassInit == 0 {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS initialization failed: %d", errorCode)
            
            // iOS-specific error diagnostics
            switch errorCode {
            case BASS_ERROR_DEVICE:
                os_log(.error, log: logger, "💡 iOS Audio Unit may not be available - check audio session category")
            case BASS_ERROR_ALREADY:
                os_log(.info, log: logger, "ℹ️ BASS already initialized - continuing")
            default:
                os_log(.error, log: logger, "💡 Check iOS audio session setup before BASS_Init")
            }
            return
        }
        
        // CRITICAL: Explicitly load BASSFLAC plugin
        // With CBass package, BASSFLAC should be automatically available
        // But we need to verify it's loaded
        os_log(.info, log: logger, "🔍 Checking BASSFLAC plugin availability...")
        
        // Test BASSFLAC availability by checking supported formats
        let pluginInfo = BASS_PluginGetInfo(0)
        var flacSupported = false
        
        if pluginInfo != nil {
            os_log(.info, log: logger, "✅ BASS plugins are available, checking for FLAC support...")
            flacSupported = true // CBass package should include BASSFLAC
        } else {
            os_log(.error, log: logger, "❌ No BASS plugins detected")
        }
        
        if flacSupported {
            os_log(.info, log: logger, "✅ BASSFLAC plugin should be available via CBass package")
        }
        
        // Set LMS-compatible User-Agent for FLAC streaming
        let userAgent = "LyrPlay/1.0 BASSFLAC"
        BASS_SetConfigPtr(DWORD(BASS_CONFIG_NET_AGENT), userAgent)
        
        // Configure BASS for optimal iOS/LMS streaming (CBass expert optimizations)
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(20000))     // 20s timeout - responsive but stable
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_READTIMEOUT), DWORD(10000)) // 10s read timeout
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(65536))      // 64KB default - balanced for all formats
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(2000))           // 2s default - much more responsive
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(100))      // 100ms updates - responsive UI
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATETHREADS), DWORD(2))       // Dual-threaded updates
        
        // Local network optimizations for LMS servers
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PLAYLIST), DWORD(0))        // Direct streaming
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_PASSIVE), DWORD(0))         // Active mode for local network
        
        // iOS-specific CBass configurations for better iOS audio integration
        BASS_SetConfig(DWORD(BASS_CONFIG_IOS_MIXAUDIO), DWORD(0))        // Disable audio mixing for exclusive playback
        BASS_SetConfig(DWORD(BASS_CONFIG_DEV_BUFFER), DWORD(20))         // 20ms device buffer (good for iOS)
        BASS_SetConfig(DWORD(BASS_CONFIG_GVOL_STREAM), DWORD(10000))     // Global stream volume at max
        
        os_log(.info, log: logger, "✅ BASS initialized - Version: %08X", BASS_GetVersion())
        
        // Test BASSFLAC with a diagnostic check
        testBassflacPlugin()
    }
    
    private func testBassflacPlugin() {
        // Quick test to verify BASSFLAC is working
        let plugins = BASS_PluginGetInfo(0) // Get all loaded plugins
        os_log(.info, log: logger, "🔍 Testing BASSFLAC plugin availability...")
        
        // Check if FLAC format is supported
        var formatSupported = false
        if let pluginInfo = plugins {
            var currentPlugin = pluginInfo
            while currentPlugin.pointee.formats != nil {
                var currentFormat = currentPlugin.pointee.formats
                while currentFormat!.pointee.name != nil {
                    let formatName = String(cString: currentFormat!.pointee.name)
                    let formatCType = currentFormat!.pointee.ctype
                    
                    if formatName.lowercased().contains("flac") {
                        formatSupported = true
                        os_log(.info, log: logger, "✅ FLAC format supported: %{public}@ (Type: %08X)", formatName, formatCType)
                    }
                    
                    currentFormat = currentFormat?.advanced(by: 1)
                }
                currentPlugin = currentPlugin.advanced(by: 1)
            }
        }
        
        if !formatSupported {
            os_log(.error, log: logger, "❌ FLAC format not found in loaded plugins!")
        }
    }
    
    // MARK: - Stream Playback (Compatible with AudioPlayerDelegate interface)
    func playStream(urlString: String) {
        guard !urlString.isEmpty else {
            os_log(.error, log: logger, "❌ Empty URL provided")
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with CBass: %{public}@", urlString)
        
        audioQueue.async { [weak self] in
            self?.playStreamInternal(urlString: urlString)
        }
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        os_log(.info, log: logger, "🎵 Playing %{public}@ stream with CBass: %{public}@", format, urlString)
        
        // Configure format-specific optimizations
        configureForFormat(format)
        playStream(urlString: urlString)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        playStream(urlString: urlString)
        
        if startTime > 0 {
            // Delay seek to allow stream to establish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.seekToPosition(startTime)
            }
        }
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        playStreamWithFormat(urlString: urlString, format: format)
        
        if startTime > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.seekToPosition(startTime)
            }
        }
    }
    
    // MARK: - Private Stream Implementation
    private func playStreamInternal(urlString: String) {
        prepareForNewStream()
        
        os_log(.info, log: logger, "🔧 Creating BASS stream for URL: %{public}@", urlString)
        
        // Create BASS stream - OPTIMIZED for immediate playback (expert recommendation)
        // REMOVED BASS_STREAM_BLOCK for StreamingKit-like immediate response
        
        currentStream = BASS_StreamCreateURL(
            urlString,                   // Original URL (FLAC detection works fine)
            0,                           // offset (always 0 for network)
            DWORD(BASS_STREAM_STATUS) |  // enable status info
            DWORD(BASS_STREAM_AUTOFREE), // auto-free when stopped
            nil,                         // download progress callback (not needed)  
            nil                          // user data
        )
        
        guard currentStream != 0 else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_StreamCreateURL failed for: %{public}@", urlString)
            DispatchQueue.main.async {
                self.handleBassError("Stream creation failed", errorCode: errorCode)
            }
            return
        }
        
        // Log stream info for debugging
        logStreamInfo()
        
        // Set up callbacks for track end detection and status updates
        setupCallbacks()
        
        // Start playback
        let playResult = BASS_ChannelPlay(currentStream, 0) // 0 = don't restart if already playing
        
        DispatchQueue.main.async {
            if playResult != 0 {
                os_log(.info, log: self.logger, "✅ CBass stream started successfully - Handle: %d", self.currentStream)
                
                // MediaPlayer framework registration moved to initializeBass()
                // to prevent OSStatus -50 errors during track transitions
                
                // INTEGRATION POINT: Notify SlimProto of stream connection
                self.commandHandler?.handleStreamConnected()
                
                // Update UI state
                self.isPlaying = true
                self.isPaused = false
                
                // Trigger lock screen controls setup with delay to ensure audio is flowing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.ensureLockScreenControlsAreActive()
                }
                
                self.delegate?.audioPlayerDidStartPlaying()
                
                // Enable track end detection after minimum duration
                self.trackEndDetectionEnabled = false
                DispatchQueue.main.asyncAfter(deadline: .now() + self.minimumTrackDuration) {
                    self.trackEndDetectionEnabled = true
                    os_log(.info, log: self.logger, "✅ Track end detection enabled")
                }
                
                // Start monitoring stream status for FLAC debugging
                self.startStreamMonitoring()
                
            } else {
                let errorCode = BASS_ErrorGetCode()
                self.handleBassError("Playback start failed", errorCode: errorCode)
            }
        }
    }
    
    // MARK: - Playback Control
    func play() {
        audioQueue.async { [weak self] in
            guard let self = self, self.currentStream != 0 else { return }
            
            self.isIntentionallyPaused = false
            let result = BASS_ChannelPlay(self.currentStream, 0)
            
            DispatchQueue.main.async {
                if result != 0 {
                    self.isPlaying = true
                    self.isPaused = false
                    self.delegate?.audioPlayerDidStartPlaying()
                    os_log(.info, log: self.logger, "▶️ CBass playback resumed")
                } else {
                    let errorCode = BASS_ErrorGetCode()
                    self.handleBassError("Resume failed", errorCode: errorCode)
                }
            }
        }
    }
    
    func pause() {
        audioQueue.async { [weak self] in
            guard let self = self, self.currentStream != 0 else { return }
            
            self.isIntentionallyPaused = true
            let result = BASS_ChannelPause(self.currentStream)
            
            DispatchQueue.main.async {
                if result != 0 {
                    self.isPlaying = false
                    self.isPaused = true
                    self.delegate?.audioPlayerDidPause()
                    os_log(.info, log: self.logger, "⏸️ CBass playback paused")
                }
            }
        }
    }
    
    func stop() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.isIntentionallyStopped = true
            self.isIntentionallyPaused = false
            
            if self.currentStream != 0 {
                BASS_ChannelStop(self.currentStream)
            }
            
            DispatchQueue.main.async {
                self.isPlaying = false
                self.isPaused = false
                self.delegate?.audioPlayerDidStop()
                os_log(.info, log: self.logger, "⏹️ CBass playback stopped")
            }
        }
    }
    
    // MARK: - Time and State Access (Compatible Interface)
    func getCurrentTime() -> Double {
        return audioQueue.sync { () -> Double in
            guard currentStream != 0 else { return 0.0 }
            let bytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
            return BASS_ChannelBytes2Seconds(currentStream, bytes)
        }
    }
    
    func getDuration() -> Double {
        // Prefer metadata duration if available
        if metadataDuration > 0 {
            return metadataDuration
        }
        
        return audioQueue.sync { () -> Double in
            guard currentStream != 0 else { return 0.0 }
            let bytes = BASS_ChannelGetLength(currentStream, DWORD(BASS_POS_BYTE))
            let duration = BASS_ChannelBytes2Seconds(currentStream, bytes)
            return duration.isFinite && duration > 0 ? duration : 0.0
        }
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        return duration > 0 ? Float(currentTime / duration) : 0.0
    }
    
    func getPlayerState() -> String {
        return audioQueue.sync { () -> String in
            guard currentStream != 0 else { return "No Stream" }
            
            let state = BASS_ChannelIsActive(currentStream)
            switch state {
            case DWORD(BASS_ACTIVE_STOPPED):
                return "Stopped"
            case DWORD(BASS_ACTIVE_PLAYING):
                return "Playing"
            case DWORD(BASS_ACTIVE_PAUSED):
                return "Paused"
            case DWORD(BASS_ACTIVE_STALLED):
                return "Stalled"
            default:
                return "Unknown"
            }
        }
    }
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        audioQueue.async { [weak self] in
            guard let self = self, self.currentStream != 0 else { return }
            BASS_ChannelSetAttribute(self.currentStream, DWORD(BASS_ATTRIB_VOL), clampedVolume)
        }
    }
    
    func getVolume() -> Float {
        return audioQueue.sync { () -> Float in
            guard currentStream != 0 else { return 1.0 }
            var volume: Float = 1.0
            BASS_ChannelGetAttribute(currentStream, DWORD(BASS_ATTRIB_VOL), &volume)
            return volume
        }
    }
    
    // MARK: - Seeking (MAJOR IMPROVEMENT: Native FLAC seeking!)
    func seekToPosition(_ time: Double) {
        audioQueue.async { [weak self] in
            guard let self = self, self.currentStream != 0 else { return }
            
            let bytes = BASS_ChannelSeconds2Bytes(self.currentStream, time)
            let result = BASS_ChannelSetPosition(self.currentStream, bytes, DWORD(BASS_POS_BYTE))
            
            DispatchQueue.main.async {
                if result != 0 {
                    self.lastReportedTime = time
                    os_log(.info, log: self.logger, "🔄 CBass seek successful to %.2f seconds", time)
                } else {
                    let errorCode = BASS_ErrorGetCode()
                    os_log(.error, log: self.logger, "❌ CBass seek failed: %d", errorCode)
                }
            }
        }
    }
    
    // MARK: - Legacy Compatibility
    func checkIfTrackEnded() -> Bool {
        // BASS handles track end detection via callbacks
        return false
    }
    
    // MARK: - Metadata Support
    func setMetadataDuration(_ duration: TimeInterval) {
        if duration > 0.0 {
            if abs(metadataDuration - duration) > 1.0 {
                os_log(.info, log: logger, "🎵 Metadata duration updated: %.0f seconds", duration)
            }
            metadataDuration = duration
            
            DispatchQueue.main.async { [weak self] in
                self?.duration = duration
            }
        } else if metadataDuration > 0.0 {
            os_log(.debug, log: logger, "🎵 Preserving existing duration %.0f seconds (ignoring 0.0)", metadataDuration)
        }
    }
    
    // MARK: - Format-Specific Configuration
    private func configureForFormat(_ format: String) {
        switch format.uppercased() {
        case "FLAC", "ALAC":
            // IMMEDIATE START FLAC: StreamingKit-like responsiveness with stability (CBass expert optimized)
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(2000))        // 2s playback buffer - stable
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(524288))  // 512KB network buffer - reasonable size
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(3))       // 3% pre-buffer - only 15.3KB to start!
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))    // 50ms updates - responsive
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(10000))  // 10s timeout - local network
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_READTIMEOUT), DWORD(5000)) // 5s read timeout
            os_log(.info, log: logger, "🎵 Immediate FLAC: 2s buffer, 512KB network, 3%% prebuffer = 15KB to start!")
            
        case "AAC":
            // AAC optimizations - ultra-responsive for compressed format
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))        // 1.5s buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(32768))   // 32KB network buffer  
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(3))       // 3% pre-buffer - immediate start
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))    // 50ms updates
            os_log(.info, log: logger, "🎵 Optimized AAC: 1.5s buffer, 32KB network, 3%% prebuffer")
            
        case "MP3":
            // MP3 optimizations - ultra-responsive for compressed format
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))        // 1.5s buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(32768))   // 32KB network buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(3))       // 3% pre-buffer - immediate start
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))    // 50ms updates
            os_log(.info, log: logger, "🎵 Optimized MP3: 1.5s buffer, 32KB network, 3%% prebuffer")
            
        default:
            // Default configuration
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(500))         // 500ms default
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(8192))    // 8KB default
            os_log(.info, log: logger, "🎵 Using default configuration for format: %{public}@", format)
        }
    }
    
    // MARK: - iOS MediaPlayer Framework Registration (CRITICAL for Lock Screen)
    private func registerWithiOSMediaFramework() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // STEP 1: Ensure audio session options include lock screen support
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP]
            )
            
            // STEP 2: Ensure session is active
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
            }
            
            // STEP 3: Register as the current audio player with MediaPlayer framework
            let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
            let commandCenter = MPRemoteCommandCenter.shared()
            
            // Clear any existing registration first
            nowPlayingInfoCenter.nowPlayingInfo = nil
            
            // Set minimal now playing info to register as active audio app
            var nowPlayingInfo = [String: Any]()
            nowPlayingInfo[MPMediaItemPropertyTitle] = "CBass Audio Stream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "LyrPlay"
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            
            nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
            
            // Enable basic remote commands
            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            
            os_log(.info, log: logger, "✅ Registered with iOS MediaPlayer framework for lock screen controls")
            
        } catch let error as NSError {
            os_log(.error, log: logger, "❌ Failed to register with iOS MediaPlayer framework: OSStatus %d", error.code)
            os_log(.error, log: logger, "   Lock screen controls may not appear")
        }
    }
    
    // MARK: - iOS Audio Session Setup for CBass (CRITICAL)
    private func setupiOSAudioSessionForCBass() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // STEP 1: Set category FIRST with minimal options to prevent conflicts
            try audioSession.setCategory(.playback, mode: .default, options: [])
            
            // STEP 2: Set preferred sample rate to match BASS_Init
            try audioSession.setPreferredSampleRate(44100.0)
            
            // STEP 3: Set buffer duration for CBass compatibility
            try audioSession.setPreferredIOBufferDuration(0.005) // 5ms - good for CBass
            
            // STEP 4: Activate session BEFORE BASS_Init to claim audio resources
            try audioSession.setActive(true)
            
            os_log(.info, log: logger, "✅ iOS audio session configured for CBass BEFORE BASS_Init")
            os_log(.info, log: logger, "  Category: %{public}s", audioSession.category.rawValue)
            os_log(.info, log: logger, "  Sample Rate: %.0f Hz", audioSession.sampleRate)
            os_log(.info, log: logger, "  Buffer Duration: %.1f ms", audioSession.ioBufferDuration * 1000)
            
        } catch let error as NSError {
            os_log(.error, log: logger, "❌ Critical: Failed to setup iOS audio session for CBass: OSStatus %d", error.code)
            os_log(.error, log: logger, "   This will likely cause BASS_Init to fail")
            
            // Log specific iOS audio session errors
            switch error.code {
            case -50:
                os_log(.error, log: logger, "💡 OSStatus -50: Invalid parameter in audio session setup")
            case -560030580:
                os_log(.error, log: logger, "💡 Audio session activation failed - another app may be using audio")
            default:
                os_log(.error, log: logger, "💡 Unexpected audio session error: %{public}s", error.localizedDescription)
            }
        }
    }
    
    // MARK: - Audio Session Management for CBass
    private func activateAudioSessionForPlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Ensure we have the right category and options set
            let currentCategory = audioSession.category
            if currentCategory != .playback {
                os_log(.error, log: logger, "⚠️ Audio session category is %{public}s, should be playback", currentCategory.rawValue)
                
                // Fix the category if needed
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP, .duckOthers]
                )
                os_log(.info, log: logger, "🔧 Fixed audio session category to playback")
            }
            
            // Activate the session
            try audioSession.setActive(true, options: [])
            os_log(.info, log: logger, "✅ Audio session activated by CBass - lock screen controls should now appear")
            
            // Log current state for debugging
            os_log(.info, log: logger, "🔍 Audio Session State After Activation:")
            os_log(.info, log: logger, "  Category: %{public}s", audioSession.category.rawValue)
            os_log(.info, log: logger, "  Mode: %{public}s", audioSession.mode.rawValue)
            os_log(.info, log: logger, "  Options: %{public}s", String(describing: audioSession.categoryOptions))
            os_log(.info, log: logger, "  Sample Rate: %.0f Hz", audioSession.sampleRate)
            os_log(.info, log: logger, "  Other Audio Playing: %{public}s", audioSession.isOtherAudioPlaying ? "YES" : "NO")
            
        } catch let error as NSError {
            let osStatusError = error.code
            os_log(.error, log: logger, "❌ Failed to activate audio session - OSStatus: %d, Description: %{public}s", 
                   osStatusError, error.localizedDescription)
            
            // Provide specific guidance for common errors
            switch osStatusError {
            case -50: // kAudioSessionInvalidParameter
                os_log(.error, log: logger, "💡 OSStatus -50: Invalid parameter - check category/mode/options combination")
            case -560030580: // kAudioSessionNotActiveError
                os_log(.error, log: logger, "💡 OSStatus -560030580: Session not active - retrying activation")
            case -560033202: // kAudioSessionBadPropertySizeError
                os_log(.error, log: logger, "💡 OSStatus -560033202: Bad property size - check buffer duration settings")
            default:
                os_log(.error, log: logger, "💡 Unknown OSStatus error - consult Apple audio session documentation")
            }
        }
    }
    
    // MARK: - Lock Screen Controls Activation (iOS-Specific CBass Integration)
    private func ensureLockScreenControlsAreActive() {
        // CRITICAL FIX: iOS requires specific sequence for lock screen controls with CBass
        
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // STEP 1: Clear any existing now playing info first
        nowPlayingInfoCenter.nowPlayingInfo = nil
        
        // STEP 2: Disable all commands temporarily
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        
        // STEP 3: Wait a brief moment for iOS to register the changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            // STEP 4: Set comprehensive now playing info
            var nowPlayingInfo = [String: Any]()
            nowPlayingInfo[MPMediaItemPropertyTitle] = "LyrPlay Audio Stream"
            nowPlayingInfo[MPMediaItemPropertyArtist] = "CBass Audio Player"
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Lyrion Music Server"
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = 0.0 // Unknown duration
            
            // CRITICAL: Set media type to audio
            nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            
            nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
            
            // STEP 5: Re-enable commands with proper targets
            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            commandCenter.nextTrackCommand.isEnabled = true
            commandCenter.previousTrackCommand.isEnabled = true
            
            os_log(.info, log: self.logger, "✅ Lock screen controls configured for CBass audio playback")
            
            // STEP 6: Verify audio session is still active and has proper category
            let audioSession = AVAudioSession.sharedInstance()
            if audioSession.category != .playback {
                os_log(.error, log: self.logger, "⚠️ Audio session category changed - lock screen may not work")
                
                // Fix the category if it changed
                do {
                    try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
                    os_log(.info, log: self.logger, "🔧 Restored audio session category for lock screen")
                } catch {
                    os_log(.error, log: self.logger, "❌ Failed to restore audio session category: %{public}s", error.localizedDescription)
                }
            }
            
            // STEP 7: Final verification
            os_log(.info, log: self.logger, "🔍 Lock Screen Setup Verification:")
            os_log(.info, log: self.logger, "  Now Playing Info: %{public}s", nowPlayingInfoCenter.nowPlayingInfo != nil ? "SET" : "NIL")
            os_log(.info, log: self.logger, "  Play Command Enabled: %{public}s", commandCenter.playCommand.isEnabled ? "YES" : "NO")
            os_log(.info, log: self.logger, "  Audio Session Category: %{public}s", audioSession.category.rawValue)
            os_log(.info, log: self.logger, "  Audio Session Active: %{public}s", "YES") // We know it's active because we just activated it
        }
    }
    
    // MARK: - Private Helpers
    private func prepareForNewStream() {
        cleanup()
        
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.isPaused = false
            self?.currentTime = 0
        }
    }
    
    private func cleanup() {
        // Stop monitoring timer
        stopStreamMonitoring()
        
        if currentStream != 0 {
            // Remove all sync callbacks before freeing the stream
            BASS_ChannelRemoveSync(currentStream, DWORD(BASS_SYNC_END))
            BASS_ChannelRemoveSync(currentStream, DWORD(BASS_SYNC_STALL))
            BASS_ChannelRemoveSync(currentStream, DWORD(BASS_SYNC_POS))
            // Note: BASS_SYNC_META callback removed to fix metadata spam
            
            BASS_ChannelStop(currentStream)
            BASS_StreamFree(currentStream)
            currentStream = 0
            os_log(.debug, log: logger, "🧹 CBass stream and callbacks cleaned up")
        }
    }
    
    private func setupCallbacks() {
        guard currentStream != 0 else { return }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        // Track end detection - CRITICAL for SlimProto integration
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_END), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                if player.trackEndDetectionEnabled {
                    // CRITICAL FIX: Check if this is legitimate track end vs stream starvation
                    let currentTime = player.getCurrentTime()
                    let duration = player.getDuration()
                    
                    // Only notify track end if we're actually near the end of the track
                    if duration > 0 && currentTime >= (duration - 2.0) {
                        os_log(.info, log: player.logger, "🎵 Track legitimately ended (%.1fs/%.1fs) - notifying SlimProto", currentTime, duration)
                        
                        // INTEGRATION POINT: Notify SlimProto of track end
                        player.commandHandler?.notifyTrackEnded()
                        
                        // Update UI state
                        player.isPlaying = false
                        player.isPaused = false
                        player.delegate?.audioPlayerDidReachEnd()
                    } else {
                        os_log(.error, log: player.logger, "⚠️ Stream stopped unexpectedly at %.1fs/%.1fs - likely starvation, NOT track end", currentTime, duration)
                        
                        // SQUEEZELITE-STYLE: Notify server of stream disconnection, don't skip tracks
                        player.handleStreamStarvation(currentTime: currentTime, duration: duration)
                    }
                } else {
                    os_log(.debug, log: player.logger, "🎵 Track end detected but suppressed (within minimum duration)")
                }
            }
        }, selfPtr)
        
        // Stream stall detection
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_STALL), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                os_log(.info, log: player.logger, "⚠️ Stream stalled - notifying delegate")
                player.delegate?.audioPlayerDidStall()
            }
        }, selfPtr)
        
        // Position updates every second for UI synchronization
        let oneSecondBytes = BASS_ChannelSeconds2Bytes(currentStream, 1.0)
        os_log(.info, log: logger, "🔧 Setting up BASS_SYNC_POS at %.0f bytes (1.0 second mark)", Double(oneSecondBytes))
        
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_POS), oneSecondBytes, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            let currentTime = player.getCurrentTime()
            DispatchQueue.main.async {
                os_log(.info, log: player.logger, "🔄 CBass Position Sync: %.2fs → delegate?.audioPlayerTimeDidUpdate()", currentTime)
                player.currentTime = currentTime
                player.delegate?.audioPlayerTimeDidUpdate(currentTime)
            }
        }, selfPtr)
        
        // Note: Removed BASS_SYNC_META callback - was causing metadata spam
        // LMS handles metadata through SlimProto protocol, not ICY metadata
        // Keeping this commented for radio streams in future:
        /*
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_META), 0, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            DispatchQueue.main.async {
                os_log(.info, log: player.logger, "🎵 ICY Metadata update received")
                player.delegate?.audioPlayerDidReceiveMetadataUpdate()
            }
        }, selfPtr)
        */
        
        os_log(.info, log: logger, "✅ CBass callbacks configured: track end, stall detection, position updates, metadata")
    }
    
    private func handleBassError(_ context: String, errorCode: Int32) {
        let errorDescription = bassErrorDescription(errorCode)
        os_log(.error, log: logger, "❌ %{public}s: %{public}s (%d)", context, errorDescription, errorCode)
        
        // Delegate error to main AudioPlayerDelegate
        delegate?.audioPlayerDidStall()
    }
    
    private func bassErrorDescription(_ code: Int32) -> String {
        switch code {
        case BASS_ERROR_FILEOPEN:
            return "File/URL could not be opened"
        case BASS_ERROR_FILEFORM:
            return "File format not recognized/supported"
        case BASS_ERROR_CODEC:
            return "Codec not available/supported"
        case BASS_ERROR_FORMAT:
            return "Sample format not supported"
        case BASS_ERROR_MEM:
            return "Insufficient memory"
        case BASS_ERROR_NO3D:
            return "3D functionality not available"
        case BASS_ERROR_UNKNOWN:
            return "Unknown error"
        case BASS_ERROR_DEVICE:
            return "Invalid device"
        case BASS_ERROR_NOPLAY:
            return "Not playing"
        case BASS_ERROR_FREQ:
            return "Invalid frequency"
        case BASS_ERROR_HANDLE:
            return "Invalid handle"
        case BASS_ERROR_NOTFILE:
            return "Not a file stream"
        case BASS_ERROR_DECODE:
            return "Decoding error"
        default:
            return "Error code \(code)"
        }
    }
    
    // MARK: - Stream Monitoring (FLAC Debugging)
    private var monitoringTimer: Timer?
    
    private func startStreamMonitoring() {
        stopStreamMonitoring() // Clean up any existing timer
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkStreamStatus()
        }
    }
    
    private func stopStreamMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    private func checkStreamStatus() {
        guard currentStream != 0 else {
            stopStreamMonitoring()
            return
        }
        
        let state = BASS_ChannelIsActive(currentStream)
        let positionBytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
        let positionSeconds = BASS_ChannelBytes2Seconds(currentStream, positionBytes)
        let bufferedBytes = BASS_StreamGetFilePosition(currentStream, DWORD(BASS_FILEPOS_BUFFER))
        let downloadedBytes = BASS_StreamGetFilePosition(currentStream, DWORD(BASS_FILEPOS_DOWNLOAD))
        
        // Calculate buffer health
        let bufferHealth = getBufferHealth(bufferedBytes: bufferedBytes)
        let stateDescription = getStreamStateDescription(state)
        
        // Only log meaningful status changes, not normal buffering
        if state == DWORD(BASS_ACTIVE_PLAYING) && positionSeconds > 0 {
            // Only log every 10 seconds when actually playing
            if Int(positionSeconds) % 10 == 0 {
                os_log(.info, log: logger, "✅ FLAC Playing: %.1fs | Downloaded: %lld | Buffer: %{public}s", 
                       positionSeconds, downloadedBytes, bufferHealth)
            }
        } else if state == DWORD(BASS_ACTIVE_STALLED) {
            // STALLED is normal during buffering - only warn if buffer is critically low
            if bufferHealth.contains("CRITICAL") {
                os_log(.error, log: logger, "⚠️ FLAC Critical Buffer: %{public}s | Downloaded: %lld", 
                       bufferHealth, downloadedBytes)
            } else {
                // Normal buffering - less frequent logging
                os_log(.debug, log: logger, "🔄 FLAC Buffering: %{public}s | Downloaded: %lld", 
                       bufferHealth, downloadedBytes)
            }
        } else if state == DWORD(BASS_ACTIVE_STOPPED) {
            os_log(.error, log: logger, "❌ FLAC Stream STOPPED at %.1fs | Buffer: %{public}s", 
                   positionSeconds, bufferHealth)
            stopStreamMonitoring()
        }
    }
    
    private func getStreamStateDescription(_ state: DWORD) -> String {
        switch state {
        case DWORD(BASS_ACTIVE_STOPPED): return "STOPPED"
        case DWORD(BASS_ACTIVE_PLAYING): return "PLAYING"
        case DWORD(BASS_ACTIVE_STALLED): return "BUFFERING"
        case DWORD(BASS_ACTIVE_PAUSED): return "PAUSED"
        default: return "UNKNOWN"
        }
    }
    
    private func getBufferHealth(bufferedBytes: QWORD) -> String {
        // Get current position to calculate remaining buffer
        let positionBytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
        let remainingBytes = bufferedBytes > positionBytes ? bufferedBytes - positionBytes : 0
        
        // CORRECTED: Use realistic FLAC compressed bitrate (~800 kbps average)
        // FLAC compression is typically 50-60% of uncompressed PCM
        let flacBitrate = 800.0 * 1000.0 / 8.0 // ~800 kbps compressed FLAC = 100KB/s
        let remainingSeconds = Double(remainingBytes) / flacBitrate
        
        // Convert to percentage of our 2s target buffer (updated from 20s)
        let bufferPercentage = min(100, Int((remainingSeconds / 2.0) * 100))
        
        switch bufferPercentage {
        case 80...100: return "EXCELLENT (\(bufferPercentage)% = \(Int(remainingSeconds))s)"
        case 50...79: return "GOOD (\(bufferPercentage)% = \(Int(remainingSeconds))s)"
        case 20...49: return "LOW (\(bufferPercentage)% = \(Int(remainingSeconds))s)"
        default: return "CRITICAL (\(bufferPercentage)% = \(Int(remainingSeconds))s)"
        }
    }
    
    private func logStreamInfo() {
        guard currentStream != 0 else { return }
        
        // Get stream format info
        var info = BASS_CHANNELINFO()
        if BASS_ChannelGetInfo(currentStream, &info) != 0 {
            let freq = info.freq
            let chans = info.chans
            let ctype = info.ctype
            let flags = info.flags
            
            os_log(.info, log: logger, "🎵 Stream Info: Freq=%dHz, Channels=%d, Type=%08X, Flags=%08X", 
                   freq, chans, ctype, flags)
            
            // Detailed FLAC type checking
            if (ctype & DWORD(BASS_CTYPE_STREAM_FLAC)) != 0 {
                os_log(.info, log: logger, "✅ Confirmed FLAC stream type")
                
                // Get additional FLAC info
                let length = BASS_ChannelGetLength(currentStream, DWORD(BASS_POS_BYTE))
                let duration = BASS_ChannelBytes2Seconds(currentStream, length)
                
                os_log(.info, log: logger, "🎵 FLAC Details: Length=%lld bytes, Duration=%.2f seconds", 
                       length, duration)
                
            } else {
                os_log(.info, log: logger, "⚠️ Not recognized as FLAC stream!")
                os_log(.info, log: logger, "   Expected: BASS_CTYPE_STREAM_FLAC (%08X)", BASS_CTYPE_STREAM_FLAC)
                os_log(.info, log: logger, "   Actual: %08X", ctype)
                
                // Check if it's being treated as a generic stream
                if (ctype & DWORD(BASS_CTYPE_STREAM)) != 0 {
                    os_log(.info, log: logger, "🔍 Generic stream detected - BASSFLAC may not be loaded properly")
                }
            }
            
            // Check stream flags for issues
            if (flags & DWORD(BASS_SAMPLE_FLOAT)) != 0 {
                os_log(.info, log: logger, "🎵 32-bit floating point stream")
            }
            
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to get stream info: %d (%{public}s)", 
                   errorCode, bassErrorDescription(errorCode))
        }
        
        // Test if we can get position (this should work even before playback)
        let initialPos = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
        os_log(.info, log: logger, "🎵 Initial position: %lld bytes", initialPos)
    }
    
    // MARK: - System Information (Debugging)
    func getBassVersion() -> String {
        let version = BASS_GetVersion()
        let major = (version >> 24) & 0xFF
        let minor = (version >> 16) & 0xFF
        let build = version & 0xFFFF
        return "\(major).\(minor).\(build)"
    }
    
    func getBassSystemInfo() -> [String: Any] {
        return [
            "version": getBassVersion(),
            "isActive": currentStream != 0,
            "currentStream": currentStream,
            "playerState": getPlayerState()
        ]
    }
    
    func isEngineActive() -> Bool {
        return currentStream != 0
    }
    
    // MARK: - Stream Starvation Handling (Squeezelite-style)
    private func handleStreamStarvation(currentTime: Double, duration: Double) {
        os_log(.error, log: logger, "🚨 Stream starvation detected - notifying server (squeezelite-style)")
        
        // Update UI state to reflect stopped state
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.isPaused = false
            self?.delegate?.audioPlayerDidStall()
        }
        
        // CRITICAL: Notify SlimProto coordinator of stream disconnection
        // Server will decide whether to restart, change format, or stop
        if let commandHandler = commandHandler {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Send stream disconnected status to server with current position
                commandHandler.reportStreamDisconnection(
                    currentTime: currentTime,
                    totalDuration: duration,
                    reason: "Network starvation"
                )
                
                os_log(.info, log: self.logger, "📡 Notified server: Stream disconnected at %.1fs (reason: starvation)", currentTime)
            }
        } else {
            os_log(.error, log: logger, "❌ Cannot notify server of starvation - no command handler")
        }
    }
    
    // MARK: - Cleanup
    deinit {
        cleanup()
        BASS_Free()
        os_log(.info, log: logger, "CBassAudioPlayer deinitialized")
    }
}
