// File: OnboardingViews.swift
// First-run setup: Welcome → Your Server → Connection → Your Player.
//
// Styled like the redesigned Settings (bd x19i): system grouped forms, the
// explanation in each section's footer, one prominent action per step, system
// light/dark appearance. Server discovery is the shared ServerDiscoveryManager
// (the same code as Settings → Server → Discover Servers). Finishing the last
// step marks the app configured; ContentView then shows Material and connects
// (bd t4o5 — also after Reset All Settings).
import SwiftUI
import os.log

// MARK: - Flow

struct OnboardingFlow: View {
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, server, connectionTest, player

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .server: return "Your Server"
            case .connectionTest: return "Connection"
            case .player: return "Your Player"
            }
        }
    }

    var body: some View {
        NavigationView {
            Group {
                switch step {
                case .welcome:
                    WelcomeStep(onNext: { go(.server) })
                case .server:
                    ServerStep(onNext: { go(.connectionTest) })
                case .connectionTest:
                    ConnectionTestView(onSuccess: { go(.player) }, onRetry: { go(.server) })
                case .player:
                    PlayerStep()
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            .animation(.easeInOut(duration: 0.3), value: step)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { stepHeader }
                ToolbarItem(placement: .navigationBarLeading) {
                    if step != .welcome {
                        Button("Back") { back() }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var stepHeader: some View {
        VStack(spacing: 1) {
            Text(step.title)
                .font(.headline)
            if step != .welcome {
                Text("Step \(step.rawValue) of \(Step.allCases.count - 1)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func go(_ next: Step) {
        withAnimation { step = next }
    }

    private func back() {
        switch step {
        case .welcome: break
        case .server: go(.welcome)
        case .connectionTest, .player: go(.server)
        }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            VStack(spacing: 14) {
                appIcon
                Text("LyrPlay")
                    .font(.largeTitle.bold())
                Text("A player for your Lyrion Music Server, with the Material interface you already know.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 28)

            VStack(alignment: .leading, spacing: 20) {
                feature("wifi", "Streams from your server",
                        "Your whole library, at home or away.")
                feature("waveform", "Lossless audio",
                        "FLAC, Opus, AAC and MP3, gapless, bit-perfect to a DAC.")
                feature("car.fill", "CarPlay, Siri and the lock screen",
                        "Control playback wherever you are.")
                feature("arrow.down.circle", "Keeps playing through dead spots",
                        "Saves the next songs so a tunnel does not stop the music.")
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 28)

            Button(action: onNext) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.getStarted")
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = UIImage(named: "iconm") {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
                .frame(width: 88, height: 88)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Your Server

private struct ServerStep: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var discovery = ServerDiscoveryManager()
    let onNext: () -> Void

    @State private var host = ""
    @State private var webPort = "9000"
    @State private var slimProtoPort = "3483"
    @State private var username = ""
    @State private var password = ""
    @State private var useHTTPS = false
    @State private var allowSelfSignedCert = false
    @State private var errors: [String] = []

    var body: some View {
        Form {
            discoverySection

            Section {
                TextField("192.168.1.100 or myserver.local", text: $host)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("onboarding.host")
                portRow("Web Port", placeholder: "9000", text: $webPort, id: "onboarding.webPort")
                portRow("Player Port", placeholder: "3483", text: $slimProtoPort, id: "onboarding.slimPort")
            } header: {
                Text("Server Address")
            } footer: {
                Text("The address of the computer running Lyrion Music Server. Away from home, use the address the server is reachable at. The ports only change for a reverse proxy or a custom setup.")
            }

            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("onboarding.username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("onboarding.password")
            } header: {
                Text("Password")
            } footer: {
                Text("Only if your server asks for a username and password. Most servers do not.")
            }

            Section {
                Toggle("Use HTTPS", isOn: $useHTTPS)
                Toggle("Allow Self-Signed Certificate", isOn: $allowSelfSignedCert)
                    .disabled(!useHTTPS)
            } header: {
                Text("HTTPS")
            } footer: {
                Text("For a server behind an HTTPS reverse proxy. The player connection on the player port is never encrypted.")
            }

            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingActionBar {
                Button(action: validateAndContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
        .dismissesKeyboardOnScroll()
        .onAppear {
            load()
            discovery.startDiscovery()
        }
        .onDisappear {
            discovery.stopDiscovery()
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            if discovery.isDiscovering && discovery.discoveredServers.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for servers…")
                        .foregroundColor(.secondary)
                }
            }
            ForEach(discovery.discoveredServers) { server in
                Button {
                    select(server)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .foregroundColor(.primary)
                            Text(verbatim: "\(server.host):\(server.port)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isSelected(server) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            if !discovery.isDiscovering {
                Button("Search Again") { discovery.startDiscovery() }
            }
        } header: {
            Text("Servers on This Network")
        } footer: {
            if discovery.isDiscovering || !discovery.discoveredServers.isEmpty {
                Text("Tap a server to use it, or enter an address below.")
            } else {
                Text("No server answered. Make sure it is running on this Wi‑Fi network, or enter its address below.")
            }
        }
    }

    private func portRow(_ label: String, placeholder: String, text: Binding<String>, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .accessibilityIdentifier(id)
        }
    }

    private func isSelected(_ server: DiscoveredServer) -> Bool {
        host == server.host && webPort == String(server.port)
    }

    private func select(_ server: DiscoveredServer) {
        host = server.host
        webPort = String(server.port)
    }

    private func load() {
        host = settings.activeServerHost
        webPort = String(settings.activeServerWebPort)
        slimProtoPort = String(settings.activeServerSlimProtoPort)
        username = settings.serverUsername
        password = settings.serverPassword
        useHTTPS = settings.serverWebUseHTTPS
        allowSelfSignedCert = settings.serverAllowSelfSignedCert
    }

    private func validateAndContinue() {
        errors.removeAll()

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            errors.append("Enter the server address.")
        }
        guard let webPortInt = Int(webPort), (1...65535).contains(webPortInt) else {
            errors.append("The web port must be a number from 1 to 65535.")
            return
        }
        guard let slimPortInt = Int(slimProtoPort), (1...65535).contains(slimPortInt) else {
            errors.append("The player port must be a number from 1 to 65535.")
            return
        }
        guard errors.isEmpty else { return }

        settings.serverHost = trimmedHost
        settings.serverWebPort = webPortInt
        settings.serverSlimProtoPort = slimPortInt
        settings.serverUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.serverPassword = password
        settings.serverWebUseHTTPS = useHTTPS
        settings.serverAllowSelfSignedCert = useHTTPS ? allowSelfSignedCert : false
        settings.saveSettings()   // credentials go to the Keychain

        onNext()
    }
}

// MARK: - Connection

/// Checks the web and player ports of the server just entered. `TestDetail`
/// and `TestDetailRow` are shared with Settings' ConnectionTestSheet.
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
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: headerSymbol)
                        .font(.system(size: 44))
                        .foregroundColor(headerColor)
                    Text(headerTitle)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: settings.serverHost)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section("Checks") {
                ForEach(testDetails.indices, id: \.self) { index in
                    TestDetailRow(detail: testDetails[index])
                }
            }

            if testState == .failure, let result = testResult {
                Section {
                    Text(errorMessage(for: result))
                        .foregroundColor(.secondary)
                } header: {
                    Text("What to Check")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingActionBar { actionButtons }
        }
        .onAppear {
            runConnectionTest()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch testState {
        case .testing:
            Button(action: {}) {
                Text("Checking…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)
        case .success:
            Button(action: onSuccess) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.continue")
        case .failure:
            VStack(spacing: 10) {
                Button(action: runConnectionTest) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: onRetry) {
                    Text("Change Server")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private var headerSymbol: String {
        switch testState {
        case .testing: return "network"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    private var headerColor: Color {
        switch testState {
        case .testing: return .accentColor
        case .success: return .green
        case .failure: return .red
        }
    }

    private var headerTitle: String {
        switch testState {
        case .testing: return "Checking the connection…"
        case .success: return "Connected"
        case .failure: return "Could Not Connect"
        }
    }

    private func runConnectionTest() {
        testState = .testing
        testDetails = [
            TestDetail(name: "Web Interface (Port \(settings.activeServerWebPort))", status: .testing, message: "Testing..."),
            TestDetail(name: "Stream Protocol (Port \(settings.activeServerSlimProtoPort))", status: .testing, message: "Testing...")
        ]

        Task {
            let auth = SettingsManager.generateAuthHeader(username: settings.serverUsername, password: settings.serverPassword)
            let result = await settings.testConnection(
                host: settings.serverHost,
                webPort: settings.serverWebPort,
                slimProtoPort: settings.serverSlimProtoPort,
                webUseHTTPS: settings.serverWebUseHTTPS,
                allowSelfSignedCert: settings.serverAllowSelfSignedCert,
                authHeader: auth
            )

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
        let web = "Web Interface (Port \(settings.activeServerWebPort))"
        let slim = "Stream Protocol (Port \(settings.activeServerSlimProtoPort))"
        switch result {
        case .success:
            testDetails = [
                TestDetail(name: web, status: .success, message: "Connected"),
                TestDetail(name: slim, status: .success, message: "Connected")
            ]
        case .webPortFailure(let error):
            testDetails = [
                TestDetail(name: web, status: .failure, message: error),
                TestDetail(name: slim, status: .testing, message: "Skipped")
            ]
        case .slimProtoPortFailure(let error):
            testDetails = [
                TestDetail(name: web, status: .success, message: "Connected"),
                TestDetail(name: slim, status: .failure, message: error)
            ]
        case .invalidHost(let error):
            testDetails = [
                TestDetail(name: web, status: .failure, message: error),
                TestDetail(name: slim, status: .failure, message: error)
            ]
        default:
            testDetails = [
                TestDetail(name: web, status: .failure, message: "Failed"),
                TestDetail(name: slim, status: .failure, message: "Failed")
            ]
        }
    }

    private func errorMessage(for result: SettingsManager.ConnectionTestResult) -> String {
        switch result {
        case .webPortFailure(let error) where error.contains("401"):
            return "The server asked for a password. Go back and check the username and password."
        case .webPortFailure:
            return "The web interface did not answer. Check that the server is running and the address and web port are right."
        case .slimProtoPortFailure:
            return "The web interface answered, but the player port did not. Check the player port, and that nothing blocks it."
        case .invalidHost:
            return "That address does not look right. Check the hostname or IP address."
        case .timeout:
            return "The connection timed out. Check the network and the address."
        case .networkError(let error):
            return error
        default:
            return "Something went wrong with the connection."
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
                    .foregroundColor(.blue)
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

// MARK: - Your Player

private struct PlayerStep: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var playerName = ""
    @State private var showingMACInfo = false

    private let suggestions = ["iPhone", "iPad", "Living Room", "Bedroom", "Kitchen", "Office"]

    private var trimmedName: String {
        playerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField("Player name", text: $playerName)
                    .accessibilityIdentifier("onboarding.playerName")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { name in
                            Button(name) { playerName = name }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Player Name")
            } footer: {
                Text("How this device appears in the server's player list and in other apps.")
            }

            Section {
                HStack {
                    Text("Player ID")
                    Spacer()
                    Text(settings.formattedMACAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button("About the Player ID") { showingMACInfo = true }
            } footer: {
                Text("The server tells this device apart from other players by its ID. It is made up on first launch and stays the same.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            OnboardingActionBar {
                Button(action: finishSetup) {
                    Text("Finish Setup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("onboarding.finish")
            }
        }
        .dismissesKeyboardOnScroll()
        .sheet(isPresented: $showingMACInfo) {
            MACInfoSheet()
        }
        .onAppear {
            if playerName.isEmpty {
                playerName = settings.playerName.isEmpty ? defaultName : settings.playerName
            }
        }
    }

    private var defaultName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func finishSetup() {
        settings.playerName = trimmedName
        settings.markAsConfigured()
        // ContentView switches to Material and connects when isConfigured flips.
    }
}

private extension View {
    /// Dragging the form puts the keyboard away (iOS 16+; a no-op before).
    @ViewBuilder
    func dismissesKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}

/// The one action at the bottom of a step, on a bar above the keyboard/home area.
private struct OnboardingActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
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

// MARK: - Button Styles (shared with Settings and ContentView)

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
