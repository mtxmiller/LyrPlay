// File: AudioPlayer.swift
// Updated to use CBass for superior FLAC support and native seeking
import Foundation
import Combine
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
    
    // MARK: - CBass Audio Engine
    private let cbassAudioPlayer: CBassAudioPlayer
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioPlayer")
    
    // MARK: - Legacy Compatibility Properties
    weak var delegate: AudioPlayerDelegate?
    weak var commandHandler: SlimProtoCommandHandler? {
        didSet {
            cbassAudioPlayer.commandHandler = commandHandler
        }
    }
    
    // MARK: - Published Properties (for SwiftUI compatibility)
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    // MARK: - Initialization
    override init() {
        cbassAudioPlayer = CBassAudioPlayer()
        super.init()
        
        // Set up delegation chain
        cbassAudioPlayer.delegate = self
        
        // Bind published properties to CBass player
        setupPropertyBinding()
        
        os_log(.info, log: logger, "AudioPlayer initialized with CBass audio engine")
    }
    
    // MARK: - Property Binding
    private func setupPropertyBinding() {
        // Observe CBass player's published properties and update our own
        cbassAudioPlayer.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPlaying)
        
        cbassAudioPlayer.$isPaused
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPaused)
        
        cbassAudioPlayer.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
        
        cbassAudioPlayer.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)
    }
    
    // MARK: - Stream Playback (Exact Interface Compatibility)
    func playStream(urlString: String) {
        os_log(.info, log: logger, "🎵 Playing stream via CBass: %{public}@", urlString)
        cbassAudioPlayer.playStream(urlString: urlString)
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        os_log(.info, log: logger, "🎵 Playing %{public}@ stream via CBass: %{public}@", format, urlString)
        cbassAudioPlayer.playStreamWithFormat(urlString: urlString, format: format)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        cbassAudioPlayer.playStreamAtPosition(urlString: urlString, startTime: startTime)
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        cbassAudioPlayer.playStreamAtPositionWithFormat(urlString: urlString, startTime: startTime, format: format)
    }
    
    // MARK: - Playback Control
    func play() {
        cbassAudioPlayer.play()
    }
    
    func pause() {
        cbassAudioPlayer.pause()
    }
    
    func stop() {
        cbassAudioPlayer.stop()
    }
    
    // MARK: - Time and State Access
    func getCurrentTime() -> Double {
        return cbassAudioPlayer.getCurrentTime()
    }
    
    func getDuration() -> Double {
        return cbassAudioPlayer.getDuration()
    }
    
    func getPosition() -> Float {
        return cbassAudioPlayer.getPosition()
    }
    
    func getPlayerState() -> String {
        return cbassAudioPlayer.getPlayerState()
    }
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        cbassAudioPlayer.setVolume(volume)
    }
    
    func getVolume() -> Float {
        return cbassAudioPlayer.getVolume()
    }
    
    // MARK: - Seeking (MAJOR IMPROVEMENT: Native FLAC seeking!)
    func seekToPosition(_ time: Double) {
        cbassAudioPlayer.seekToPosition(time)
    }
    
    // MARK: - Legacy Compatibility Methods
    func checkIfTrackEnded() -> Bool {
        return cbassAudioPlayer.checkIfTrackEnded()
    }
    
    // MARK: - Metadata Support
    func setMetadataDuration(_ duration: TimeInterval) {
        cbassAudioPlayer.setMetadataDuration(duration)
    }
    
    // MARK: - System Information (Enhanced with CBass)
    func getBassVersion() -> String {
        return cbassAudioPlayer.getBassVersion()
    }
    
    func getBassSystemInfo() -> [String: Any] {
        return cbassAudioPlayer.getBassSystemInfo()
    }
    
    func isEngineActive() -> Bool {
        return cbassAudioPlayer.isEngineActive()
    }
    
    // MARK: - Cleanup
    deinit {
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}

// MARK: - AudioPlayerDelegate Implementation (Bridge to External Delegate)
extension AudioPlayer: AudioPlayerDelegate {
    func audioPlayerDidStartPlaying() {
        delegate?.audioPlayerDidStartPlaying()
    }
    
    func audioPlayerDidPause() {
        delegate?.audioPlayerDidPause()
    }
    
    func audioPlayerDidStop() {
        delegate?.audioPlayerDidStop()
    }
    
    func audioPlayerDidReachEnd() {
        delegate?.audioPlayerDidReachEnd()
    }
    
    func audioPlayerTimeDidUpdate(_ time: Double) {
        delegate?.audioPlayerTimeDidUpdate(time)
    }
    
    func audioPlayerDidStall() {
        delegate?.audioPlayerDidStall()
    }
    
    func audioPlayerDidReceiveMetadataUpdate() {
        delegate?.audioPlayerDidReceiveMetadataUpdate()
    }
}