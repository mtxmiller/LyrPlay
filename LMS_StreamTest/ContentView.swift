// File: ContentView.swift
// Enhanced with Material skin settings integration
import SwiftUI
import WebKit
import os.log

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var audioManager: AudioManager  // ← FIXED: Remove .shared here
    @StateObject private var slimProtoCoordinator: SlimProtoCoordinator
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hasConnected = false
    @State private var showingSettings = false
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ContentView")
    @State private var isAppInBackground = false
    @State private var hasLoadedInitially = false
    @State private var webView: WKWebView?
    @State private var failureTimer: Timer?
    @State private var hasConnectionError = false
    @State private var hasHandledError = false
    @State private var hasShownError = false
    
    init() {
        os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"), "ContentView initializing with Material Settings Integration")
        
        // ✅ FIXED: Use the same singleton instance for EVERYTHING
        let audioMgr = AudioManager.shared
        self._audioManager = StateObject(wrappedValue: audioMgr)
        
        // ✅ Create SlimProtoCoordinator ONCE with the SAME AudioManager
        let coordinator = SlimProtoCoordinator(audioManager: audioMgr)
        self._slimProtoCoordinator = StateObject(wrappedValue: coordinator)
        
        // ✅ Connect them using the SAME instances
        audioMgr.slimClient = coordinator
        
        os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"), "✅ FIXED: Single AudioManager and SlimProtoCoordinator instances created")
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
                hasShownError = false  // Reset error flag
                hasConnectionError = false
                connectToLMS()
            }
        }
        // ADD THE .sheet MODIFIER HERE (after .onReceive):
        .sheet(isPresented: $showingSettings, onDismiss: {
            // Reset error states when dismissing settings
            hasConnectionError = false
            hasShownError = false
            hasHandledError = false
            loadError = nil
            
            // FIXED: Only reconnect if server settings actually changed
            let currentHost = settings.activeServerHost
            let currentWebPort = settings.activeServerWebPort
            let currentSlimPort = settings.activeServerSlimProtoPort
            
            // Check if any critical settings changed
            let hostChanged = currentHost != slimProtoCoordinator.lastKnownHost
            let portChanged = currentSlimPort != Int(slimProtoCoordinator.lastKnownPort)
            
            if hostChanged || portChanged {
                os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"),
                       "🔄 Server settings changed - reconnecting (host: %{public}s, port: %d)",
                       currentHost, currentSlimPort)
                
                // Reset connection flag
                hasConnected = false
                
                // Update coordinator with new settings
                slimProtoCoordinator.updateServerSettings(
                    host: currentHost,
                    port: UInt16(currentSlimPort)
                )
                
                // Reconnect after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.connectToLMS()
                }
            } else {
                os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"),
                       "✅ No server changes detected - keeping existing connection")
            }
        }) {
            SettingsView()
        }

    }
    
    private var mainAppView: some View {
        ZStack {
            // Background that fills everything
            Color(red: 0.25, green: 0.25, blue: 0.25) // Dark gray like Material
                .ignoresSafeArea(.all)
            
            // WebView that respects TOP safe area but ignores bottom
            if let url = URL(string: materialWebURL), !hasConnectionError {
                WebView(
                    url: url,
                    isLoading: $isLoading,
                    loadError: $loadError,
                    webViewReference: $webView,
                    onSettingsPressed: {
                        showingSettings = true
                    }
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .onChange(of: webView) { newWebView in
                    // Pass webView reference to coordinator for Material UI refresh
                    if let webView = newWebView {
                        slimProtoCoordinator.setWebView(webView)
                    }
                }
            } else {
                serverErrorView
            }
            
            // Status overlay
            if isLoading || loadError != nil {
                statusOverlay
            }
            
        }
        .onAppear {
            if !hasConnected && !hasConnectionError {
                connectToLMS()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppInBackground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            isAppInBackground = false
        }
        .onReceive(settings.$shouldReloadWebView) { shouldReload in
            print("🔄 shouldReloadWebView changed to: \(shouldReload)")
            if shouldReload {
                print("🔄 Attempting to reload WebView...")
                // Reset the trigger
                settings.shouldReloadWebView = false
                
                // Force WebView reload by updating the URL with a new timestamp
                if let webView = webView {
                    print("🔄 WebView found, reloading...")
                    let newURL = URL(string: materialWebURL)!
                    let request = URLRequest(url: newURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                    webView.load(request)
                    print("🔄 WebView reload requested")
                } else {
                    print("❌ WebView is nil!")
                }
            }
        }
    }
    
    private func handleLoadFailure() {
        // Auto-show settings after 10 seconds of failure
        failureTimer?.invalidate()
        failureTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            if self.loadError != nil {
                self.showingSettings = true
            }
        }
    }
    
    // MARK: - Material Integration URL
    private var materialWebURL: String {
        let baseURL = settings.webURL
        let settingsURL = "lmsstream://settings"
        let settingsName = "iOS App Settings"
        
        let encodedSettingsURL = settingsURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settingsURL
        let encodedSettingsName = settingsName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settingsName
        
        // Cache busting timestamp
        let timestamp = Int(Date().timeIntervalSince1970)
        
        // REMOVED: player parameter - let Material control default player selection
        return "\(baseURL)?appSettings=\(encodedSettingsURL)&appSettingsName=\(encodedSettingsName)&_t=\(timestamp)"
    }

    
    private var serverErrorView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text("Invalid LMS URL")
                .font(.headline)
                .foregroundColor(.red)
            
            Text("Server: \(settings.activeServerHost)")
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
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                    Text("Loading Material Interface...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.black.opacity(0.8))
                .cornerRadius(8)
            }
            
            if let error = loadError, !hasHandledError {
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
                .onAppear {
                    // Only handle the error ONCE
                    hasHandledError = true
                    hasConnectionError = true
                    //slimProtoCoordinator.disconnect()
                    
                    // Auto-show settings after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        if self.loadError != nil && !self.showingSettings {
                            self.showingSettings = true
                        }
                    }
                }
            }
            
            Spacer()
                .frame(height: 50) // Account for home indicator
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(loadError != nil) // Allow touches only when there's an error
    }
    
    // Enhanced debug overlay with server time synchronization info

    
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
    
    // Server time status color
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
    
    private var serverTimeStatusIcon: String {
        let status = slimProtoCoordinator.serverTimeStatus
        if status.contains("Available") {
            return "clock.fill"
        } else if status.contains("Unavailable") {
            return "clock.badge.xmark"
        } else {
            return "clock"
        }
    }

    private var serverTimeStatusText: String {
        let status = slimProtoCoordinator.serverTimeStatus
        // Extract just the key info, not the full verbose status
        if status.contains("Available") {
            // Extract the "last sync: Xs ago" part if present
            if let range = status.range(of: "last sync: ") {
                let remaining = String(status[range.upperBound...])
                if let endRange = remaining.range(of: ")") {
                    let syncInfo = String(remaining[..<endRange.lowerBound])
                    return "Server: \(syncInfo)"
                }
            }
            return "Server: Active"
        } else if status.contains("failures") {
            // Extract failure count
            if let range = status.range(of: "(") {
                let remaining = String(status[range.upperBound...])
                if let endRange = remaining.range(of: " failures") {
                    let failureCount = String(remaining[..<endRange.lowerBound])
                    return "Server: \(failureCount) fails"
                }
            }
            return "Server: Failed"
        } else {
            return "Server: Unknown"
        }
    }
    
    private func connectToLMS() {
        guard !hasConnected else { return }
        
        os_log(.info, log: logger, "Connecting to LMS server with Material Integration: %{public}s", settings.activeServerHost)
        
        audioManager.setSlimClient(slimProtoCoordinator)
        
        // Update coordinator with current settings
        slimProtoCoordinator.updateServerSettings(
            host: settings.activeServerHost,
            port: UInt16(settings.activeServerSlimProtoPort)
        )
        
        slimProtoCoordinator.connect()
        hasConnected = true
    }

}

struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var webViewReference: WKWebView?
    let onSettingsPressed: () -> Void
    
    private let logger = OSLog(subsystem: "com.lmsstream", category: "WebView")
    
    func makeUIView(context: Context) -> WKWebView {
        os_log(.info, log: logger, "Creating WKWebView with Material Integration for URL: %{public}s", url.absoluteString)
        
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        // CRITICAL: Enable custom URL scheme handling for Material integration
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "lmsStreamHandler")
        configuration.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // Set background color to match LMS skin
        webView.backgroundColor = UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        
        // ADD THESE CRITICAL LINES:
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        
        // Store reference for external access
        DispatchQueue.main.async {
            webViewReference = webView
        }
        
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10.0  // Now you can add this line
        
        webView.load(request)

        
        os_log(.info, log: logger, "WKWebView load request started with Material appSettings integration")
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // ADD THIS - check if host changed:
        if let currentURL = uiView.url, currentURL.host != url.host {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            uiView.load(request)
        }
    }
    
    
    
    func makeCoordinator() -> Coordinator {
        os_log(.info, log: logger, "Creating WebView Coordinator with Material integration")
        return Coordinator(self)
    }
    
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var parent: WebView
        private let logger = OSLog(subsystem: "com.lmsstream", category: "WebViewCoordinator")
        
        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            os_log(.info, log: logger, "Coordinator initialized with Material settings handler")
        }
        
        // MARK: - Material Settings Integration Handler
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            os_log(.info, log: logger, "📱 Received message from Material: %{public}s", message.name)
            
            if message.name == "lmsStreamHandler" {
                if let body = message.body as? String {
                    os_log(.info, log: logger, "📱 Material message body: %{public}s", body)
                    
                    // Handle the settings URL from Material
                    if body.contains("lmsstream://settings") {
                        os_log(.info, log: logger, "✅ Material settings button pressed - opening app settings")
                        DispatchQueue.main.async {
                            self.parent.onSettingsPressed()
                        }
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            os_log(.info, log: logger, "Started loading Material interface")
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.loadError = nil
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            os_log(.info, log: logger, "Finished loading Material interface")
            
            // CRITICAL: Inject JavaScript to handle Material's appSettings integration
            let settingsHandlerScript = """
            (function() {
                console.log('LyrPlay: Injecting Material settings handler...');
                
                // Override window.open to catch the appSettings URL
                const originalOpen = window.open;
                window.open = function(url, name, specs) {
                    console.log('LyrPlay: window.open called with URL:', url);
                    
                    if (url && url.startsWith('lmsstream://')) {
                        console.log('LyrPlay: Handling settings URL:', url);
                        // Send message to Swift
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lmsStreamHandler) {
                            window.webkit.messageHandlers.lmsStreamHandler.postMessage(url);
                        }
                        return null; // Prevent actual navigation
                    }
                    
                    // For other URLs, use original behavior
                    return originalOpen.call(this, url, name, specs);
                };
                
                // Also handle direct location changes
                const originalLocation = window.location;
                Object.defineProperty(window, 'location', {
                    get: function() {
                        return originalLocation;
                    },
                    set: function(url) {
                        if (typeof url === 'string' && url.startsWith('lmsstream://')) {
                            console.log('LyrPlay: Handling location change to:', url);
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lmsStreamHandler) {
                                window.webkit.messageHandlers.lmsStreamHandler.postMessage(url);
                            }
                            return;
                        }
                        originalLocation.href = url;
                    }
                });
                
                console.log('LyrPlay: Material settings handler injected successfully');
            })();
            """
            
            webView.evaluateJavaScript(settingsHandlerScript) { result, error in
                if let error = error {
                    os_log(.error, log: self.logger, "❌ Failed to inject settings handler: %{public}s", error.localizedDescription)
                    // Enable fallback settings button
                    DispatchQueue.main.async {
                        SettingsManager.shared.showFallbackSettingsButton = true
                    }
                } else {
                    os_log(.info, log: self.logger, "✅ Material settings handler injected successfully")
                    // Disable fallback settings button
                    DispatchQueue.main.async {
                        SettingsManager.shared.showFallbackSettingsButton = false
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed to load Material interface: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = "Failed to load Material: \(error.localizedDescription)"
                // Enable fallback settings button on error
                SettingsManager.shared.showFallbackSettingsButton = true
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed provisional navigation: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.loadError = "Connection failed: \(error.localizedDescription)"
                // Enable fallback settings button on error
                SettingsManager.shared.showFallbackSettingsButton = true
            }
        }
        
        // MARK: - Handle Direct URL Navigation (Alternative Method)
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString
                
                os_log(.info, log: logger, "🔍 Navigation decision for URL: %{public}s", urlString)
                
                // ONLY intercept our custom settings URL scheme
                if urlString.hasPrefix("lmsstream://settings") {
                    os_log(.info, log: logger, "✅ Intercepted Material settings URL: %{public}s", urlString)
                    
                    // Handle the settings navigation
                    DispatchQueue.main.async {
                        self.parent.onSettingsPressed()
                    }
                    
                    // Cancel the navigation
                    decisionHandler(.cancel)
                    return
                }
                
                // Check if this is a link to the same server (allow these to load in WebView)
                if let host = url.host {
                    let serverHost = SettingsManager.shared.serverHost
                    
                    // Allow navigation within the same LMS server
                    if host == serverHost || host.hasSuffix(".\(serverHost)") {
                        os_log(.info, log: logger, "✅ Allowing navigation within LMS server: %{public}s", urlString)
                        decisionHandler(.allow)
                        return
                    }
                    
                    // Allow localhost and local network addresses
                    if host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") ||
                       host == "localhost" || host.hasSuffix(".local") {
                        os_log(.info, log: logger, "✅ Allowing local network navigation: %{public}s", urlString)
                        decisionHandler(.allow)
                        return
                    }
                }
                
                // For external links, only open in Safari if it's a user-initiated link click
                if navigationAction.navigationType == .linkActivated {
                    os_log(.info, log: logger, "🌐 Opening external link in Safari: %{public}s", urlString)
                    
                    // Open in Safari
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    
                    // Cancel the navigation in WebView
                    decisionHandler(.cancel)
                    return
                }
            }
            
            // Allow all other navigation (page loads, redirects, etc.)
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString
                os_log(.info, log: logger, "📄 Material requesting iframe/popup for: %{public}s", urlString)
                
                // Check if this is a server administration page (like server.log)
                if let host = url.host {
                    let serverHost = SettingsManager.shared.serverHost
                    
                    // If it's from our LMS server, load it in the main WebView
                    if host == serverHost || host.hasSuffix(".\(serverHost)") {
                        os_log(.info, log: logger, "✅ Loading LMS admin page in main WebView: %{public}s", urlString)
                        
                        // Load the URL in the main WebView instead of creating a new one
                        webView.load(navigationAction.request)
                        return nil
                    }
                }
                
                // For external URLs, open in Safari
                os_log(.info, log: logger, "🌐 Opening external URL in Safari: %{public}s", urlString)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            
            // Return nil to prevent creating a new WebView
            return nil
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
