// File: OnboardingViews.swift
import SwiftUI
import os.log
import Network
import Foundation


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
            case .welcome: return "Welcome to LyrPlay"
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
                Text("LyrPlay")
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
            print("🔧 ServerSetupView appeared")
            loadCurrentSettings()
            print("🔧 Settings loaded, scheduling auto-discovery")
            
            // Auto-start discovery after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("🔧 Auto-discovery timer fired")
                startServerDiscovery()
            }
        }
    }
    
    private func startServerDiscovery() {
        print("🔧 startServerDiscovery() called")
        print("🔧 isDiscovering state: \(isDiscovering)")
        
        guard !isDiscovering else {
            print("🔧 Discovery already in progress - returning")
            return
        }
        
        print("🔧 Starting discovery without setting flag here")
        discoveredServers.removeAll()
        
        // Start discovery on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            print("🔧 Background queue started, calling discoverLMSServers")
            self.discoverLMSServers()
        }
    }

    private func discoverLMSServers() {
        print("🚨 discoverLMSServers() ENTERED - FIRST LINE")
        
        guard !isDiscovering else {
            print("❌ Discovery already in progress - skipping")
            return
        }
        
        isDiscovering = true
        discoveredServers.removeAll()
        
        print("🔍 Starting real LMS discovery using UDP broadcast...")
        
        // Use simple UDP discovery only
        DispatchQueue.global(qos: .userInitiated).async {
            self.discoverViaUDPBroadcast { foundServers in
                DispatchQueue.main.async {
                    self.discoveredServers = Array(foundServers).sorted { $0.name < $1.name }
                    self.isDiscovering = false
                    
                    print("🎯 Discovery complete: Found \(foundServers.count) servers")
                    
                    if foundServers.isEmpty {
                        print("❌ No servers found - try manual entry or check if LMS is running")
                    }
                }
            }
        }
    }
    
    // MARK: - Network Detection Helper
    private func getLocalNetworkBroadcastAddresses() -> [String] {
        var broadcastAddresses: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            print("📡 Failed to get network interfaces")
            return broadcastAddresses
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let flags = Int32(interface.ifa_flags)
            
            // Skip loopback and non-broadcast interfaces
            guard (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0,
                  (flags & IFF_UP) != 0,
                  interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            
            // Calculate broadcast address from IP and netmask
            guard let addr = interface.ifa_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }),
                  let netmask = interface.ifa_netmask?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee }) else {
                continue
            }
            
            let ip = addr.sin_addr.s_addr
            let mask = netmask.sin_addr.s_addr
            let broadcast = ip | (~mask)
            
            // Convert to string
            var broadcastAddr = sockaddr_in()
            broadcastAddr.sin_family = sa_family_t(AF_INET)
            broadcastAddr.sin_addr.s_addr = broadcast
            
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &broadcastAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            
            if result == 0 {
                let broadcastIP = String(cString: host)
                if !broadcastAddresses.contains(broadcastIP) {
                    broadcastAddresses.append(broadcastIP)
                    print("📡 Found broadcast address: \(broadcastIP)")
                }
            }
        }
        
        return broadcastAddresses
    }
    
    // MARK: - Simple LMS UDP Discovery Protocol
    private func discoverViaUDPBroadcast(completion: @escaping (Set<DiscoveredServer>) -> Void) {
        print("📡 Starting LMS UDP discovery...")
        var foundServers: Set<DiscoveredServer> = []
        
        // Use the standard LMS discovery message: "eNAME\0JSON\0"
        let discoveryMessage = "eNAME\0JSON\0"
        guard let discoveryData = discoveryMessage.data(using: .ascii) else {
            completion(foundServers)
            return
        }
        
        // Create UDP socket
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        print("📡 Socket creation result: \(socket)")
        guard socket >= 0 else {
            print("❌ Failed to create UDP socket, error: \(errno)")
            completion(foundServers)
            return
        }
        print("✅ UDP socket created successfully: \(socket)")
        
        // Enable broadcast
        var broadcast = 1
        let broadcastResult = setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int>.size))
        print("📡 Broadcast enable result: \(broadcastResult)")
        
        // Set receive timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutResult = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        print("📡 Timeout set result: \(timeoutResult)")
        
        // Bind socket to local address (required for broadcast)
        var localAddr = sockaddr_in()
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = 0 // Let system choose port
        localAddr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        print("📡 bind() result: \(bindResult)")
        
        if bindResult != 0 {
            print("❌ Failed to bind socket, errno: \(errno)")
            close(socket)
            completion(foundServers)
            return
        }
        
        // Try broadcast discovery - get local network broadcast addresses
        var targets = getLocalNetworkBroadcastAddresses()
        if targets.isEmpty {
            // Fallback to common network ranges if detection fails
            targets = [
                "255.255.255.255",      // Global broadcast (try first)
                "192.168.1.255",        // Common home router range  
                "192.168.0.255",        // Another common home range
                "10.0.0.255",           // Some home networks
            ]
        }
        
        for target in targets {
            print("📡 Trying discovery to: \(target):3483")
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(3483).bigEndian
            let inetResult = inet_pton(AF_INET, target, &addr.sin_addr)
            print("📡 inet_pton result for \(target): \(inetResult)")
            
            if inetResult != 1 {
                print("❌ Invalid IP address: \(target)")
                continue
            }
            
            print("📡 Discovery message length: \(discoveryData.count) bytes")
            let sendResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    discoveryData.withUnsafeBytes { bytes in
                        sendto(socket, bytes.bindMemory(to: UInt8.self).baseAddress, discoveryData.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            
            print("📡 sendto() result for \(target): \(sendResult)")
            if sendResult > 0 {
            print("📡 Sent LMS discovery packet")
            
            // Listen for responses
            var responseBuffer = [UInt8](repeating: 0, count: 1024)
            var senderAddr = sockaddr_in()
            var senderAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let startTime = Date()
            print("📡 Starting to listen for responses (5 second timeout)...")
            while Date().timeIntervalSince(startTime) < 5.0 {
                let bytesReceived = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(socket, &responseBuffer, responseBuffer.count, 0, sockPtr, &senderAddrLen)
                    }
                }
                
                print("📡 recvfrom() result: \(bytesReceived)")
                if bytesReceived > 0 {
                    let responseData = Data(responseBuffer.prefix(Int(bytesReceived)))
                    
                    // Get sender IP
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = withUnsafePointer(to: &senderAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            getnameinfo(sockPtr, senderAddrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                        }
                    }
                    
                    if result == 0 {
                        let serverIP = String(cString: hostBuffer)
                        print("📡 Got LMS response from \(serverIP)")
                        
                        if let serverInfo = parseLMSDiscoveryResponse(responseData, serverIP: serverIP) {
                            foundServers.insert(serverInfo)
                            print("✅ Found LMS server: \(serverInfo.name) at \(serverIP)")
                        }
                    }
                } else {
                    usleep(100000) // 100ms delay
                }
            }
            } else {
                print("❌ Failed to send discovery packet to \(target), sendto() returned: \(sendResult), errno: \(errno)")
            }
            
            // If we found servers, break out of the targets loop
            if !foundServers.isEmpty {
                break
            }
        } // End targets loop
        
        close(socket)
        print("📡 Socket closed")
        print("📡 LMS UDP discovery complete, found \(foundServers.count) servers")
        completion(foundServers)
    }

    
    private func parseLMSDiscoveryResponse(_ data: Data, serverIP: String) -> DiscoveredServer? {
        // Parse LMS discovery response format: 'E' + TAG + length + data
        // Skip the 'E' prefix (should be validated)
        guard data.count > 0 && data[0] == 0x45 else {
            print("❌ Invalid response packet (doesn't start with 'E')")
            return nil
        }
        
        var offset = 1 // Skip 'E'
        var serverName: String?
        var webPort: Int?
        
        while offset < data.count - 5 {
            // Extract 4-byte tag
            guard offset + 4 <= data.count else { break }
            let tagData = data.subdata(in: offset..<offset+4)
            guard let tag = String(data: tagData, encoding: .ascii) else {
                break
            }
            
            offset += 4
            
            // Extract length byte
            guard offset < data.count else { break }
            let length = Int(data[offset])
            offset += 1
            
            // Extract data
            guard offset + length <= data.count else { break }
            let valueData = data.subdata(in: offset..<offset+length)
            
            print("📡 Parsed tag: \(tag), length: \(length)")
            
            switch tag {
            case "NAME":
                serverName = String(data: valueData, encoding: .utf8)
                print("📡 Found server name: \(serverName ?? "nil")")
                
            case "JSON":
                if let portString = String(data: valueData, encoding: .utf8) {
                    webPort = Int(portString)
                    print("📡 Found web port: \(webPort ?? 0)")
                }
                
            default:
                print("📡 Unknown tag: \(tag)")
            }
            
            offset += length
        }
        
        guard let name = serverName, let port = webPort else {
            print("❌ Failed to parse server response - name: \(serverName ?? "nil"), port: \(webPort?.description ?? "nil")")
            return nil
        }
        
        return DiscoveredServer(
            name: name, 
            host: serverIP, 
            port: port
        )
    }

    // MARK: - Server Validation Helper
    
    // MARK: - Simple Server Validation
    private func validateLMSServerQuick(host: String, port: Int, completion: @escaping (DiscoveredServer?) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/jsonrpc.js") else {
            completion(nil)
            return
        }
        
        let jsonRPC: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["version", "?"]]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LyrPlay Discovery", forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 2.0
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            var serverName: String? = nil
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any] {
                
                if let version = result["_version"] as? String {
                    serverName = "LMS \(version)"
                } else {
                    serverName = "Lyrion Music Server"
                }
            }
            
            let name = serverName ?? "LMS Server"
            completion(DiscoveredServer(name: name, host: host, port: port))
        }.resume()
    }
    
    private let commonAddresses = [
        "lms.local", "squeezebox.local",
        "192.168.1.100", "192.168.1.101"
    ]
    
    private func loadCurrentSettings() {
        serverHost = settings.activeServerHost
        webPort = String(settings.activeServerWebPort)
        slimProtoPort = String(settings.activeServerSlimProtoPort)
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
                
                Text("Verifying connection to \(settings.activeServerHost)")
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
            TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .testing, message: "Testing..."),
            TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .testing, message: "Testing...")
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
                TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .success, message: "Connected"),
                TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .success, message: "Connected")
            ]
            
        case .webPortFailure(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: error),
                TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .testing, message: "Skipped")
            ]
            
        case .slimProtoPortFailure(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .success, message: "Connected"),
                TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: error)
            ]
            
        case .invalidHost(let error):
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: error),
                TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: error)
            ]
            
        default:
            testDetails = [
                TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .failure, message: "Failed"),
                TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .failure, message: "Failed")
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
                
                Text("Your LyrPlay app is now configured and ready to use.")
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
