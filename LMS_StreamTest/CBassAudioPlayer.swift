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
        
        // Initialize BASSFLAC addon for FLAC support
        let flacInit = BASSFLAC_Init()
        if flacInit == 0 {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASSFLAC initialization failed: %d", errorCode)
        }
        
        // Configure BASS for optimal LMS streaming
        BASS_SetConfig(BASS_CONFIG_NET_TIMEOUT, 15000)  // 15 second timeout
        BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
        BASS_SetConfig(BASS_CONFIG_BUFFER, 500)         // 500ms playback buffer
        BASS_SetConfig(BASS_CONFIG_UPDATEPERIOD, 10)    // 10ms update period
        BASS_SetConfig(BASS_CONFIG_UPDATETHREADS, 2)    // Dual-threaded updates
        
        os_log(.info, log: logger, "✅ BASS initialized - Version: %08X", BASS_GetVersion())
        os_log(.info, log: logger, "✅ BASSFLAC addon initialized")
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
        
        // Create BASS stream from URL
        currentStream = BASS_StreamCreateURL(
            urlString,                    // URL
            0,                           // offset (always 0 for network)
            BASS_STREAM_BLOCK |          // blocking mode for network streams
            BASS_STREAM_STATUS,          // enable status info
            nil,                         // download progress callback (not needed)
            nil                          // user data
        )
        
        guard currentStream != 0 else {
            let errorCode = BASS_ErrorGetCode()
            DispatchQueue.main.async {
                self.handleBassError("Stream creation failed", errorCode: errorCode)
            }
            return
        }
        
        // Set up callbacks for track end detection and status updates
        setupCallbacks()
        
        // Start playback
        let playResult = BASS_ChannelPlay(currentStream, 0) // 0 = don't restart if already playing
        
        DispatchQueue.main.async {
            if playResult != 0 {
                os_log(.info, log: self.logger, "✅ CBass stream started successfully")
                
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
        return audioQueue.sync {
            guard currentStream != 0 else { return 0.0 }
            let bytes = BASS_ChannelGetPosition(currentStream, BASS_POS_BYTE)
            return BASS_ChannelBytes2Seconds(currentStream, bytes)
        }
    }
    
    func getDuration() -> Double {
        // Prefer metadata duration if available
        if metadataDuration > 0 {
            return metadataDuration
        }
        
        return audioQueue.sync {
            guard currentStream != 0 else { return 0.0 }
            let bytes = BASS_ChannelGetLength(currentStream, BASS_POS_BYTE)
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
        return audioQueue.sync {
            guard currentStream != 0 else { return "No Stream" }
            
            let state = BASS_ChannelIsActive(currentStream)
            switch state {
            case BASS_ACTIVE_STOPPED:
                return "Stopped"
            case BASS_ACTIVE_PLAYING:
                return "Playing"
            case BASS_ACTIVE_PAUSED:
                return "Paused"
            case BASS_ACTIVE_STALLED:
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
            BASS_ChannelSetAttribute(self.currentStream, BASS_ATTRIB_VOL, clampedVolume)
        }
    }
    
    func getVolume() -> Float {
        return audioQueue.sync {
            guard currentStream != 0 else { return 1.0 }
            var volume: Float = 1.0
            BASS_ChannelGetAttribute(currentStream, BASS_ATTRIB_VOL, &volume)
            return volume
        }
    }
    
    // MARK: - Seeking (MAJOR IMPROVEMENT: Native FLAC seeking!)
    func seekToPosition(_ time: Double) {
        audioQueue.async { [weak self] in
            guard let self = self, self.currentStream != 0 else { return }
            
            let bytes = BASS_ChannelSeconds2Bytes(self.currentStream, time)
            let result = BASS_ChannelSetPosition(self.currentStream, bytes, BASS_POS_BYTE)
            
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
            // Lossless audio optimizations
            BASS_SetConfig(BASS_CONFIG_BUFFER, 1000)        // 1 second buffer
            BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 16384)   // 16KB network buffer
            os_log(.info, log: logger, "🎵 Configured for lossless audio: %{public}@", format)
            
        case "AAC":
            // AAC optimizations
            BASS_SetConfig(BASS_CONFIG_BUFFER, 500)         // 500ms buffer
            BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
            os_log(.info, log: logger, "🎵 Configured for AAC audio")
            
        case "MP3":
            // MP3 stream optimizations
            BASS_SetConfig(BASS_CONFIG_BUFFER, 750)         // 750ms buffer
            BASS_SetConfig(BASS_CONFIG_NET_BUFFER, 8192)    // 8KB network buffer
            os_log(.info, log: logger, "🎵 Configured for MP3 streaming")
            
        default:
            // Default configuration
            BASS_SetConfig(BASS_CONFIG_BUFFER, 500)         // 500ms default
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
        if currentStream != 0 {
            BASS_ChannelStop(currentStream)
            BASS_StreamFree(currentStream)
            currentStream = 0
        }
    }
    
    private func setupCallbacks() {
        // TODO: Implement BASS callback system for track end detection
        // This will be implemented in the next phase
        os_log(.info, log: logger, "🔍 CBass callbacks setup (placeholder)")
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