// File: AudioPlayer.swift
// Updated to use BASS with plugin loading for FLAC/Opus support
// BASS API exposed via bridging header (LMS_StreamTest-Bridging-Header.h)
import Foundation
import AVFoundation
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
    func audioPlayerRequestsSeek(_ timeOffset: Double)  // For transcoding pipeline fixes
    func audioPlayerDidReceiveMetadata(_ metadata: (title: String?, artist: String?))  // ICY metadata from radio streams
}

class AudioPlayer: NSObject, ObservableObject {

    // MARK: - Stream Info
    struct StreamInfo {
        let format: String
        let sampleRate: Int
        let channels: Int
        let bitDepth: Int
        let bitrate: Float

        var displayString: String {
            let channelStr = channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels)ch"
            let bitrateStr = bitrate > 0 ? " @ \(Int(bitrate)) kbps" : ""
            return "\(format) • \(sampleRate/1000)kHz • \(bitDepth)-bit • \(channelStr)\(bitrateStr)"
        }
    }

    // MARK: - Output Device Info
    struct OutputDeviceInfo {
        let deviceName: String
        let deviceType: String
        let outputSampleRate: Int
        let outputChannels: Int
        let latency: Int  // milliseconds

        var displayString: String {
            return "\(deviceName) • \(outputSampleRate/1000)kHz • \(latency)ms latency"
        }
    }

    // MARK: - Playback State (Player Synchronization)
    /// Playback state enum for synchronized multi-room audio
    enum PlaybackState {
        case stopped          // No playback
        case buffering        // Loading stream data
        case running          // Active playback
        case startAt(jiffies: TimeInterval)  // Waiting for synchronized start time
    }

    // MARK: - Published Properties
    @Published var currentStreamInfo: StreamInfo?
    @Published var currentOutputInfo: OutputDeviceInfo?

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

    // Synchronized playback state and monitoring
    private var playbackState: PlaybackState = .stopped
    private var startAtMonitorTimer: Timer?
    
    // MARK: - Delegation
    weak var delegate: AudioPlayerDelegate?
    
    // MARK: - State Tracking
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 1.0  // Max 1 update per second

    private var currentStreamURL: String = ""
    private var currentStreamFormat: String = "UNKNOWN"
    private var pendingReplayGain: Float = 0.0  // ReplayGain to apply after stream creation

    // MARK: - Silent Recovery Support
    /// Flag to mute the next stream creation (for silent app foreground recovery)
    /// When true, stream volume is set to 0 immediately upon creation
    var muteNextStream: Bool = false

    weak var commandHandler: SlimProtoCommandHandler?
    weak var audioManager: AudioManager?  // Reference to notify about media control refresh

    // MARK: - ICY Metadata Handling
    private var metadataSync: HSYNC = 0

    // MARK: - Initialization
    override init() {
        super.init()
        setupCBass()
        setupRouteChangeObserver()
        #if DEBUG
        os_log(.info, log: logger, "AudioPlayer initialized with CBass")
        #endif
    }

    private func setupRouteChangeObserver() {
        // Observe audio route changes to update output device info
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        // Update output device info when route changes (AirPods, CarPlay, USB DAC, etc.)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateOutputDeviceInfo()
            os_log(.info, log: self.logger, "🔀 Route changed - output device info updated")
        }
    }
    
    // MARK: - Core Setup (MINIMAL CBASS)
    private func setupCBass() {
        // BASS handles iOS audio session automatically (default behavior)
        // No BASS_CONFIG_IOS_SESSION configuration needed - BASS manages everything

        // Initialize BASS with BASS_DEVICE_FREQ flag at 48kHz base rate
        // 48kHz is the base of high-res family (48→96→192kHz clean multiples)
        // Prevents upsampling while allowing DAC to negotiate up for high-res content
        // BASS_DEVICE_FREQ flag enables DAC to output at higher rates when content matches
        let targetRate: DWORD = 48000  // 48kHz family base for high-res compatibility
        let result = BASS_Init(-1, targetRate, DWORD(BASS_DEVICE_FREQ), nil, nil)

        if result == 0 {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS initialization failed: %d", errorCode)
            return
        }

        // Query what sample rate we actually got from the hardware
        var info = BASS_INFO()
        if BASS_GetInfo(&info) != 0 {
            let actualRate = info.freq
            os_log(.info, log: logger, "🎵 BASS Audio Output: Requested %dHz → Hardware provided %dHz",
                   Int(targetRate), actualRate)

            // Log device type based on actual rate for debugging
            if actualRate >= 192000 {
                os_log(.info, log: logger, "✅ High-end external DAC detected (192kHz+)")
            } else if actualRate >= 96000 {
                os_log(.info, log: logger, "✅ External DAC detected (96kHz)")
            } else if actualRate == 48000 {
                os_log(.info, log: logger, "📱 Standard iOS output (48kHz - built-in/AirPods)")
            } else if actualRate == 44100 {
                os_log(.info, log: logger, "📱 Standard iOS output (44.1kHz - built-in speaker)")
            }

            // CRITICAL: Check for BASS vs iOS mismatch (LMS_StreamTest-yg4)
            // If BASS thinks 192kHz but iOS is at 48kHz, iOS will resample down
            let iosRate = AVAudioSession.sharedInstance().sampleRate
            os_log(.info, log: logger, "🔍 Sample Rate Verification: BASS=%dHz, iOS=%.0fHz", actualRate, iosRate)

            if abs(Double(actualRate) - iosRate) > 100 {
                os_log(.error, log: logger, "⚠️ MISMATCH DETECTED: BASS reports %dHz but iOS session is %.0fHz - audio will be resampled!", actualRate, iosRate)
                os_log(.error, log: logger, "⚠️ This means high-res audio will be downsampled to %.0fHz by iOS", iosRate)
            } else {
                os_log(.info, log: logger, "✅ BASS and iOS sample rates match - bit-perfect output")
            }
        } else {
            os_log(.error, log: logger, "❌ Failed to get BASS device info: %d", BASS_ErrorGetCode())
        }

        // REMOVED: Excessive 1MB verification window was potentially blocking transcoded streams
        // Use BASS defaults instead: VERIFY=16KB, VERIFY_NET=4KB (25% of VERIFY)
        // let verifyBytes = DWORD(1024 * 1024)
        // BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY), verifyBytes)
        // BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY_NET), verifyBytes)
        os_log(.info, log: logger, "✅ Using BASS default verification (16KB local, 4KB network)")

        // BASS PLUGIN LOADING (per Ian@un4seen recommendation)
        // Load FLAC and Opus plugins so BASS_StreamCreateURL can handle all formats
        let flacPlugin = BASS_PluginLoad("bassflac", 0)
        let opusPlugin = BASS_PluginLoad("bassopus", 0)

        if flacPlugin != 0 {
            os_log(.info, log: logger, "✅ BASSFLAC plugin loaded: handle=%d", flacPlugin)
        } else {
            os_log(.error, log: logger, "❌ Failed to load BASSFLAC plugin: %d", BASS_ErrorGetCode())
        }

        if opusPlugin != 0 {
            os_log(.info, log: logger, "✅ BASSOPUS plugin loaded: handle=%d", opusPlugin)
        } else {
            os_log(.error, log: logger, "❌ Failed to load BASSOPUS plugin: %d", BASS_ErrorGetCode())
        }

        // Enable ICY metadata for radio streams
        BASS_SetConfig(DWORD(BASS_CONFIG_NET_META), 1)  // Enable Shoutcast metadata requests

        // Network buffer configuration - optimized for both LAN and mobile streaming
        //BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(10000))  // 10s buffer (balanced for LAN/cellular)
        //os_log(.info, log: logger, "📡 Network buffer: 10s (balanced for LAN/mobile streaming)")
        #if DEBUG
        os_log(.info, log: logger, "✅ BASS configured with automatic iOS session management")
        os_log(.info, log: logger, "✅ CBass configured - Version: %08X", BASS_GetVersion())
        #endif
    }

    /// Legacy auth header update - no longer used with URL-embedded credentials
    /// Kept for compatibility with SettingsManager.saveSettings()
    func updateAuthHeader() {
        // No-op: Authentication now handled via URL-embedded credentials
        // Stream URLs use http://user:pass@host:port format
        // WebView and JSON-RPC use Authorization headers
    }

    // MARK: - Stream Playback (MINIMAL CBASS)
    func playStream(urlString: String) {
        guard !urlString.isEmpty else {
            os_log(.error, log: logger, "Empty URL provided")
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with CBass: %{public}s", urlString)
        
        // Track current URL for potential recovery scenarios
        currentStreamURL = urlString
        
        // If no format was explicitly set, try to detect from URL as fallback
        if currentStreamFormat == "UNKNOWN" {
            os_log(.info, log: logger, "⚠️ No format set - using generic stream creation")
        }
        
        prepareForNewStream()
        
        // Track timing for reference
        trackStartTime = Date()
        
        // CBass configured for streaming FLAC tolerance (like squeezelite)
        // TESTING v1.6.2: BASS_STREAM_BLOCK for better transcoded stream compatibility
        let streamFlags = DWORD(BASS_STREAM_STATUS) |   // enable status info
                         DWORD(BASS_STREAM_BLOCK)        // force streaming mode (tolerates incomplete data)
        //                 DWORD(BASS_STREAM_AUTOFREE) |   // auto-free when stopped
         //                DWORD(BASS_SAMPLE_FLOAT) |      // use float samples (like squeezelite)

        // FORMAT-SPECIFIC stream creation - CRITICAL FIX for Opus seeking
        currentStream = createStreamForFormat(urlString: urlString, streamFlags: streamFlags)

        guard currentStream != 0 else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_StreamCreateURL failed: %d for URL: %{public}s", errorCode, urlString)

            // Handle format errors (permanent failures)
            if errorCode == DWORD(41) {  // BASS_ERROR_FILEFORM - unsupported format
                os_log(.error, log: logger, "❌ Unsupported audio format - notifying server with STMn")
                commandHandler?.handleStreamFailed()
                return
            }

            // Handle timeout errors (transient failures)
            if errorCode == DWORD(40) {  // BASS_ERROR_TIMEOUT
                // CRITICAL: Check if we're in a track transition
                if let handler = commandHandler, handler.isInTrackTransition() {
                    // Track transition - don't send seek, server is already switching tracks
                    os_log(.info, log: logger, "🔧 BASS timeout during track transition - skipping auto-seek (waitingForNextTrack)")
                } else {
                    // Normal playback - send seek to fix transcoding pipeline
                    os_log(.info, log: logger, "🔧 BASS timeout detected - requesting minimal seek to fix transcoding")
                    delegate?.audioPlayerRequestsSeek(0.05)
                }
            }
            return
        }

        // SILENT RECOVERY: Mute using DSP gain (like ReplayGain) instead of volume
        // BASS_ATTRIB_VOLDSP applies gain to sample data - should actually work!
        // Use 0.001 instead of 0.0 to avoid any potential edge cases (-60dB = effectively silent)
        if muteNextStream {
            BASS_ChannelSetAttribute(currentStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
            os_log(.info, log: logger, "🔇 APP OPEN RECOVERY: DSP gain = 0.001 (sample-level muting, -60dB)")
        }

        setupCallbacks()

        // Apply ReplayGain BEFORE starting playback if pending
        if pendingReplayGain > 0.0 {
            applyReplayGain(pendingReplayGain)
            pendingReplayGain = 0.0  // Clear after application
        }

        let playResult = BASS_ChannelPlay(currentStream, 0)
        if playResult != 0 {
            os_log(.info, log: logger, "✅ CBass playback started - Handle: %d (muted: %{public}s)", currentStream, muteNextStream ? "YES" : "NO")

            // Update stream info for UI display (also updates output device info)
            updateStreamInfo()

            commandHandler?.handleStreamConnected()
            delegate?.audioPlayerDidStartPlaying()
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ BASS_ChannelPlay failed: %d", errorCode)
        }
    }
    
    func playStreamWithFormat(urlString: String, format: String, replayGain: Float = 0.0) {
        os_log(.info, log: logger, "🎵 Playing %{public}s stream: %{public}s with replayGain %.4f", format, urlString, replayGain)

        // CRITICAL: Store format for plugin-specific stream creation
        currentStreamFormat = format

        // Store replayGain for application after stream creation
        pendingReplayGain = replayGain

        // Format-specific configuration
        configureForFormat(format)

        // Use the main playStream method (which will apply replayGain after stream creation)
        playStream(urlString: urlString)
    }

    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String, replayGain: Float = 0.0) {
        playStreamWithFormat(urlString: urlString, format: format, replayGain: replayGain)

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
        playbackState = .stopped
        stopStartAtMonitoring()

        if currentStream != 0 {
            BASS_ChannelStop(currentStream)
            currentStream = 0
        }

        delegate?.audioPlayerDidStop()
        os_log(.debug, log: logger, "⏹️ CBass stopped playback")
    }

    // MARK: - Synchronized Start (OUTPUT_START_AT)

    /// Start playback at a specific jiffies time (for multi-room sync)
    /// Buffers audio but delays playback until local jiffies >= targetJiffies
    func startAt(jiffies targetJiffies: TimeInterval) {
        guard currentStream != 0 else {
            os_log(.error, log: logger, "❌ startAt() called with no active stream")
            return
        }

        os_log(.info, log: logger, "🎯 Synchronized start requested at jiffies %.3f", targetJiffies)

        // Enter OUTPUT_START_AT state
        playbackState = .startAt(jiffies: targetJiffies)

        // Start monitoring - check every 100ms if we've reached the target time
        startStartAtMonitoring(targetJiffies: targetJiffies)
    }

    /// Monitor current jiffies and start playback when target time is reached
    private func startStartAtMonitoring(targetJiffies: TimeInterval) {
        // Stop any existing timer
        stopStartAtMonitoring()

        // Create timer on main thread to check jiffies every 100ms
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.startAtMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }

                // Check if we're still in startAt state
                guard case .startAt(let targetJiffies) = self.playbackState else {
                    self.stopStartAtMonitoring()
                    return
                }

                // Get current jiffies (milliseconds since app start)
                let currentJiffies = ProcessInfo.processInfo.systemUptime

                // Check if we've reached or passed the target time
                // Also handle timeout (if target is >10s in future, something's wrong)
                if currentJiffies >= targetJiffies || targetJiffies > currentJiffies + 10.0 {
                    if targetJiffies > currentJiffies + 10.0 {
                        os_log(.error, log: self.logger, "⚠️ Target jiffies %.3f is too far in future (>10s) - starting immediately", targetJiffies)
                    } else {
                        os_log(.info, log: self.logger, "✅ Jiffies target reached! (current: %.3f >= target: %.3f) - starting playback", currentJiffies, targetJiffies)
                    }

                    // Transition to running state
                    self.playbackState = .running
                    self.stopStartAtMonitoring()

                    // Start actual BASS playback
                    let result = BASS_ChannelPlay(self.currentStream, 0)

                    if result != 0 {
                        os_log(.info, log: self.logger, "▶️ Synchronized playback started at jiffies %.3f", currentJiffies)
                        self.delegate?.audioPlayerDidStartPlaying()
                    } else {
                        let errorCode = BASS_ErrorGetCode()
                        os_log(.error, log: self.logger, "❌ Failed to start synchronized playback: %d", errorCode)
                    }
                } else {
                    // Keep buffering - log every 1 second to avoid spam
                    let delta = targetJiffies - currentJiffies
                    if Int(delta * 10) % 10 == 0 {  // Log every ~1 second
                        os_log(.debug, log: self.logger, "⏳ Buffering for sync start - waiting %.1f more seconds", delta)
                    }
                }
            }

            os_log(.info, log: self.logger, "🔄 Started jiffies monitoring timer for synchronized start")
        }
    }

    /// Stop the startAt monitoring timer
    private func stopStartAtMonitoring() {
        startAtMonitorTimer?.invalidate()
        startAtMonitorTimer = nil
    }

    // MARK: - Sync Drift Corrections

    /// Play silence for a duration (timed pause for sync drift correction)
    /// Advances playback position without outputting audio
    func playSilence(duration: TimeInterval) {
        guard currentStream != 0 else {
            os_log(.error, log: logger, "❌ playSilence() called with no active stream")
            return
        }

        os_log(.info, log: logger, "⏸️🔇 Playing silence for %.3f seconds (drift correction)", duration)

        // Get current position in bytes
        let currentPosBytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))

        // Convert duration to bytes
        let durationBytes = BASS_ChannelSeconds2Bytes(currentStream, duration)

        // Calculate new position
        let newPosBytes = currentPosBytes + durationBytes

        // Set new position (effectively skips ahead, "playing" silence)
        let result = BASS_ChannelSetPosition(currentStream, newPosBytes, DWORD(BASS_POS_BYTE))

        if result != 0 {
            os_log(.info, log: logger, "✅ Silence played - advanced %.3f seconds", duration)
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to play silence: %d", errorCode)
        }
    }

    /// Skip ahead by consuming buffer (sync drift correction)
    /// Advances playback position to catch up with synchronized playback
    func skipAhead(duration: TimeInterval) {
        guard currentStream != 0 else {
            os_log(.error, log: logger, "❌ skipAhead() called with no active stream")
            return
        }

        os_log(.info, log: logger, "⏩ Skipping ahead %.3f seconds (drift correction)", duration)

        // Get current position in bytes
        let currentPosBytes = BASS_ChannelGetPosition(currentStream, DWORD(BASS_POS_BYTE))

        // Convert duration to bytes
        let durationBytes = BASS_ChannelSeconds2Bytes(currentStream, duration)

        // Calculate new position
        let newPosBytes = currentPosBytes + durationBytes

        // Set new position (skip ahead in buffer)
        let result = BASS_ChannelSetPosition(currentStream, newPosBytes, DWORD(BASS_POS_BYTE))

        if result != 0 {
            os_log(.info, log: logger, "✅ Skipped ahead %.3f seconds", duration)
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to skip ahead: %d", errorCode)
        }
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

    /// Restore DSP gain to 1.0 after silent recovery
    func restoreDSPGain() {
        guard currentStream != 0 else { return }

        BASS_ChannelSetAttribute(currentStream, DWORD(BASS_ATTRIB_VOLDSP), 1.0)
        os_log(.info, log: logger, "🔊 APP OPEN RECOVERY: DSP gain restored to 1.0")
    }

    // MARK: - ReplayGain Support
    private func applyReplayGain(_ replayGain: Float) {
        guard currentStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot apply ReplayGain: no active stream")
            return
        }

        // Server sends replay_gain as 32-bit u32_t in 16.16 fixed point format
        // Already converted to float by dividing by 65536.0
        // Represents linear gain multiplier (e.g., 0.501 for -6dB, 1.412 for +3dB)

        // Use BASS_ATTRIB_VOLDSP instead of BASS_ATTRIB_VOL because:
        // - BASS_ATTRIB_VOLDSP applies gain to sample data (like squeezelite)
        // - BASS_ATTRIB_VOL controls playback volume and would interfere with user volume
        // - VOLDSP works on decoding channels and is present in the DSP chain

        // Clamp to reasonable range to prevent distortion
        let clampedGain = min(replayGain, 2.0)  // Max 2x gain (~6dB boost)

        let success = BASS_ChannelSetAttribute(currentStream, DWORD(BASS_ATTRIB_VOLDSP), clampedGain)

        if success != 0 {
            os_log(.info, log: logger, "✅ Applied ReplayGain DSP: %.4f (clamped: %.4f)", replayGain, clampedGain)
        } else {
            let errorCode = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to apply ReplayGain DSP: BASS error %d", errorCode)
        }
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
        // Clear stream info when stream is cleaned up
        currentStreamInfo = nil
        // Note: Keep output device info - it's still valid even without an active stream
    }

    // MARK: - Stream Info Retrieval
    private func updateStreamInfo() {
        guard currentStream != 0 else {
            currentStreamInfo = nil
            return
        }

        // Get channel info from BASS
        var info = BASS_CHANNELINFO()
        guard BASS_ChannelGetInfo(currentStream, &info) != 0 else {
            os_log(.error, log: logger, "❌ Failed to get channel info: %d", BASS_ErrorGetCode())
            return
        }

        // Get bitrate attribute
        var bitrate: Float = 0.0
        BASS_ChannelGetAttribute(currentStream, DWORD(BASS_ATTRIB_BITRATE), &bitrate)

        // Map ctype to human-readable format name
        let formatName = formatNameFromCType(info.ctype)

        // Extract bit depth from origres (LOWORD contains bits)
        let bitDepth = Int(info.origres & 0xFFFF)

        let streamInfo = StreamInfo(
            format: formatName,
            sampleRate: Int(info.freq),
            channels: Int(info.chans),
            bitDepth: bitDepth > 0 ? bitDepth : 16,  // Default to 16-bit if not specified
            bitrate: bitrate
        )

        currentStreamInfo = streamInfo
        os_log(.info, log: logger, "📊 Stream info: %{public}s", streamInfo.displayString)

        // Also update output device info when stream changes (sample rate may change)
        updateOutputDeviceInfo()
    }

    private func formatNameFromCType(_ ctype: DWORD) -> String {
        // BASS codec type constants
        let BASS_CTYPE_STREAM_MP3: DWORD = 0x10005
        let BASS_CTYPE_STREAM_VORBIS: DWORD = 0x10002  // OGG Vorbis
        let BASS_CTYPE_STREAM_OPUS: DWORD = 0x11200    // From bassopus.h
        let BASS_CTYPE_STREAM_FLAC: DWORD = 0x10900    // From bassflac.h
        let BASS_CTYPE_STREAM_FLAC_OGG: DWORD = 0x10901  // FLAC in OGG container
        let BASS_CTYPE_STREAM_WAV: DWORD = 0x40000     // WAV format flag
        let BASS_CTYPE_STREAM_WAV_PCM: DWORD = 0x10001
        let BASS_CTYPE_STREAM_WAV_FLOAT: DWORD = 0x10003
        let BASS_CTYPE_STREAM_AIFF: DWORD = 0x10004
        let BASS_CTYPE_STREAM_CA: DWORD = 0x10007      // CoreAudio (AAC on iOS)

        // Check for WAV format flag first (0x40000 bit set)
        if (ctype & BASS_CTYPE_STREAM_WAV) != 0 {
            // Extract codec from LOWORD
            let codec = ctype & 0xFFFF
            switch codec {
            case 0x0001:  // WAVE_FORMAT_PCM
                return "WAV PCM"
            case 0x0003:  // WAVE_FORMAT_IEEE_FLOAT
                return "WAV Float"
            default:
                return "WAV (codec \(String(format: "0x%X", codec)))"
            }
        }

        switch ctype {
        case BASS_CTYPE_STREAM_MP3:
            return "MP3"
        case BASS_CTYPE_STREAM_VORBIS:
            return "OGG Vorbis"
        case BASS_CTYPE_STREAM_OPUS:
            return "Opus"
        case BASS_CTYPE_STREAM_FLAC:
            return "FLAC"
        case BASS_CTYPE_STREAM_FLAC_OGG:
            return "FLAC (OGG)"
        case BASS_CTYPE_STREAM_WAV_PCM:
            return "WAV PCM"
        case BASS_CTYPE_STREAM_WAV_FLOAT:
            return "WAV Float"
        case BASS_CTYPE_STREAM_AIFF:
            return "AIFF"
        case BASS_CTYPE_STREAM_CA:
            return "AAC"
        default:
            return "Unknown (\(String(format: "0x%X", ctype)))"
        }
    }

    // MARK: - Output Device Info Retrieval
    public func updateOutputDeviceInfo() {
        // Get current BASS device output information (sample rate, latency, etc.)
        var info = BASS_INFO()
        guard BASS_GetInfo(&info) != 0 else {
            os_log(.error, log: logger, "❌ Failed to get BASS output info: %d", BASS_ErrorGetCode())
            currentOutputInfo = nil
            return
        }

        // On iOS, BASS uses the default device (-1) and routing is managed by iOS
        // Query AVAudioSession for the actual device name and type
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute

        // Get the first output (primary audio route)
        guard let output = currentRoute.outputs.first else {
            os_log(.error, log: logger, "❌ No audio output route available")
            currentOutputInfo = nil
            return
        }

        // Extract device name and type from iOS audio route
        let deviceName = output.portName  // e.g., "AirPods Pro", "Speaker", "USB Audio Device"
        let deviceType = deviceTypeFromPortType(output.portType)

        // Create output device info with BASS specs + iOS device info
        let outputInfo = OutputDeviceInfo(
            deviceName: deviceName,
            deviceType: deviceType,
            outputSampleRate: Int(info.freq),
            outputChannels: Int(info.speakers),
            latency: Int(info.latency)
        )

        currentOutputInfo = outputInfo
        os_log(.info, log: logger, "🔊 Output device: %{public}s (port: %{public}s)",
               outputInfo.displayString, output.portType.rawValue)
    }

    private func deviceTypeFromPortType(_ portType: AVAudioSession.Port) -> String {
        // Map iOS AVAudioSession port types to human-readable device types
        switch portType {
        case .builtInSpeaker:
            return "Built-in Speaker"
        case .builtInReceiver:
            return "Built-in Receiver"
        case .headphones:
            return "Headphones"
        case .bluetoothA2DP:
            return "Bluetooth Audio"
        case .bluetoothLE:
            return "Bluetooth LE"
        case .bluetoothHFP:
            return "Bluetooth Hands-Free"
        case .carAudio:
            return "CarPlay"
        case .airPlay:
            return "AirPlay"
        case .HDMI:
            return "HDMI"
        case .usbAudio:
            return "USB Audio"
        case .lineOut:
            return "Line Out"
        case .headsetMic:
            return "Headset"
        default:
            return "Audio Output"
        }
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

        // ICY metadata callback for radio streams
        setupMetadataCallback()
    }

    // MARK: - ICY Metadata Handling
    private func setupMetadataCallback() {
        guard currentStream != 0 else { return }

        // Remove any existing metadata sync
        if metadataSync != 0 {
            BASS_ChannelRemoveSync(currentStream, metadataSync)
            metadataSync = 0
        }

        // Only set up metadata callback for HTTP streams (radio/streaming)
        if currentStreamURL.hasPrefix("http") {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            metadataSync = BASS_ChannelSetSync(currentStream, DWORD(BASS_SYNC_META), 0, { handle, channel, data, user in
                guard let user = user else { return }
                let player = Unmanaged<AudioPlayer>.fromOpaque(user).takeUnretainedValue()

                DispatchQueue.main.async {
                    player.handleMetadataUpdate()
                }
            }, selfPtr)

            if metadataSync != 0 {
                os_log(.info, log: logger, "🎵 ICY metadata callback set up for radio stream")
            }
        }
    }

    private func handleMetadataUpdate() {
        guard currentStream != 0 else { return }

        // Get ICY metadata from BASS
        guard let metaPtr = BASS_ChannelGetTags(currentStream, DWORD(BASS_TAG_META)) else {
            os_log(.debug, log: logger, "🎵 No ICY metadata available")
            return
        }

        let metaString = String(cString: metaPtr)
        // Parse ICY metadata format: StreamTitle='Artist - Title';StreamUrl='xxx';
        let metadata = parseICYMetadata(metaString)

        if metadata.title != nil || metadata.artist != nil {
            delegate?.audioPlayerDidReceiveMetadata(metadata)
        }
    }

    private func parseICYMetadata(_ metaString: String) -> (title: String?, artist: String?) {
        var title: String?
        var artist: String?

        // Look for StreamTitle='...' in the metadata
        if let titleRange = metaString.range(of: "StreamTitle='") {
            let startIndex = titleRange.upperBound
            if let endRange = metaString[startIndex...].range(of: "';") {
                let titleContent = String(metaString[startIndex..<endRange.lowerBound])

                // Try to split "Artist - Title" format
                if titleContent.contains(" - ") {
                    let components = titleContent.components(separatedBy: " - ")
                    if components.count >= 2 {
                        artist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        title = components[1...].joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        title = titleContent
                    }
                } else {
                    title = titleContent
                }
            }
        }

        return (title: title, artist: artist)
    }

    // MARK: - Unified Stream Creation (per Ian@un4seen - uses plugin system)
    private func createStreamForFormat(urlString: String, streamFlags: DWORD) -> HSTREAM {
        // Use the format provided by SlimProto STRM command (for logging only)
        let format = currentStreamFormat

        // UNIFIED APPROACH: BASS_StreamCreateURL automatically uses appropriate plugin
        // based on file headers after BASS_PluginLoad() has registered FLAC and Opus support
        os_log(.info, log: logger, "🎵 Creating %{public}s stream with unified BASS_StreamCreateURL (plugin-based)", format)

        return BASS_StreamCreateURL(
            urlString,
            0,                    // offset
            streamFlags,          // flags
            nil, nil             // no callbacks
        )
    }
    
    
    // MARK: - Format Configuration (USER-CONFIGURABLE CBass BUFFERS)  
    private func configureForFormat(_ format: String) {
        switch format.uppercased() {
        case "FLAC":
            // Use user-configurable CBass buffer settings
            //let flacBufferMS = settings.flacBufferSeconds * 1000     // Playback buffer in milliseconds
            //let networkBufferMS = settings.networkBufferKB * 1000   // Network buffer in milliseconds (using KB setting as seconds)
            
            //BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(flacBufferMS))        // User FLAC buffer
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(networkBufferMS))   // Network buffer in milliseconds
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(5))       // 75% pre-buffer (BASS default)
            //BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(50))    // Fast updates for stability
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_TIMEOUT), DWORD(120000))  // 2min timeout
            
            #if DEBUG
            os_log(.info, log: logger, "🎵 FLAC configured with user settings: %ds buffer, %ds network", settings.flacBufferSeconds, settings.networkBufferKB)
            #endif
            
        case "AAC", "MP3", "OGG":
            // Compressed formats that work well - smaller buffer for responsiveness
            //BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1500))         // 1.5s buffer
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(50000))     // 50s network buffer
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(15))       // 15% prebuf = 7.5s startup (faster than default)
            
            
            os_log(.info, log: logger, "🎵 Compressed format with reliable buffering: %{public}s (1.5s playback, 50s network)", format)
            
        case "OPUS":
            // Opus - larger network buffer for reliability  
            //BASS_SetConfig(DWORD(BASS_CONFIG_BUFFER), DWORD(1.5))         // 5s playback buffer
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_BUFFER), DWORD(50000))   // 50s
            //BASS_SetConfig(DWORD(BASS_CONFIG_NET_PREBUF), DWORD(15))       // 15% prebuf
            //BASS_SetConfig(DWORD(BASS_CONFIG_UPDATEPERIOD), DWORD(200))    // Moderate update rate
            
            
            #if DEBUG
            os_log(.info, log: logger, "🎵 Opus configured with reliable buffering: 5s playback, 120s network")
            #endif
            
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
        NotificationCenter.default.removeObserver(self)
        cleanup()
        BASS_Free()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}
