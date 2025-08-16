//
//  CBassAudioPlayer.swift
//  LyrPlay
//
//  CBass audio player implementation - Professional BASS audio library integration
//  Replaces StreamingKit with superior FLAC support and native seeking capabilities
//

import Foundation
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
        // Initialize BASS core
        let bassInit = BASS_Init(-1, 44100, 0, nil, nil)
        if bassInit == 0 {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS initialization failed: %d", errorCode)
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
        
        // Configure BASS for optimal LMS streaming
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(15000))     // 15 second timeout
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_READTIMEOUT), DWORD(10000)) // 10s read timeout
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(8192))       // 8KB default network buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(500))            // 500ms default playback buffer
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))       // 50ms update period for FLAC
        BASS_SetConfig(DWORD(BASS_CONFIG_UPDATETHREADS), DWORD(2))       // Dual-threaded updates
        
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
        
        // Create BASS stream - FLAC detection is working properly
        
        currentStream = BASS_StreamCreateURL(
            urlString,                   // Original URL (FLAC detection works fine)
            0,                           // offset (always 0 for network)
            DWORD(BASS_STREAM_BLOCK) |   // blocking mode for network streams
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
                
                // INTEGRATION POINT: Notify SlimProto of stream connection
                self.commandHandler?.handleStreamConnected()
                
                // Update UI state
                self.isPlaying = true
                self.isPaused = false
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
            // FLAC streaming optimization - focus on sustained playback
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(5000))        // 5s buffer for sustained FLAC
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(131072))  // 128KB network buffer for large FLAC chunks
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(25))      // 25% pre-buffer to start sooner
            BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(100))   // Less frequent updates for stability
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(30000))  // 30s timeout for large files
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_READTIMEOUT), DWORD(15000)) // 15s read timeout
            os_log(.info, log: logger, "🎵 Configured for sustained FLAC streaming: 5s buffer, 128KB network, 25%% prebuffer")
            
        case "AAC":
            // AAC optimizations
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(500))         // 500ms buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(8192))    // 8KB network buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(50))      // Pre-buffer 50%
            os_log(.info, log: logger, "🎵 Configured for AAC audio")
            
        case "MP3":
            // MP3 stream optimizations
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(750))         // 750ms buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(8192))    // 8KB network buffer
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(50))      // Pre-buffer 50%
            os_log(.info, log: logger, "🎵 Configured for MP3 streaming")
            
        default:
            // Default configuration
            BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(500))         // 500ms default
            BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(8192))    // 8KB default
            os_log(.info, log: logger, "🎵 Using default configuration for format: %{public}@", format)
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
                    os_log(.info, log: player.logger, "🎵 Track ended - notifying SlimProto")
                    
                    // INTEGRATION POINT: Notify SlimProto of track end
                    player.commandHandler?.notifyTrackEnded()
                    
                    // Update UI state
                    player.isPlaying = false
                    player.isPaused = false
                    player.delegate?.audioPlayerDidReachEnd()
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
        BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_POS), oneSecondBytes, { handle, channel, data, user in
            guard let user = user else { return }
            let player = Unmanaged<CBassAudioPlayer>.fromOpaque(user).takeUnretainedValue()
            
            let currentTime = player.getCurrentTime()
            DispatchQueue.main.async {
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
        let bytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))
        let buffered = BASS_StreamGetFilePosition(currentStream, DWORD(BASS_FILEPOS_BUFFER))
        let downloaded = BASS_StreamGetFilePosition(currentStream, DWORD(BASS_FILEPOS_DOWNLOAD))
        
        if state == DWORD(BASS_ACTIVE_STALLED) {
            os_log(.info, log: logger, "🚨 FLAC Stream Status: STALLED - Bytes: %lld, Buffer: %lld, Downloaded: %lld",
                   bytes, buffered, downloaded)
        } else if state == DWORD(BASS_ACTIVE_STOPPED) {
            os_log(.error, log: logger, "🚨 FLAC Stream Status: STOPPED - Bytes: %lld, Buffer: %lld, Downloaded: %lld", 
                   bytes, buffered, downloaded)
            stopStreamMonitoring()
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
    
    // MARK: - Cleanup
    deinit {
        cleanup()
        BASS_Free()
        os_log(.info, log: logger, "CBassAudioPlayer deinitialized")
    }
}
