// File: OnboardingViews.swift
import SwiftUI
import os.log
import Network


// MARK: - Main Onboarding Container
struct OnboardingFlow: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var currentStep: OnboardingStep = .welcome
    @State private var isAnimating = false

    
    enum OnboardingStep: CaseIterable {
        case welcome
        case serverSetup
        case connectionTest
        case playerSetup
        case complete
        
        var title: String {
            switch self {
            case .welcome: return "Welcome to SlimAMP"
            case .serverSetup: return "Server Setup"
            case .connectionTest: return "Testing Connection"
            case .playerSetup: return "Player Setup"
            case .complete: return "Setup Complete"
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack {
                    // Progress indicator
                    OnboardingProgressView(currentStep: currentStep)
                        .padding(.top)
                    
                    // Current step content
                    Group {
                        switch currentStep {
                        case .welcome:
                            WelcomeView(onNext: { moveToStep(.serverSetup) })
                        case .serverSetup:
                            ServerSetupView(
                                onNext: { moveToStep(.connectionTest) },
                                onBack: { moveToStep(.welcome) }
                            )
                        case .connectionTest:
                            ConnectionTestView(
                                onSuccess: { moveToStep(.playerSetup) },
                                onRetry: { moveToStep(.serverSetup) }
                            )
                        case .playerSetup:
                            PlayerSetupView(
                                onNext: { moveToStep(.complete) },
                                onBack: { moveToStep(.serverSetup) }
                            )
                        case .complete:
                            SetupCompleteView()
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func moveToStep(_ step: OnboardingStep) {
        withAnimation {
            currentStep = step
        }
    }
}

// MARK: - Progress Indicator
struct OnboardingProgressView: View {
    let currentStep: OnboardingFlow.OnboardingStep
    
    private var progress: Float {
        let steps = OnboardingFlow.OnboardingStep.allCases
        guard let currentIndex = steps.firstIndex(of: currentStep) else { return 0 }
        return Float(currentIndex) / Float(steps.count - 1)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text(currentStep.title)
                .font(.headline)
                .foregroundColor(.white)
            
            ProgressView(value: progress)
                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                .frame(height: 4)
        }
        .padding(.horizontal)
    }
}

// MARK: - Welcome View
struct WelcomeView: View {
    let onNext: () -> Void
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Group {
                if let uiImage = UIImage(named: "iconm") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                } else {
                    // Shows this if image file can't be found
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text("Icon file not found")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            
            VStack(spacing: 30) {
                Text("SlimAMP")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Connect to your Lyrion Music Server and enjoy high-quality streaming on your iOS device.")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 40) {
                FeatureRow(icon: "wifi", title: "Stream from LMS", description: "Connect to your music server")
                FeatureRow(icon: "speaker.wave.3", title: "High Quality Audio", description: "FLAC, AAC, and MP3 support")
                FeatureRow(icon: "lock.shield", title: "Background Playback", description: "Control from lock screen")
            }
            
            Spacer()
            
            Button("Get Started") {
                onNext()
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .onAppear {
            isAnimating = true
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

struct DiscoveredServer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    
    var displayName: String {
        return "\(name) (\(host))"
    }
}

// MARK: - Server Setup View
struct ServerSetupView: View {
    @StateObject private var settings = SettingsManager.shared
    let onNext: () -> Void
    let onBack: () -> Void
    
    @State private var serverHost = ""
    @State private var webPort = "9000"
    @State private var slimProtoPort = "3483"
    @State private var validationErrors: [String] = []
    @State private var isDiscovering = false
    @State private var discoveredServers: [DiscoveredServer] = []
    @State private var hasChanges = false
    
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Discovery button section
                VStack(spacing: 12) {
                    Button(action: { startServerDiscovery() }) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text(isDiscovering ? "Discovering..." : "Find LMS Servers")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isDiscovering)
                }

                // Discovered servers section
                if !discoveredServers.isEmpty {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Discovered Servers")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            if isDiscovering {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                            }
                        }
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(discoveredServers) { server in
                                Button(server.displayName) {
                                    serverHost = server.host
                                    webPort = String(server.port)
                                    hasChanges = true
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .lineLimit(2)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top)
                }
                
                VStack(spacing: 20) {
                    FormField(
                        title: "Server Address",
                        placeholder: "192.168.1.100 or myserver.local",
                        text: $serverHost,
                        keyboardType: .URL
                    )
                    
                    HStack(spacing: 16) {
                        FormField(
                            title: "Web Port",
                            placeholder: "9000",
                            text: $webPort,
                            keyboardType: .numberPad
                        )
                        
                        FormField(
                            title: "Stream Port",
                            placeholder: "3483",
                            text: $slimProtoPort,
                            keyboardType: .numberPad
                        )
                    }
                }
                
                if !validationErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(validationErrors, id: \.self) { error in
                            HStack {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                
                VStack(spacing: 12) {
                    Text("Common LMS Addresses")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(commonAddresses, id: \.self) { address in
                            Button(address) {
                                serverHost = address
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .padding(.top)
                
                Spacer(minLength: 40)
                
                HStack(spacing: 16) {
                    Button("Back") {
                        onBack()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    Button("Test Connection") {
                        validateAndProceed()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(serverHost.isEmpty)
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal)
        }
        .onAppear {
            loadCurrentSettings()
            
            // Auto-start discovery after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                startServerDiscovery()
            }
        }
    }
    
    private func startServerDiscovery() {
        guard !isDiscovering else { return }
        
        isDiscovering = true
        discoveredServers.removeAll()
        
        // Start discovery on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            discoverLMSServers()
        }
    }

    private func discoverLMSServers() {
        let semaphore = DispatchSemaphore(value: 0)
        var foundServers: [DiscoveredServer] = []
        
        // Get current network info
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "network.discovery")
        
        monitor.pathUpdateHandler = { path in
            defer { semaphore.signal() }
            
            guard path.status == .satisfied else { return }
            
            // Try common LMS ports and hostnames
            let commonHosts = [
                "lms.local", "squeezebox.local", "logitechmediaserver.local",
                "slimserver.local", "musicserver.local"
            ]
            
            // Also try local network scanning for common addresses
            let baseAddresses = [
                "192.168.1.", "192.168.0.", "10.0.0.", "172.16.0."
            ]
            
            let group = DispatchGroup()
            
            // Check common hostnames first
            for host in commonHosts {
                group.enter()
                checkLMSServer(host: host, port: 9000) { server in
                    if let server = server {
                        foundServers.append(server)
                    }
                    group.leave()
                }
            }
            
            // Quick scan of common IP ranges (first 10 addresses only to avoid spam)
            for baseAddr in baseAddresses {
                for i in 1...10 {
                    let host = "\(baseAddr)\(i)"
                    group.enter()
                    checkLMSServer(host: host, port: 9000) { server in
                        if let server = server {
                            foundServers.append(server)
                        }
                        group.leave()
                    }
                }
            }
            
            // Wait for all checks to complete (max 10 seconds)
            _ = group.wait(timeout: .now() + 10)
        }
        
        monitor.start(queue: queue)
        
        // Wait for network check
        _ = semaphore.wait(timeout: .now() + 15)
        monitor.cancel()
        
        // Update UI on main thread
        DispatchQueue.main.async {
            self.discoveredServers = Array(Set(foundServers)).sorted { $0.name < $1.name }
            self.isDiscovering = false
            
            if foundServers.isEmpty {
                // Could show an alert here
                print("No LMS servers found")
            }
        }
    }

    private func checkLMSServer(host: String, port: Int, completion: @escaping (DiscoveredServer?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3.0  // Quick timeout
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 400,
               error == nil {
                
                // Try to get server name from a quick JSON-RPC call
                self.getLMSServerName(host: host, port: port) { serverName in
                    let name = serverName ?? "LMS Server"
                    completion(DiscoveredServer(name: name, host: host, port: port))
                }
            } else {
                completion(nil)
            }
        }.resume()
    }

    private func getLMSServerName(host: String, port: Int, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/jsonrpc.js") else {
            completion(nil)
            return
        }
        
        let jsonRPC: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["serverstatus", "0", "0"]]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 2.0
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let serverName = result["hostname"] as? String {
                completion(serverName)
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    private let commonAddresses = [
        "lms.local", "squeezebox.local",
        "192.168.1.100", "192.168.1.101"
    ]
    
    private func loadCurrentSettings() {
        serverHost = settings.serverHost
        webPort = String(settings.serverWebPort)
        slimProtoPort = String(settings.serverSlimProtoPort)
    }
    
    private func validateAndProceed() {
        validationErrors.removeAll()
        
        // Validate inputs
        if serverHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationErrors.append("Server address is required")
        }
        
        guard let webPortInt = Int(webPort), webPortInt > 0, webPortInt < 65536 else {
            validationErrors.append("Web port must be a valid number between 1 and 65535")
            return
        }
        
        guard let slimPortInt = Int(slimProtoPort), slimPortInt > 0, slimPortInt < 65536 else {
            validationErrors.append("Stream port must be a valid number between 1 and 65535")
            return
        }
        
        if !validationErrors.isEmpty {
            return
        }
        
        // Save to settings
        settings.serverHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.serverWebPort = webPortInt
        settings.serverSlimProtoPort = slimPortInt
        
        onNext()
    }
}

// MARK: - Connection Test View
struct ConnectionTestView: View {
    @StateObject private var settings = SettingsManager.shared
    let onSuccess: () -> Void
    let onRetry: () -> Void
    
    @State private var testState: TestState = .testing
    @State private var testResult: SettingsManager.ConnectionTestResult?
    @State private var testDetails: [TestDetail] = []
    
    enum TestState {
        case testing
        case success
        case failure
    }
    
    struct TestDetail {
        let name: String
        let status: Status
        let message: String
        
        enum Status {
            case testing
            case success
            case failure
        }
    }
    
    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                Text("Testing Connection")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text("Verifying connection to \(settings.serverHost)")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            
            VStack(spacing: 16) {
                ForEach(testDetails.indices, id: \.self) { index in
                    let detail = testDetails[index]
                    TestDetailRow(detail: detail)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            
            Spacer()
            
            switch testState {
            case .testing:
                ProgressView("Testing...")
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .foregroundColor(.white)
                
            case .success:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    
                    Text("Connection Successful!")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Button("Continue") {
                        onSuccess()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                
            case .failure:
                VStack(spacing: 16) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    
                    Text("Connection Failed")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    if let result = testResult {
                        Text(errorMessage(for: result))
                            .font(.body)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    HStack(spacing: 16) {
                        Button("Try Again") {
                            runConnectionTest()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        
                        Button("Change Settings") {
                            onRetry()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .onAppear {
            runConnectionTest()
        }
    }
    
    private func runConnectionTest() {
        testState = .testing
        testDetails = [
            TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .testing, message: "Testing..."),
            TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .testing, message: "Testing...")
        ]
        
        Task {
            let result = await settings.testConnection()
            
            await MainActor.run {
                testResult = result
                updateTestDetails(for: result)
                
                switch result {
                case .success:
                    testState = .success
                default:
                    testState = .failure
                }
            }
        }
    }
    
    private func updateTestDetails(for result: SettingsManager.ConnectionTestResult) {
        switch result {
        case .success:
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .success, message: "Connected"),
                TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .success, message: "Connected")
            ]
            
        case .webPortFailure(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: error),
                TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .testing, message: "Skipped")
            ]
            
        case .slimProtoPortFailure(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .success, message: "Connected"),
                TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: error)
            ]
            
        case .invalidHost(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: error),
                TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: error)
            ]
            
        default:
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.serverWebPort))", status: .failure, message: "Failed"),
                TestDetail(name: "Stream Protocol (Port \(settings.serverSlimProtoPort))", status: .failure, message: "Failed")
            ]
        }
    }
    
    private func errorMessage(for result: SettingsManager.ConnectionTestResult) -> String {
        switch result {
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
        default:
            return "Unknown connection error occurred."
        }
    }
}

struct TestDetailRow: View {
    let detail: ConnectionTestView.TestDetail
    
    var body: some View {
        HStack {
            statusIcon
            
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(detail.message)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch detail.status {
        case .testing:
            ProgressView()
                .scaleEffect(0.8)
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title2)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.title2)
        }
    }
}

// MARK: - Player Setup View
struct PlayerSetupView: View {
    @StateObject private var settings = SettingsManager.shared
    let onNext: () -> Void
    let onBack: () -> Void
    
    @State private var playerName = ""
    @State private var showingMACInfo = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 15) {
                VStack(spacing: 16) {
                    Text("Player Setup")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    Text("Give your player a name that will appear in LMS. This helps identify this device when you have multiple players.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)
                
                VStack(spacing: 20) {
                    FormField(
                        title: "Player Name",
                        placeholder: "iOS Player",
                        text: $playerName
                    )
                    
                    InfoCard(
                        title: "Player ID",
                        value: settings.formattedMACAddress,
                        description: "Unique identifier for this player",
                        showInfo: $showingMACInfo
                    )
                }
                
                VStack(spacing: 16) {
                    Text("Suggested Names")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(suggestedNames, id: \.self) { name in
                            Button(name) {
                                playerName = name
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                
                Spacer(minLength: 40)
                
                HStack(spacing: 16) {
                    Button("Back") {
                        onBack()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    Button("Finish Setup") {
                        finishSetup()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showingMACInfo) {
            MACInfoSheet()
        }
        .onAppear {
            if playerName.isEmpty {
                playerName = settings.playerName.isEmpty ? "iOS Player" : settings.playerName
            }
        }
    }
    
    private let suggestedNames = [
        "iPhone", "iPad", "Living Room", "Bedroom",
        "Kitchen", "Office"
    ]
    
    private func finishSetup() {
        settings.playerName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.markAsConfigured()
        onNext()
    }
}

struct InfoCard: View {
    let title: String
    let value: String
    let description: String
    @Binding var showInfo: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
            }
            
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.gray)
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            
            Text(description)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

struct MACInfoSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var settings = SettingsManager.shared
    @State private var showingRegenerateAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Player ID Information")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                VStack(spacing: 16) {
                    Text("Your player ID is a unique identifier (MAC address) that LMS uses to recognize this device. Each player in LMS needs a unique ID.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                    
                    Text("Current ID:")
                        .font(.headline)
                    
                    Text(settings.formattedMACAddress)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(.blue)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                    
                    Text("⚠️ Regenerating the ID will create a new player in LMS. Your old player entry will become inactive.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button("Regenerate ID") {
                        showingRegenerateAlert = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal)
            .navigationBarHidden(true)
        }
        .alert("Regenerate Player ID?", isPresented: $showingRegenerateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                settings.regenerateMACAddress()
            }
        } message: {
            Text("This will create a new player in LMS. Your current player entry will become inactive. Continue?")
        }
    }
}

// MARK: - Setup Complete View
struct SetupCompleteView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
            
            VStack(spacing: 16) {
                Text("Setup Complete!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Your LMS Stream app is now configured and ready to use.")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                ConfigSummaryRow(label: "Server", value: settings.webURL)
                ConfigSummaryRow(label: "Player", value: settings.playerName)
                ConfigSummaryRow(label: "Player ID", value: settings.formattedMACAddress)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            
            VStack(spacing: 16) {
                Text("Next Steps:")
                    .font(.headline)
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 8) {
                    NextStepRow(number: "1", text: "Open LMS web interface to see your new player")
                    NextStepRow(number: "2", text: "Start playing music to begin streaming")
                    NextStepRow(number: "3", text: "Control playback from the lock screen")
                }
            }
            
            Spacer()
            
            // This view doesn't need navigation buttons as it's the final step
            // The app will automatically navigate when settings.isConfigured becomes true
        }
        .padding(.horizontal)
        .onAppear {
            isAnimating = true
        }
    }
}

struct ConfigSummaryRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            Text(value)
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct NextStepRow: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            Text(text)
                .font(.body)
                .foregroundColor(.gray)
            
            Spacer()
        }
    }
}

// MARK: - Reusable Form Components
struct FormField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            
            TextField(placeholder, text: $text)
                .textFieldStyle(CustomTextFieldStyle())
                .keyboardType(keyboardType)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }
}

struct CustomTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(8)
            .foregroundColor(.white)
    }
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Preview
struct OnboardingFlow_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingFlow()
    }
}
