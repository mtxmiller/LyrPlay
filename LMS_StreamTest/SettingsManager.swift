// File: SettingsManager.swift
// UPDATED: Native FLAC support with StreamingKit
import Foundation
import Network
import os.log
import UIKit

class SettingsManager: ObservableObject {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SettingsManager")
    
    // MARK: - Published Properties
    @Published var serverHost: String = ""
    @Published var serverWebPort: Int = 9000
    @Published var serverSlimProtoPort: Int = 3483
    @Published var playerName: String = ""
    @Published var connectionTimeout: TimeInterval = 10.0
    @Published var preferredFormats: [String] = ["flac", "alc", "aac", "mp3"] // UPDATED: FLAC first
    @Published var bufferSize: Int = 2097152  // 2MB
    @Published var isDebugModeEnabled: Bool = false
    @Published var isConfigured: Bool = false
    @Published var showFallbackSettingsButton: Bool = true
    
    // MARK: - Read-only Properties
    private(set) var playerMACAddress: String = ""
    private(set) var deviceModel: String = "squeezelite"
    private(set) var deviceModelName: String = "LMS Stream for iOS"
    
    // MARK: - UserDefaults Keys
    private enum Keys {
        static let serverHost = "ServerHost"
        static let serverWebPort = "ServerWebPort"
        static let serverSlimProtoPort = "ServerSlimProtoPort"
        static let playerName = "PlayerName"
        static let playerMACAddress = "PlayerMACAddress"
        static let connectionTimeout = "ConnectionTimeout"
        static let preferredFormats = "PreferredFormats"
        static let bufferSize = "BufferSize"
        static let isDebugModeEnabled = "IsDebugModeEnabled"
        static let isConfigured = "IsConfigured"
        static let settingsVersion = "SettingsVersion"
        static let showFallbackSettingsButton = "ShowFallbackSettingsButton"
    }
    
    private let currentSettingsVersion = 2 // UPDATED: Increment for FLAC support
    
    // MARK: - Singleton
    static let shared = SettingsManager()
    
    private init() {
        loadSettings()
        if playerMACAddress.isEmpty {
            generateMACAddress()
        }
        if playerName.isEmpty {
            playerName = "iOS Player"
        }
        
        // UPDATED: Set FLAC-first priority order with StreamingKit
        UserDefaults.standard.set(["flac", "alc", "aac", "mp3"], forKey: Keys.preferredFormats)
        preferredFormats = ["flac", "alc", "aac", "mp3"]
        saveSettings()
    }
    
    // MARK: - Settings Persistence
    private func loadSettings() {
        os_log(.info, log: logger, "Loading settings from UserDefaults")
        
        migrateSettingsIfNeeded()
        
        serverHost = UserDefaults.standard.string(forKey: Keys.serverHost) ?? ""
        serverWebPort = UserDefaults.standard.object(forKey: Keys.serverWebPort) as? Int ?? 9000
        serverSlimProtoPort = UserDefaults.standard.object(forKey: Keys.serverSlimProtoPort) as? Int ?? 3483
        playerName = UserDefaults.standard.string(forKey: Keys.playerName) ?? ""
        playerMACAddress = UserDefaults.standard.string(forKey: Keys.playerMACAddress) ?? ""
        connectionTimeout = UserDefaults.standard.object(forKey: Keys.connectionTimeout) as? TimeInterval ?? 10.0
        preferredFormats = UserDefaults.standard.stringArray(forKey: Keys.preferredFormats) ?? ["flac", "alc", "aac", "mp3"]
        bufferSize = UserDefaults.standard.object(forKey: Keys.bufferSize) as? Int ?? 1048576
        isDebugModeEnabled = UserDefaults.standard.bool(forKey: Keys.isDebugModeEnabled)
        isConfigured = UserDefaults.standard.bool(forKey: Keys.isConfigured)
        showFallbackSettingsButton = UserDefaults.standard.object(forKey: Keys.showFallbackSettingsButton) as? Bool ?? true
        
        os_log(.info, log: logger, "Settings loaded - Host: %{public}s, Player: %{public}s, Configured: %{public}s",
               serverHost, playerName, isConfigured ? "YES" : "NO")
    }
    
    func saveSettings() {
        os_log(.info, log: logger, "Saving settings to UserDefaults")
        
        UserDefaults.standard.set(serverHost, forKey: Keys.serverHost)
        UserDefaults.standard.set(serverWebPort, forKey: Keys.serverWebPort)
        UserDefaults.standard.set(serverSlimProtoPort, forKey: Keys.serverSlimProtoPort)
        UserDefaults.standard.set(playerName, forKey: Keys.playerName)
        UserDefaults.standard.set(playerMACAddress, forKey: Keys.playerMACAddress)
        UserDefaults.standard.set(connectionTimeout, forKey: Keys.connectionTimeout)
        UserDefaults.standard.set(preferredFormats, forKey: Keys.preferredFormats)
        UserDefaults.standard.set(bufferSize, forKey: Keys.bufferSize)
        UserDefaults.standard.set(isDebugModeEnabled, forKey: Keys.isDebugModeEnabled)
        UserDefaults.standard.set(isConfigured, forKey: Keys.isConfigured)
        UserDefaults.standard.set(currentSettingsVersion, forKey: Keys.settingsVersion)
        UserDefaults.standard.set(showFallbackSettingsButton, forKey: Keys.showFallbackSettingsButton)
        
        UserDefaults.standard.synchronize()
        
        os_log(.info, log: logger, "Settings saved successfully")
    }
    
    private func migrateSettingsIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: Keys.settingsVersion)
        
        if savedVersion == 0 {
            os_log(.info, log: logger, "First launch or no previous settings version")
        } else if savedVersion < currentSettingsVersion {
            os_log(.info, log: logger, "Migrating settings from version %d to %d", savedVersion, currentSettingsVersion)
            
            // MIGRATION: Update format preferences to include FLAC first
            if savedVersion < 2 {
                os_log(.info, log: logger, "🎵 Migrating to FLAC-first format preferences")
                UserDefaults.standard.set(["flac", "alc", "aac", "mp3"], forKey: Keys.preferredFormats)
            }
        }
    }
    
    // MARK: - MAC Address Management
    private func generateMACAddress() {
        var macBytes: [UInt8] = []
        macBytes.append(0x02) // Locally administered
        
        for _ in 1..<6 {
            macBytes.append(UInt8.random(in: 0...255))
        }
        
        playerMACAddress = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        
        os_log(.info, log: logger, "Generated new MAC address: %{public}s", playerMACAddress)
        saveSettings()
    }
    
    func regenerateMACAddress() {
        os_log(.info, log: logger, "Regenerating MAC address (will create new player in LMS)")
        generateMACAddress()
    }
    
    // MARK: - Connection Testing
    enum ConnectionTestResult {
        case success
        case webPortFailure(String)
        case slimProtoPortFailure(String)
        case invalidHost(String)
        case timeout
        case networkError(String)
    }
    
    func testConnection() async -> ConnectionTestResult {
        os_log(.info, log: logger, "Testing connection to %{public}s", serverHost)
        
        guard !serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalidHost("Host address cannot be empty")
        }
        
        let cleanHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let webTestResult = await testHTTPConnection(host: cleanHost, port: serverWebPort)
        switch webTestResult {
        case .failure(let error):
            return .webPortFailure(error)
        case .success:
            break
        }
        
        let slimProtoTestResult = await testTCPConnection(host: cleanHost, port: serverSlimProtoPort)
        switch slimProtoTestResult {
        case .failure(let error):
            return .slimProtoPortFailure(error)
        case .success:
            break
        }
        
        os_log(.info, log: logger, "Connection test successful")
        return .success
    }
    
    private enum PortTestResult {
        case success
        case failure(String)
    }
    
    private func testHTTPConnection(host: String, port: Int) async -> PortTestResult {
        guard let url = URL(string: "http://\(host):\(port)/") else {
            return .failure("Invalid URL format")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = connectionTimeout
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode < 400 {
                    os_log(.info, log: logger, "HTTP test successful - Status: %d", httpResponse.statusCode)
                    return .success
                } else {
                    return .failure("HTTP Error \(httpResponse.statusCode)")
                }
            } else {
                return .failure("Invalid HTTP response")
            }
        } catch {
            os_log(.error, log: logger, "HTTP test failed: %{public}s", error.localizedDescription)
            return .failure("HTTP connection failed: \(error.localizedDescription)")
        }
    }
    
    private func testTCPConnection(host: String, port: Int) async -> PortTestResult {
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.lmsstream.connectiontest")
            
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            
            var hasResumed = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !hasResumed {
                        hasResumed = true
                        os_log(.info, log: self.logger, "TCP connection test successful")
                        connection.cancel()
                        continuation.resume(returning: .success)
                    }
                case .failed(let error):
                    if !hasResumed {
                        hasResumed = true
                        os_log(.error, log: self.logger, "TCP connection test failed: %{public}s", error.localizedDescription)
                        continuation.resume(returning: .failure("TCP connection failed: \(error.localizedDescription)"))
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
            
            queue.asyncAfter(deadline: .now() + connectionTimeout) {
                if !hasResumed {
                    hasResumed = true
                    connection.cancel()
                    continuation.resume(returning: .failure("Connection timeout"))
                }
            }
        }
    }
    
    // MARK: - Configuration Management
    func markAsConfigured() {
        isConfigured = true
        saveSettings()
        os_log(.info, log: logger, "App marked as configured")
    }
    
    func resetConfiguration() {
        os_log(.info, log: logger, "Resetting all configuration")
        
        serverHost = ""
        playerName = "iOS Player"
        isConfigured = false
        isDebugModeEnabled = false
        
        serverWebPort = 9000
        serverSlimProtoPort = 3483
        connectionTimeout = 10.0
        preferredFormats = ["flac", "alc", "aac", "mp3"] // UPDATED: FLAC first
        bufferSize = 262144
        
        saveSettings()
    }
    
    // MARK: - Validation
    func validateConfiguration() -> [String] {
        var errors: [String] = []
        
        if serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Server host is required")
        }
        
        if playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Player name is required")
        }
        
        if serverWebPort < 1 || serverWebPort > 65535 {
            errors.append("Web port must be between 1 and 65535")
        }
        
        if serverSlimProtoPort < 1 || serverSlimProtoPort > 65535 {
            errors.append("SlimProto port must be between 1 and 65535")
        }
        
        if connectionTimeout < 1 || connectionTimeout > 60 {
            errors.append("Connection timeout must be between 1 and 60 seconds")
        }
        
        return errors
    }
    
    // MARK: - Computed Properties
    var webURL: String {
        "http://\(serverHost):\(serverWebPort)/material/"
    }

    var initialWebURL: String {
        "http://\(serverHost):\(serverWebPort)/material/?player=\(playerMACAddress)"
    }
    
    var formattedMACAddress: String {
        playerMACAddress.uppercased()
    }
    
    // MARK: - UPDATED: Enhanced capabilities string with FLAC support
    var capabilitiesString: String {
        // Convert format names to proper SlimProto abbreviations
        let convertedFormats = preferredFormats.map { format in
            switch format.lowercased() {
            case "flac":
                return "flc"  // FLAC uses "flc" in SlimProto
            case "alac":
                return "alc"  // ALAC abbreviation
            default:
                return format // aac, mp3, etc. stay the same
            }
        }.joined(separator: ",")
        
        // UPDATED: Enhanced capabilities with FLAC support
        return "\(convertedFormats),Model=squeezelite,ModelName=LMS Stream for iOS,HasVolumeControl=0,HasDigitalVolumeControl=0,MaxSampleRate=48000"
    }

    var effectivePlayerName: String {
        if !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let deviceName = UIDevice.current.name
        let cleanName = deviceName
            .replacingOccurrences(of: "'s iPhone", with: "")
            .replacingOccurrences(of: "'s iPad", with: "")
            .replacingOccurrences(of: " iPhone", with: "")
            .replacingOccurrences(of: " iPad", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleanName.isEmpty ? "iOS Player" : cleanName
    }
}
