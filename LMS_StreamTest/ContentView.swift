// File: ContentView.swift
// Enhanced debug overlay showing server time synchronization status
import SwiftUI
import WebKit
import os.log

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var audioManager = AudioManager()
    @StateObject private var slimProtoCoordinator: SlimProtoCoordinator
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hasConnected = false
    @State private var showingSettings = false
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ContentView")
    @State private var isAppInBackground = false
    @State private var hasLoadedInitially = false

    
    init() {
        os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"), "ContentView initializing with Server Time Synchronization")
        
        // Create AudioManager first
        let audioMgr = AudioManager()
        self._audioManager = StateObject(wrappedValue: audioMgr)
        
        // Create SlimProtoCoordinator with AudioManager (includes ServerTimeSynchronizer)
        let coordinator = SlimProtoCoordinator(audioManager: audioMgr)
        self._slimProtoCoordinator = StateObject(wrappedValue: coordinator)
        
        // Connect AudioManager back to coordinator for lock screen support
        audioMgr.slimClient = coordinator
        
        os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"), "✅ Enhanced SlimProto architecture with server time sync initialized")
    }
    
    var body: some View {
        Group {
            if !settings.isConfigured {
                // Show onboarding flow for first-time users
                OnboardingFlow()
            } else {
                // Show main app interface for configured users
                mainAppView
            }
        }
        .onReceive(settings.$isConfigured) { isConfigured in
            if isConfigured && !hasConnected {
                // Connect to LMS when configuration is complete
                connectToLMS()
            }
        }
    }
    
    private var mainAppView: some View {
        GeometryReader { geometry in
            ZStack {
                // Set background color to match your LMS skin (dark gray/black)
                Color.black
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea(.all)
                
                if let url = URL(string: hasLoadedInitially ? settings.webURL : settings.initialWebURL) {
                    WebView(
                        url: url,
                        isLoading: $isLoading,
                        loadError: $loadError
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea(.all)
                    .onAppear {
                        hasLoadedInitially = true
                    }
                } else {
                    serverErrorView
                }
                
                // Status bar - overlay style so it doesn't take up space
                if isLoading || loadError != nil {
                    statusOverlay
                }
                
                // Settings button overlay
                settingsButtonOverlay
                
                // Enhanced debug info overlay with server time info
                if settings.isDebugModeEnabled && !isAppInBackground {
                    enhancedDebugOverlay
                }
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            if !hasConnected {
                connectToLMS()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppInBackground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            isAppInBackground = false
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    private var serverErrorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text("Invalid LMS URL")
                .font(.headline)
                .foregroundColor(.red)
            
            Text("Server: \(settings.serverHost)")
                .font(.body)
                .foregroundColor(.white)
            
            Text("Check your server configuration")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button("Open Settings") {
                showingSettings = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
        }
        .padding()
    }
    
    private var statusOverlay: some View {
        VStack {
            Spacer()
            
            if isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading LMS Interface...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(8)
            }
            
            if let error = loadError {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                    
                    Button("Check Settings") {
                        showingSettings = true
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(8)
            }
            
            Spacer()
                .frame(height: 50) // Account for home indicator
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(loadError != nil) // Allow touches only when there's an error
    }
    
    private var settingsButtonOverlay: some View {
        VStack {
            HStack {
                Spacer()
                
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .padding(.trailing, 100)
                .padding(.top, 60) // Account for status bar
            }
            
            Spacer()
        }
    }
    
    // Enhanced debug overlay with server time synchronization info
    private var enhancedDebugOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enhanced Debug + Server Time")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    // Connection status with network info
                    Text("Connection: \(slimProtoCoordinator.connectionState)")
                        .font(.caption2)
                        .foregroundColor(connectionStateColor)
                    
                    Text("Network: \(slimProtoCoordinator.networkStatus)")
                        .font(.caption2)
                        .foregroundColor(networkStatusColor)
                    
                    Text("Stream: \(slimProtoCoordinator.streamState)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    
                    // Server Time Status (NEW)
                    Text("Server Time: \(slimProtoCoordinator.serverTimeStatus)")
                        .font(.caption2)
                        .foregroundColor(serverTimeStatusColor)
                    
                    Text("Player: \(settings.formattedMACAddress)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    // Enhanced background state info
                    if slimProtoCoordinator.isInBackground {
                        Text("Background: YES")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        
                        if slimProtoCoordinator.backgroundTimeRemaining > 0 {
                            Text("Time: \(Int(slimProtoCoordinator.backgroundTimeRemaining))s")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text("Background: NO")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    
                    // Time Source Info (NEW)
                    Text("Time Source:")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                    
                    Text(slimProtoCoordinator.timeSourceInfo)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(3)
                    
                    // Connection summary
                    Text(slimProtoCoordinator.connectionSummary)
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                .padding(8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, 100)
            
            Spacer()
        }
    }
    
    private var connectionStateColor: Color {
        switch slimProtoCoordinator.connectionState {
        case "Connected":
            return .green
        case "Connecting", "Reconnecting":
            return .yellow
        case "Failed":
            return .red
        case "No Network":
            return .orange
        default:
            return .gray
        }
    }
    
    private var networkStatusColor: Color {
        switch slimProtoCoordinator.networkStatus {
        case "Wi-Fi", "Wired":
            return .green
        case "Cellular":
            return .yellow
        case "No Network":
            return .red
        default:
            return .gray
        }
    }
    
    // NEW: Server time status color
    private var serverTimeStatusColor: Color {
        let status = slimProtoCoordinator.serverTimeStatus
        if status.contains("Available") {
            return .green
        } else if status.contains("Unavailable") {
            return .red
        } else {
            return .yellow
        }
    }
    
    private func connectToLMS() {
        guard !hasConnected else { return }
        
        os_log(.info, log: logger, "Connecting to LMS server with Server Time Sync: %{public}s", settings.serverHost)
        
        audioManager.setSlimClient(slimProtoCoordinator)
        
        // Update coordinator with current settings
        slimProtoCoordinator.updateServerSettings(
            host: settings.serverHost,
            port: UInt16(settings.serverSlimProtoPort)
        )
        
        slimProtoCoordinator.connect()
        hasConnected = true
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    private let logger = OSLog(subsystem: "com.lmsstream", category: "WebView")
    
    func makeUIView(context: Context) -> WKWebView {
        os_log(.info, log: logger, "Creating WKWebView for URL: %{public}s", url.absoluteString)
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // Set background color to match LMS skin
        webView.backgroundColor = UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        webView.load(request)
        
        os_log(.info, log: logger, "WKWebView load request started")
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Check if URL has changed and reload if necessary
        if let currentURL = uiView.url, currentURL.host != url.host || currentURL.port != url.port {
            os_log(.info, log: logger, "URL changed, reloading WebView")
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            uiView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        os_log(.info, log: logger, "Creating WebView Coordinator")
        return Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        private let logger = OSLog(subsystem: "com.lmsstream", category: "WebViewCoordinator")
        
        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            os_log(.info, log: logger, "Coordinator initialized")
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            os_log(.info, log: logger, "Started loading LMS interface")
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadError = nil
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            os_log(.info, log: logger, "Finished loading LMS interface")
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed to load LMS: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = "Failed to load LMS: \(error.localizedDescription)"
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed provisional navigation: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = "Connection failed: \(error.localizedDescription)"
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

