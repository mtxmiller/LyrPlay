// File: OnboardingViews.swift
import SwiftUI
import os.log

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
            case .welcome: return "Welcome to LMS Stream"
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
            
            // App icon/logo area
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)
                .scaleEffect(isAnimating ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isAnimating)
            
            VStack(spacing: 16) {
                Text("LMS Stream")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Connect to your Lyrion Music Server and enjoy high-quality streaming on your iOS device.")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 16) {
                FeatureRow(icon: "wifi", title: "Stream from LMS", description: "Connect to your music server")
                FeatureRow(icon: "speaker.wave.3", title: "High Quality Audio", description: "AAC, ALAC, and MP3 support")
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

// MARK: - Server Setup View
struct ServerSetupView: View {
    @StateObject private var settings = SettingsManager.shared
    let onNext: () -> Void
    let onBack: () -> Void
    
    @State private var serverHost = ""
    @State private var webPort = "9000"
    @State private var slimProtoPort = "3483"
    @State private var validationErrors: [String] = []
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Text("Server Configuration")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    Text("Enter your LMS server details. You can find the IP address in your LMS web interface under Settings → Network.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)
                
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
        }
    }
    
    private let commonAddresses = [
        "lms.local", "squeezebox.local",
        "192.168.1.100", "192.168.1.101",
        "192.168.0.100", "192.168.0.101"
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
            VStack(spacing: 30) {
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
        "Kitchen", "Office", "iOS Player", "Mobile"
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
