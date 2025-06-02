// File: SettingsViews.swift
import SwiftUI
import os.log

// MARK: - Main Settings View
struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    @State private var showingConnectionTest = false
    @State private var showingResetAlert = false
    @State private var showingMACInfo = false
    
    var body: some View {
        NavigationView {
            Form {
                // Server Configuration Section
                Section(header: Text("Server Configuration")) {
                    NavigationLink(destination: ServerConfigView()) {
                        SettingsRow(
                            icon: "server.rack",
                            title: "Server Address",
                            value: settings.serverHost.isEmpty ? "Not Set" : settings.serverHost,
                            valueColor: settings.serverHost.isEmpty ? .red : .secondary
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
                    NavigationLink(destination: AudioConfigView()) {
                        SettingsRow(
                            icon: "waveform",
                            title: "Audio Formats",
                            value: formatsSummary,
                            valueColor: .secondary
                        )
                    }
                    
                    NavigationLink(destination: BufferConfigView()) {
                        SettingsRow(
                            icon: "memorychip",
                            title: "Buffer Settings",
                            value: bufferSummary,
                            valueColor: .secondary
                        )
                    }
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
                    
                    Toggle(isOn: $settings.isDebugModeEnabled) {
                        SettingsRow(
                            icon: "ant",
                            title: "Debug Mode",
                            value: settings.isDebugModeEnabled ? "Enabled" : "Disabled",
                            valueColor: settings.isDebugModeEnabled ? .green : .secondary
                        )
                    }
                    .onChange(of: settings.isDebugModeEnabled) { _ in
                        settings.saveSettings()
                    }
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
    }
    
    private var formatsSummary: String {
        let formats = settings.preferredFormats.prefix(2).joined(separator: ", ")
        return formats.uppercased()
    }
    
    private var bufferSummary: String {
        let bufferKB = settings.bufferSize / 1024
        return "\(bufferKB)KB"
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
            serverHost = settings.serverHost
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
        
        settings.serverHost = trimmedHost
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

// MARK: - Audio Configuration View
struct AudioConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var preferredFormats: [String] = []
    @State private var hasChanges = false
    
    private let availableFormats = [
        ("aac", "AAC", "Advanced Audio Coding - Best for streaming"),
        ("alac", "ALAC", "Apple Lossless - CD quality, larger files"),
        ("mp3", "MP3", "MPEG Audio - Universal compatibility"),
        ("flac", "FLAC", "Free Lossless - High quality, transcoded on iOS")
    ]
    
    var body: some View {
        Form {
            Section(header: Text("Format Preferences")) {
                Text("Drag to reorder formats by preference. The app will request formats in this order from your LMS server.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(preferredFormats.indices, id: \.self) { index in
                    if let format = availableFormats.first(where: { $0.0 == preferredFormats[index] }) {
                        FormatRow(
                            format: format,
                            position: index + 1,
                            isSelected: true
                        )
                    }
                }
                .onMove(perform: moveFormats)
            }
            
            Section(header: Text("Available Formats")) {
                ForEach(availableFormats.filter { !preferredFormats.contains($0.0) }, id: \.0) { format in
                    Button(action: { addFormat(format.0) }) {
                        FormatRow(format: format, position: nil, isSelected: false)
                    }
                    .foregroundColor(.primary)
                }
            }
        }
        .navigationTitle("Audio Formats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    saveSettings()
                }
                .disabled(!hasChanges)
            }
        }
        .onAppear {
            preferredFormats = settings.preferredFormats
        }
    }
    
    private func moveFormats(from source: IndexSet, to destination: Int) {
        preferredFormats.move(fromOffsets: source, toOffset: destination)
        hasChanges = true
    }
    
    private func addFormat(_ format: String) {
        preferredFormats.append(format)
        hasChanges = true
    }
    
    private func saveSettings() {
        settings.preferredFormats = preferredFormats
        settings.saveSettings()
        hasChanges = false
        
        presentationMode.wrappedValue.dismiss()
    }
}

struct FormatRow: View {
    let format: (String, String, String)
    let position: Int?
    let isSelected: Bool
    
    var body: some View {
        HStack {
            if let pos = position {
                Text("\(pos)")
                    .font(.caption)
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.blue)
                    .clipShape(Circle())
            } else {
                Image(systemName: "plus.circle")
                    .foregroundColor(.green)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(format.1)
                    .font(.headline)
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Text(format.2)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Buffer Configuration View
struct BufferConfigView: View {
    @StateObject private var settings = SettingsManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var bufferSize: Double = 262144
    @State private var hasChanges = false
    
    private let bufferSizes: [(Int, String)] = [
        (131072, "128 KB - Minimal"),
        (262144, "256 KB - Default"),
        (524288, "512 KB - Large"),
        (1048576, "1 MB - Maximum")
    ]
    
    var body: some View {
        Form {
            Section(header: Text("Buffer Size")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Current: \(Int(bufferSize / 1024)) KB")
                        .font(.headline)
                    
                    Slider(
                        value: $bufferSize,
                        in: 131072...1048576,
                        step: 131072
                    ) {
                        Text("Buffer Size")
                    }
                    .onChange(of: bufferSize) { _ in hasChanges = true }
                }
                
                Text("Larger buffers provide more stable playback but use more memory. The default 256KB works well for most connections.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Presets")) {
                ForEach(bufferSizes, id: \.0) { size, description in
                    Button(action: {
                        bufferSize = Double(size)
                        hasChanges = true
                    }) {
                        HStack {
                            Text(description)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            if Int(bufferSize) == size {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Buffer Settings")
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
            bufferSize = Double(settings.bufferSize)
        }
    }
    
    private func saveSettings() {
        settings.bufferSize = Int(bufferSize)
        settings.saveSettings()
        hasChanges = false
        
        presentationMode.wrappedValue.dismiss()
    }
}

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
            
            Section(header: Text("Device Information")) {
                HStack {
                    Text("Model:")
                    Spacer()
                    Text(settings.deviceModel)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Model Name:")
                    Spacer()
                    Text(settings.deviceModelName)
                        .foregroundColor(.secondary)
                }
                
                Text("This information is sent to LMS to identify your device type.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        webPort = String(settings.serverWebPort)
        slimProtoPort = String(settings.serverSlimProtoPort)
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
                    
                    Text("Server: \(settings.serverHost)")
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
            ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .testing, message: "Testing..."),
            ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .testing, message: "Testing...")
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
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .success, message: "Connected"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .success, message: "Connected")
            ]
            
        case .webPortFailure(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: error),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .testing, message: "Skipped")
            ]
            
        case .slimProtoPortFailure(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .success, message: "Connected"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: error)
            ]
            
        case .invalidHost(let error):
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: error),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: error)
            ]
            
        default:
            testDetails = [
                ConnectionTestView.TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: "Failed"),
                ConnectionTestView.TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: "Failed")
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
