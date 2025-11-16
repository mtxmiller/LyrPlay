// File: SettingsViews.swift
import SwiftUI
import os.log
import WebKit
import UniformTypeIdentifiers


// MARK: - Main Settings View
struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @ObservedObject private var audioPlayer = AudioManager.shared.audioPlayer
    @EnvironmentObject private var coordinator: SlimProtoCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var showingConnectionTest = false
    @State private var showingResetAlert = false
    @State private var showingMACInfo = false
    //cache clear
    @State private var showingCacheClearAlert = false
    @State private var isClearingCache = false
    @State private var isReconnecting = false
    private var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Server Configuration Section
                Section(header: Text("Server Configuration")) {
                    NavigationLink(destination: ServerConfigView()) {
                        SettingsRow(
                            icon: "server.rack",
                            title: "Server Address",
                            value: settings.activeServerHost.isEmpty ? "Not Set" : settings.activeServerHost,
                            valueColor: settings.activeServerHost.isEmpty ? .red : .secondary
                        )
                    }
                    
                    NavigationLink(destination: ServerDiscoverySettingsView()) {
                        SettingsRow(
                            icon: "magnifyingglass",
                            title: "Discover Servers",
                            value: "Find LMS servers",
                            valueColor: .blue
                        )
                    }
                    
                    Button(action: { showingConnectionTest = true }) {
                        SettingsRow(
                            icon: "network",
                            title: "Test Connection",
                            value: "Tap to test",
                            valueColor: .blue
                        )
                    }
                    .foregroundColor(.primary)
                }
                
                // Backup Server Section
                Section(header: Text("Backup Server")) {
                    Toggle(isOn: $settings.isBackupServerEnabled) {
                        SettingsRow(
                            icon: "server.rack",
                            title: "Enable Backup Server",
                            value: settings.isBackupServerEnabled ? "Enabled" : "Disabled",
                            valueColor: settings.isBackupServerEnabled ? .green : .secondary
                        )
                    }
                    .onChange(of: settings.isBackupServerEnabled) { _ in
                        settings.saveSettings()
                    }
                    
                    if settings.isBackupServerEnabled {
                        NavigationLink(destination: BackupServerConfigView()) {
                            SettingsRow(
                                icon: "server.rack",
                                title: "Backup Server Address",
                                value: settings.backupServerHost.isEmpty ? "Not Set" : settings.backupServerHost,
                                valueColor: settings.backupServerHost.isEmpty ? .red : .secondary
                            )
                        }
                        
                        HStack {
                            SettingsRow(
                                icon: "switch.2",
                                title: "Active Server",
                                value: settings.currentActiveServer.displayName,
                                valueColor: .blue
                            )
                            
                            Spacer()
                            
                            Button("Switch") {
                                settings.switchToOtherServer()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.isBackupServerEnabled || settings.backupServerHost.isEmpty)
                        }
                    }
                }
                
                // Player Identity Section
                Section(header: Text("Player Identity")) {
                    NavigationLink(destination: PlayerConfigView()) {
                        SettingsRow(
                            icon: "hifispeaker",
                            title: "Player Name",
                            value: settings.playerName.isEmpty ? "Not Set" : settings.playerName,
                            valueColor: settings.playerName.isEmpty ? .red : .secondary
                        )
                    }
                    
                    Button(action: { showingMACInfo = true }) {
                        SettingsRow(
                            icon: "barcode",
                            title: "Player ID",
                            value: settings.formattedMACAddress,
                            valueColor: .secondary
                        )
                    }
                    .foregroundColor(.primary)
                }
                
                // Audio Settings Section
                Section(header: Text("Audio Settings")) {
                    // Audio Format Picker
                    NavigationLink(destination: AudioFormatConfigView()) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "music.note")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Audio Format")
                                        .font(.body)
                                    Text(settings.audioFormat.displayName)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }

                                Spacer()

                                if isReconnecting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }

                            Text(settings.audioFormat.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.leading, 28)
                        }
                    }
                    .disabled(isReconnecting)
                    .padding(.vertical, 2)
                }

                // Current Playback Info Section
                if let streamInfo = audioPlayer.currentStreamInfo {
                    Section(header: Text("Current Playback")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundColor(.green)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Stream Information")
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Text(streamInfo.displayString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Detailed breakdown
                            HStack(spacing: 16) {
                                DetailItem(label: "Format", value: streamInfo.format)
                                DetailItem(label: "Sample Rate", value: "\(streamInfo.sampleRate/1000)kHz")
                            }

                            HStack(spacing: 16) {
                                DetailItem(label: "Bit Depth", value: "\(streamInfo.bitDepth)-bit")
                                DetailItem(label: "Channels", value: streamInfo.channels == 1 ? "Mono" : streamInfo.channels == 2 ? "Stereo" : "\(streamInfo.channels)ch")
                            }

                            if streamInfo.bitrate > 0 {
                                HStack(spacing: 16) {
                                    DetailItem(label: "Bitrate", value: "\(Int(streamInfo.bitrate)) kbps")
                                    Spacer()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Playback Settings Section
                Section(header: Text("Playback Settings")) {
                    Toggle(isOn: $settings.enableAppOpenRecovery) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.green)
                                    .frame(width: 20)
                                Text("Resume Position on App Open")
                                    .font(.body)
                            }
                            Text("Automatically restore playback position when returning to app after 45+ seconds in background")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 28)
                        }
                    }
                    .onChange(of: settings.enableAppOpenRecovery) { _ in
                        settings.saveSettings()
                    }
                    .padding(.vertical, 4)
                }

                // Advanced Section
                Section(header: Text("Advanced")) {
                    NavigationLink(destination: AdvancedConfigView()) {
                        SettingsRow(
                            icon: "gearshape.2",
                            title: "Advanced Settings",
                            value: "Ports, Timeouts",
                            valueColor: .secondary
                        )
                    }
                    
                    
                    Button(action: { showingCacheClearAlert = true }) {
                        SettingsRow(
                            icon: "trash.slash",
                            title: "Clear Material Cache",
                            value: isClearingCache ? "Clearing..." : "Tap to clear",
                            valueColor: isClearingCache ? .orange : .blue
                        )
                    }
                    .foregroundColor(.primary)
                    .disabled(isClearingCache)
                    
                }
                
                // Reset Section
                Section(header: Text("Reset")) {
                    Button(action: { showingResetAlert = true }) {
                        SettingsRow(
                            icon: "arrow.clockwise",
                            title: "Reset All Settings",
                            value: "Start over",
                            valueColor: .red
                        )
                    }
                    .foregroundColor(.red)
                }

                Section(header: Text("About")) {
                    SettingsRow(
                        icon: "info.circle",
                        title: "Version",
                        value: appVersionDisplay,
                        valueColor: .secondary
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingConnectionTest) {
            ConnectionTestSheet()
        }
        .sheet(isPresented: $showingMACInfo) {
            MACInfoSheet()
        }
        .alert("Reset All Settings?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settings.resetConfiguration()
            }
        } message: {
            Text("This will reset all settings to defaults and mark the app as unconfigured. You'll need to go through setup again.")
        }
        .alert("Clear Material Cache?", isPresented: $showingCacheClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Cache") {
                clearMaterialCache()
            }
        } message: {
            Text("This will clear Material's web cache and reload the interface. This often fixes UI display issues.")
        }
    }
    
    // REMOVED: formatsSummary - no longer used since capabilities are hardcoded
    
    private func clearMaterialCache() {
        print("🗑️ Starting cache clear...")
        isClearingCache = true
        
        let websiteDataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let date = Date(timeIntervalSince1970: 0)
        
        WKWebsiteDataStore.default().removeData(ofTypes: websiteDataTypes, modifiedSince: date) {
            DispatchQueue.main.async {
                print("🗑️ Cache cleared, setting reload trigger...")
                self.isClearingCache = false
                
                // Trigger WebView reload
                self.settings.shouldReloadWebView = true
                print("🗑️ shouldReloadWebView set to true")
                
                // Dismiss settings - WebView will reload when we return
                self.presentationMode.wrappedValue.dismiss()
            }
        }
    }
}

// MARK: - Settings Row Component
struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let valueColor: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 25)
            
            Text(title)
                .foregroundColor(.primary)
            
            Spacer()
            
            Text(value)
                .foregroundColor(valueColor)
                .font(.caption)
        }
    }
}

// MARK: - Server Configuration View
struct ServerConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var serverHost: String = ""
    @State private var validationErrors: [String] = []
    @State private var showingConnectionTest = false
    @State private var hasChanges = false
    
    var body: some View {
        Form {
            Section(header: Text("Server Address")) {
                TextField("192.168.1.100 or myserver.local", text: $serverHost)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: serverHost) { _ in hasChanges = true }
                
                Text("Enter the IP address or hostname of your LMS server. You can find this in your LMS web interface under Settings → Network.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !validationErrors.isEmpty {
                Section(header: Text("Validation Errors")) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            
            Section {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Server Config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveSettings()
                }
                .disabled(!hasChanges || !validationErrors.isEmpty)
            }
        }
        .onAppear {
            serverHost = settings.activeServerHost
        }
        .sheet(isPresented: $showingConnectionTest) {
            ConnectionTestSheet()
        }
    }
    
    private func testConnection() {
        // Temporarily save the host for testing
        let originalHost = settings.serverHost
        settings.serverHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        
        showingConnectionTest = true
        
        // Restore original if test is cancelled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if !showingConnectionTest {
                settings.serverHost = originalHost
            }
        }
    }
    
    private func saveSettings() {
        validateAndSave()
    }
    
    private func validateAndSave() {
        validationErrors.removeAll()

        let trimmedHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedHost.isEmpty {
            validationErrors.append("Server address is required")
            return
        }

        // Save to the correct server based on which is currently active
        if settings.currentActiveServer == .primary {
            settings.serverHost = trimmedHost
        } else {
            settings.backupServerHost = trimmedHost
        }

        settings.saveSettings()
        hasChanges = false

        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Player Configuration View
struct PlayerConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var playerName: String = ""
    @State private var hasChanges = false
    @State private var showingMACInfo = false
    
    var body: some View {
        Form {
            Section(header: Text("Player Name")) {
                TextField("Enter player name", text: $playerName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onChange(of: playerName) { _ in hasChanges = true }
                
                Text("This name will appear in your LMS interface to identify this device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Player ID")) {
                HStack {
                    Text("Current ID:")
                    Spacer()
                    Text(settings.formattedMACAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Button("Player ID Information") {
                    showingMACInfo = true
                }
                .foregroundColor(.blue)
            }
        }
        .navigationTitle("Player Config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveSettings()
                }
                .disabled(!hasChanges)
            }
        }
        .onAppear {
            playerName = settings.playerName
        }
        .sheet(isPresented: $showingMACInfo) {
            MACInfoSheet()
        }
    }
    
    private func saveSettings() {
        settings.playerName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.saveSettings()
        hasChanges = false
        
        presentationMode.wrappedValue.dismiss()
    }
}

// REMOVED: Legacy AudioConfigView - capabilities are now hardcoded in SlimProtoClient

// MARK: - Advanced Configuration View
struct AdvancedConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var webPort: String = "9000"
    @State private var slimProtoPort: String = "3483"
    @State private var connectionTimeout: Double = 10.0
    @State private var hasChanges = false
    @State private var validationErrors: [String] = []
    
    var body: some View {
        Form {
            Section(header: Text("Port Configuration")) {
                HStack {
                    Text("Web Port:")
                    Spacer()
                    TextField("9000", text: $webPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .onChange(of: webPort) { _ in hasChanges = true }
                }
                
                HStack {
                    Text("Stream Port:")
                    Spacer()
                    TextField("3483", text: $slimProtoPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .onChange(of: slimProtoPort) { _ in hasChanges = true }
                }
                
                Text("Only change these if your LMS server uses non-standard ports.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Connection Settings")) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Connection Timeout:")
                        Spacer()
                        Text("\(Int(connectionTimeout))s")
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(
                        value: $connectionTimeout,
                        in: 5...30,
                        step: 5
                    ) {
                        Text("Timeout")
                    }
                    .onChange(of: connectionTimeout) { _ in hasChanges = true }
                }
                
                Text("How long to wait when testing connections. Increase for slower networks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !validationErrors.isEmpty {
                Section(header: Text("Validation Errors")) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveSettings()
                }
                .disabled(!hasChanges)
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
    }
    
    private func loadCurrentSettings() {
        webPort = String(settings.activeServerWebPort)
        slimProtoPort = String(settings.activeServerSlimProtoPort)
        connectionTimeout = settings.connectionTimeout
    }
    
    private func saveSettings() {
        validationErrors.removeAll()
        
        guard let webPortInt = Int(webPort), webPortInt > 0, webPortInt < 65536 else {
            validationErrors.append("Web port must be between 1 and 65535")
            return
        }
        
        guard let slimPortInt = Int(slimProtoPort), slimPortInt > 0, slimPortInt < 65536 else {
            validationErrors.append("Stream port must be between 1 and 65535")
            return
        }
        
        if webPortInt == slimPortInt {
            validationErrors.append("Web port and stream port cannot be the same")
            return
        }
        
        settings.serverWebPort = webPortInt
        settings.serverSlimProtoPort = slimPortInt
        settings.connectionTimeout = connectionTimeout
        settings.saveSettings()
        hasChanges = false
        
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Connection Test Sheet
struct ConnectionTestSheet: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var testState: TestState = .idle
    @State private var testResult: SettingsManager.ConnectionTestResult?
    @State private var testDetails: [ConnectionTestView.TestDetail] = []
    
    enum TestState {
        case idle
        case testing
        case completed
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                VStack(spacing: 16) {
                    Image(systemName: iconForState)
                        .font(.largeTitle)
                        .foregroundColor(colorForState)
                    
                    Text(titleForState)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Server: \(settings.activeServerHost)")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)
                
                if !testDetails.isEmpty {
                    VStack(spacing: 16) {
                        ForEach(testDetails.indices, id: \.self) { index in
                            TestDetailRow(detail: testDetails[index])
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                
                if testState == .testing {
                    ProgressView("Testing connection...")
                        .progressViewStyle(CircularProgressViewStyle())
                }
                
                if testState == .completed {
                    if let result = testResult {
                        Text(messageForResult(result))
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    if testState == .idle || testState == .completed {
                        Button("Test Connection") {
                            runConnectionTest()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal)
            .navigationTitle("Connection Test")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .onAppear {
            if testState == .idle {
                runConnectionTest()
            }
        }
    }
    
    private var iconForState: String {
        switch testState {
        case .idle:
            return "network"
        case .testing:
            return "network"
        case .completed:
            if case .success = testResult {
                return "checkmark.circle.fill"
            } else {
                return "xmark.circle.fill"
            }
        }
    }
    
    private var colorForState: Color {
        switch testState {
        case .idle, .testing:
            return .blue
        case .completed:
            if case .success = testResult {
                return .green
            } else {
                return .red
            }
        }
    }
    
    private var titleForState: String {
        switch testState {
        case .idle:
            return "Ready to Test"
        case .testing:
            return "Testing Connection"
        case .completed:
            if case .success = testResult {
                return "Connection Successful"
            } else {
                return "Connection Failed"
            }
        }
    }
    
    private func runConnectionTest() {
        testState = .testing
        testDetails = [
            ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .testing, message: "Testing..."),
            ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .testing, message: "Testing...")
        ]
        
        Task {
            let result = await settings.testConnection()
            
            await MainActor.run {
                testResult = result
                updateTestDetails(for: result)
                testState = .completed
            }
        }
    }
    
    private func updateTestDetails(for result: SettingsManager.ConnectionTestResult) {
        switch result {
        case .success:
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .success, message: "Connected"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .success, message: "Connected")
            ]
            
        case .webPortFailure(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: error),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .testing, message: "Skipped")
            ]
            
        case .slimProtoPortFailure(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .success, message: "Connected"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: error)
            ]
            
        case .invalidHost(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: error),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: error)
            ]
            
        default:
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: "Failed"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: "Failed")
            ]
        }
    }
    
    private func messageForResult(_ result: SettingsManager.ConnectionTestResult) -> String {
        switch result {
        case .success:
            return "All connections successful! Your LMS server is reachable and ready for streaming."
        case .webPortFailure:
            return "Cannot connect to LMS web interface. Check if LMS is running and the address is correct."
        case .slimProtoPortFailure:
            return "Web interface is accessible but streaming protocol failed. Check if SlimProto is enabled in LMS."
        case .invalidHost:
            return "Invalid server address. Please check the hostname or IP address."
        case .timeout:
            return "Connection timed out. Check your network connection and server address."
        case .networkError(let error):
            return "Network error: \(error)"
        }
    }
}

// MARK: - Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

// MARK: - Backup Server Configuration View
struct BackupServerConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var backupHost: String = ""
    @State private var backupWebPort: String = "9000"
    @State private var backupSlimPort: String = "3483"
    @State private var hasChanges = false
    @State private var validationErrors: [String] = []
    
    var body: some View {
        Form {
            Section(header: Text("Backup Server Address")) {
                TextField("192.168.1.101 or backup.local", text: $backupHost)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: backupHost) { _ in hasChanges = true }
                
                Text("Enter the IP address or hostname of your backup LMS server.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Backup Server Ports")) {
                HStack {
                    Text("Web Port:")
                    Spacer()
                    TextField("9000", text: $backupWebPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .onChange(of: backupWebPort) { _ in hasChanges = true }
                }
                
                HStack {
                    Text("Stream Port:")
                    Spacer()
                    TextField("3483", text: $backupSlimPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .onChange(of: backupSlimPort) { _ in hasChanges = true }
                }
            }
            
            if !validationErrors.isEmpty {
                Section(header: Text("Validation Errors")) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Backup Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveSettings()
                }
                .disabled(!hasChanges)
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
    }
    
    private func loadCurrentSettings() {
        backupHost = settings.backupServerHost
        backupWebPort = String(settings.backupServerWebPort)
        backupSlimPort = String(settings.backupServerSlimProtoPort)
    }
    
    private func saveSettings() {
        validationErrors.removeAll()
        
        let trimmedHost = backupHost.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedHost.isEmpty {
            validationErrors.append("Backup server address is required")
            return
        }
        
        guard let webPortInt = Int(backupWebPort), webPortInt > 0, webPortInt < 65536 else {
            validationErrors.append("Web port must be between 1 and 65535")
            return
        }
        
        guard let slimPortInt = Int(backupSlimPort), slimPortInt > 0, slimPortInt < 65536 else {
            validationErrors.append("Stream port must be between 1 and 65535")
            return
        }
        
        settings.backupServerHost = trimmedHost
        settings.backupServerWebPort = webPortInt
        settings.backupServerSlimProtoPort = slimPortInt
        settings.saveSettings()
        hasChanges = false
        
        presentationMode.wrappedValue.dismiss()
    }
}



// MARK: - Server Discovery Settings View
struct ServerDiscoverySettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var discoveryManager = ServerDiscoveryManager()
    @Environment(\.presentationMode) var presentationMode
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Title and description
                VStack(spacing: 16) {
                    Text("Discover LMS Servers")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Search for Lyrion Music Servers on your local network using UDP broadcast discovery.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)
                
                // Discovery button
                Button(action: startDiscovery) {
                    HStack {
                        if discoveryManager.isDiscovering {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("Searching...")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("Find Servers")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(discoveryManager.isDiscovering)
                .padding(.horizontal)
                
                // Discovered servers
                if !discoveryManager.discoveredServers.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Found Servers")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        ForEach(discoveryManager.discoveredServers) { server in
                            ServerDiscoveryRow(server: server) {
                                selectServer(server)
                            }
                        }
                    }
                    .padding(.top)
                }
                
                if discoveryManager.discoveredServers.isEmpty && !discoveryManager.isDiscovering {
                    Text("No servers found. Make sure your LMS server is running and on the same network.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .navigationTitle("Server Discovery")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .alert("Server Selected", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            startDiscovery()
        }
        .onDisappear {
            discoveryManager.stopDiscovery()
        }
    }
    
    private func startDiscovery() {
        discoveryManager.startDiscovery()
    }
    
    private func selectServer(_ server: DiscoveredServer) {
        // Validate server first
        discoveryManager.validateServer(server) { isValid in
            if isValid {
                // Save to settings
                settings.serverHost = server.host
                settings.serverWebPort = server.port
                settings.serverSlimProtoPort = 3483
                settings.saveSettings()
                
                alertMessage = "Server '\(server.name)' at \(server.host) has been selected and saved to your settings."
                showingAlert = true
                
                // Auto-dismiss after selection
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    presentationMode.wrappedValue.dismiss()
                }
            } else {
                alertMessage = "Unable to connect to server '\(server.name)' at \(server.host). Please try another server."
                showingAlert = true
            }
        }
    }
}

// MARK: - Server Discovery Row
struct ServerDiscoveryRow: View {
    let server: DiscoveredServer
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("\(server.host):\(server.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.blue)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal)
    }
}

// MARK: - Audio Format Configuration View
struct AudioFormatConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @EnvironmentObject private var coordinator: SlimProtoCoordinator
    @Environment(\.presentationMode) var presentationMode
    @State private var isReconnecting = false
    
    var body: some View {
        Form {
            Section(header: Text("Audio Format Selection"), 
                   footer: Text("Changes require reconnection to take effect. Higher quality formats may use more bandwidth.")) {
                
                ForEach(SettingsManager.AudioFormat.allCases, id: \.self) { format in
                    Button(action: {
                        selectFormat(format)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(format.displayName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    
                                    if settings.audioFormat == format {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                                
                                Text(format.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            
                            if settings.audioFormat != format {
                                Spacer()
                            }
                        }
                    }
                    .disabled(isReconnecting)
                    .buttonStyle(PlainButtonStyle())
                }
            }

            Section(header: Text("Server Setup")) {
                // Easy Setup: MobileTranscode Plugin
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(.orange)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Easy Setup: MobileTranscode Plugin")
                                .font(.body)
                                .fontWeight(.semibold)

                            Text("Install from: Server Settings → Manage Plugins → 3rd Party → MobileTranscode Plugin")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Automatically configures FLAC, Opus & OGG Vorbis")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Note: Opus format requires opus-tools installed on your server")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(.vertical, 4)

                // Manual setup fallback
                Link(destination: URL(string: "https://github.com/mtxmiller/LyrPlay")!) {
                    HStack {
                        Image(systemName: "book")
                            .foregroundColor(.blue)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manual Setup Instructions")
                                .font(.body)
                                .foregroundColor(.blue)

                            Text("Advanced: Configure transcoding manually")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.top, 4)
            }
            
            if isReconnecting {
                Section {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Reconnecting with new format...")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Audio Format")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func selectFormat(_ format: SettingsManager.AudioFormat) {
        guard settings.audioFormat != format else { return }
        
        settings.audioFormat = format
        settings.saveSettings()
        
        // Restart connection if currently connected
        if coordinator.connectionState == "Connected" {
            Task {
                await MainActor.run {
                    isReconnecting = true
                }
                
                await coordinator.restartConnection()
                
                await MainActor.run {
                    isReconnecting = false
                }
            }
        }
    }
}

// MARK: - Format Requirement Row (Legacy - kept for compatibility)
struct FormatRequirementRow: View {
    let format: String
    let requirement: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(format)
                    .font(.body)
                    .fontWeight(.medium)

                Text(requirement)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Format Requirement Simple (No status indicators)
struct FormatRequirementSimple: View {
    let format: String
    let requirement: String

    var body: some View {
        HStack(spacing: 8) {
            Text("•")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(format)
                    .font(.body)
                    .fontWeight(.medium)

                Text(requirement)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - Detail Item (for stream info display)
struct DetailItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
