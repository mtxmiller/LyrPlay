// File: ContentView.swift
// Enhanced with Material skin settings integration
import SwiftUI
import WebKit
import os.log
import UIKit

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

            // IMPROVED: Force update server settings and reconnect if ANY server setting changed
            let currentHost = settings.activeServerHost
            let currentWebPort = settings.activeServerWebPort
            let currentSlimPort = settings.activeServerSlimProtoPort

            // Check if any critical settings changed (including backup server changes)
            let hostChanged = currentHost != slimProtoCoordinator.lastKnownHost
            let portChanged = currentSlimPort != Int(slimProtoCoordinator.lastKnownPort)

            if hostChanged || portChanged {
                os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"),
                       "🔄 Server settings changed - force updating and reconnecting (host: %{public}s, port: %d)",
                       currentHost, currentSlimPort)

                // Reset connection flag
                hasConnected = false

                // CRITICAL FIX: Disconnect first to clear stale state
                slimProtoCoordinator.disconnect()

                // CRITICAL FIX: Force update coordinator AND client with new settings
                slimProtoCoordinator.updateServerSettings(
                    host: currentHost,
                    port: UInt16(currentSlimPort)
                )

                // Also clear reconnection counter to prevent failover interference
                slimProtoCoordinator.resetConnectionManager()

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
                .environmentObject(slimProtoCoordinator)
        }

    }
    
    private var mainAppView: some View {
        ZStack {
            // Background that fills everything
            Color(red: 0.25, green: 0.25, blue: 0.25) // Dark gray like Material
                .ignoresSafeArea(.all)
            
            // Loading screen overlay that covers the entire view when loading
            // FIXED: Always show loading screen when isLoading=true, regardless of error state
            if isLoading {
                lyrPlayLoadingScreen
                    .ignoresSafeArea(.all)
                    .zIndex(1) // Ensure it appears above WebView
            }
            
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
                .opacity(isLoading ? 0 : 1) // Hide WebView while loading for smooth transition
                .animation(.easeInOut(duration: 0.5), value: isLoading)
                .onChange(of: webView) { newWebView in
                    // Pass webView reference to coordinator for Material UI refresh
                    if let webView = newWebView {
                        slimProtoCoordinator.setWebView(webView)
                    }
                }
            } else {
                serverErrorView
            }
            
            // Error overlay (only show when there's an error)
            if loadError != nil {
                errorOverlay
            }
            
        }
        .onAppear {
            if !hasConnected && !hasConnectionError {
                connectToLMS()
            }
            
            // CRITICAL FIX: Removed duplicate app open recovery call
            // App open recovery should only be triggered by willEnterForegroundNotification
            // Having it in both onAppear and willEnterForeground caused double execution
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            isAppInBackground = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            isAppInBackground = false

            // App foreground recovery: Use backgrounding duration to determine if recovery needed
            // Wait 2 seconds to ensure connection is stable after foregrounding
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Skip recovery if already playing (background audio kept connection alive)
                let currentState = audioManager.getPlayerState()
                if currentState == "Playing" {
                    os_log(.info, log: logger, "📱 App Foreground: Skipping recovery - already playing (state: %{public}s)", currentState)
                    return
                }

                // Get background duration from coordinator (centralized tracking)
                guard let duration = slimProtoCoordinator.getBackgroundDuration() else {
                    os_log(.info, log: logger, "📱 App Foreground: No background time tracked - skipping recovery")
                    return
                }

                os_log(.info, log: logger, "📱 App Foreground: Backgrounded for %.1f seconds", duration)

                // Check if app open recovery is enabled in settings
                guard settings.enableAppOpenRecovery else {
                    os_log(.info, log: logger, "📱 App Foreground: Recovery disabled in settings - skipping")
                    return
                }

                os_log(.error, log: logger, "[APP-RECOVERY] 🎯 APP OPEN RECOVERY TRIGGERED - backgrounded for %.1f seconds", duration)
                os_log(.error, log: logger, "[APP-RECOVERY] 📊 Settings: enableAppOpenRecovery=%{public}s", settings.enableAppOpenRecovery ? "YES" : "NO")
                os_log(.error, log: logger, "[APP-RECOVERY] 📊 Audio format: %{public}s", settings.audioFormat.displayName)
                os_log(.error, log: logger, "[APP-RECOVERY] 📊 Current player state: %{public}s", audioManager.getPlayerState())

                if duration > 45 {
                    // Long background (> 45s) - likely disconnected, perform recovery
                    os_log(.info, log: logger, "📱 App Foreground: Long background (%.1fs) - reconnecting and recovering position", duration)

                    // Reconnect if needed
                    if !slimProtoCoordinator.isConnected {
                        slimProtoCoordinator.connect()
                    }

                    // Wait for connection before recovery
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        os_log(.info, log: logger, "📱 App Foreground: Performing position recovery (shouldPlay: false)")
                        slimProtoCoordinator.performPlaylistRecovery(shouldPlay: false)
                    }
                } else {
                    // Brief background (< 45s) - skip recovery
                    os_log(.info, log: logger, "📱 App Foreground: Brief background (%.1fs) - no recovery needed", duration)
                }
            }
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
        .onReceive(settings.$currentActiveServer) { _ in
            // CRITICAL FIX: Reload WebView when server switches
            os_log(.info, log: logger, "🔄 Active server changed to: %{public}s - reloading WebView", settings.currentActiveServer.displayName)
            
            // Force WebView reload with new server URL
            if let webView = webView {
                let newURL = URL(string: materialWebURL)!
                let request = URLRequest(url: newURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                webView.load(request)
                os_log(.info, log: logger, "✅ WebView reloaded for server switch to: %{public}s", settings.activeServerHost)
            }
            
            // ALSO CRITICAL: Update SlimProto connection to new server
            slimProtoCoordinator.updateServerSettings(
                host: settings.activeServerHost,
                port: UInt16(settings.activeServerSlimProtoPort)
            )
            
            // Reconnect SlimProto to new server
            Task {
                await slimProtoCoordinator.restartConnection()
                os_log(.info, log: logger, "✅ SlimProto reconnected to: %{public}s:%d", settings.activeServerHost, settings.activeServerSlimProtoPort)
            }
        }
    }

    // MARK: - Helper Functions
    private func getLyrPlayPlayerName() -> String {
        return settings.effectivePlayerName
    }

    // MARK: - Material Integration URL
    private var materialWebURL: String {
        let baseURL = settings.webURL
        let settingsURL = "lmsstream://settings"
        let settingsName = "iOS App Settings"

        let encodedSettingsURL = settingsURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settingsURL
        let encodedSettingsName = settingsName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? settingsName

        // Add player parameter to show only LyrPlay when iOS Player Focus is enabled
        let playerName = settings.iOSPlayerFocus ? getLyrPlayPlayerName() : ""

        // REMOVED: Cache busting timestamp - let browser cache Material skin static assets
        // Material skin handles data freshness via its own API calls

        // Add Material skin query parameters:
        // - hide=mediaControls: Hides lock screen/notification settings (prevents Material web player from interfering with native iOS lock screen)
        //   NOTE: Material code checks for 'mediaControls' not 'notif' (ui-settings.js:506)
        // - appSettings: Custom iOS app settings integration
        // - player: Show only specified player when iOS Player Focus is enabled
        if settings.iOSPlayerFocus {
            return "\(baseURL)?player=\(playerName)&single&hide=mediaControls&appSettings=\(encodedSettingsURL)&appSettingsName=\(encodedSettingsName)"
        } else {
            return "\(baseURL)?hide=mediaControls&appSettings=\(encodedSettingsURL)&appSettingsName=\(encodedSettingsName)"
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
    
    // MARK: - LyrPlay Loading Screen
    private var lyrPlayLoadingScreen: some View {
        ZStack {
            // Dark background matching Material skin - fills entire screen
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.12, green: 0.12, blue: 0.12), // Darker top
                    Color(red: 0.20, green: 0.20, blue: 0.20), // Slightly lighter middle  
                    Color(red: 0.15, green: 0.15, blue: 0.15)  // Dark bottom
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea(.all) // Ensure it fills the entire screen including safe areas
            
            VStack(spacing: 40) {
                Spacer()
                
                // LyrPlay PNG Logo - Transparent background, inverted black to white
                Image("lyrplay-logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 300) // Reduced from 400 to 300
                    .colorInvert() // Convert black logo to white for dark background
                    .scaleEffect(isLoading ? 1.03 : 1.0)
                    .animation(
                        .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                        value: isLoading
                    )
                
                Spacer()
                
                // Loading indicator and status
                VStack(spacing: 16) {
                    // Elegant progress indicator
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.9)))
                        .scaleEffect(1.2)
                    
                    // Loading text with animation
                    HStack(spacing: 8) {
                        Text("Loading Material Interface")
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(.white.opacity(0.9))
                        
                        // Animated dots
                        HStack(spacing: 2) {
                            ForEach(0..<3) { index in
                                Circle()
                                    .fill(.white.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                    .scaleEffect(isLoading ? 1.0 : 0.5)
                                    .animation(
                                        .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                        value: isLoading
                                    )
                            }
                        }
                    }
                }
                
                Spacer()
                    .frame(height: 80) // Space for home indicator
            }
            .padding(.horizontal, 40)
        }
    }
    
    // MARK: - Error Overlay (Separate from loading screen)
    private var errorOverlay: some View {
        VStack {
            Spacer()
            
            if let error = loadError, !hasHandledError {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.title2)
                        Text(error)
                            .font(.body)
                            .foregroundColor(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                    }
                    
                    Button("Check Settings") {
                        showingSettings = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.blue)
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black.opacity(0.85))
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                )
                .onAppear {
                    // Only handle the error ONCE
                    hasHandledError = true
                    hasConnectionError = true
                    
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
        
        // Set background color to match LMS skin - CRITICAL: Set BEFORE loading
        webView.backgroundColor = UIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)
        webView.isOpaque = false
        
        // ADD THESE CRITICAL LINES:
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        
        // Store reference for external access
        DispatchQueue.main.async {
            webViewReference = webView
        }

        // HYBRID CACHING APPROACH:
        // - First load (no cache): Force network with fast timeout (fail fast if server down)
        // - Subsequent loads (has cache): Use cache for instant load, verify server in background

        let hasCache = URLCache.shared.cachedResponse(for: URLRequest(url: url)) != nil

        var request: URLRequest
        if hasCache {
            // Have cache - load from cache for speed, verify server in background
            request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
            request.timeoutInterval = 30.0  // Can wait longer since cache will show

            os_log(.info, log: logger, "✅ Cache available - loading from cache, verifying server in background")

            // Verify server reachability in background
            context.coordinator.verifyServerReachability(url: url)
        } else {
            // No cache - MUST load from network with FAST timeout
            request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 10.0  // Fail fast if server is down!

            os_log(.info, log: logger, "⚠️ No cache - forcing network load with 10s timeout for fast failure")
        }

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

        // MARK: - Server Reachability Verification
        func verifyServerReachability(url: URL) {
            // Quick HEAD request to server to verify it's up
            // This runs in background while cache loads for instant UI
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0  // Quick timeout

            os_log(.info, log: logger, "🔍 Verifying server reachability in background...")

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    // Server unreachable - set error even though cache loaded
                    os_log(.error, log: self.logger, "❌ Server unreachable: %{public}s", error.localizedDescription)
                    DispatchQueue.main.async {
                        self.parent.loadError = "Server unreachable: \(error.localizedDescription)"
                    }
                } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                    // Server returned error status
                    os_log(.error, log: self.logger, "❌ Server error: HTTP %d", httpResponse.statusCode)
                    DispatchQueue.main.async {
                        self.parent.loadError = "Server error: HTTP \(httpResponse.statusCode)"
                    }
                } else {
                    // Success - cache is valid and server is up
                    os_log(.info, log: self.logger, "✅ Server reachability verified - cache is fresh")
                }
            }.resume()
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
            os_log(.info, log: logger, "📡 WebView: Started loading Material interface")
            DispatchQueue.main.async {
                os_log(.debug, log: self.logger, "🔄 WebView: Setting isLoading = true")
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
                
                // Note: Lock screen/notification controls are now hidden via Material's hide=notif parameter
                // Native iOS media controls are handled entirely by LyrPlay's NowPlayingManager
                
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
                    // Enable fallback settings button and ensure loading is hidden
                    DispatchQueue.main.async {
                        SettingsManager.shared.showFallbackSettingsButton = true
                        self.parent.isLoading = false
                        os_log(.debug, log: self.logger, "❌ WebView: Setting isLoading = false (JS injection failed)")
                    }
                } else {
                    os_log(.info, log: self.logger, "✅ Material settings handler injected successfully")
                    // Disable fallback settings button and ensure loading is hidden
                    DispatchQueue.main.async {
                        SettingsManager.shared.showFallbackSettingsButton = false
                        self.parent.isLoading = false
                        os_log(.debug, log: self.logger, "✅ WebView: Setting isLoading = false (JS injection success)")
                    }
                }
            }
            
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed to load Material interface: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                os_log(.debug, log: self.logger, "❌ WebView: Setting isLoading = false (didFail)")
                self.parent.isLoading = false
                self.parent.loadError = "Failed to load Material: \(error.localizedDescription)"
                // Enable fallback settings button on error
                SettingsManager.shared.showFallbackSettingsButton = true
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: logger, "Failed provisional navigation: %{public}s", error.localizedDescription)
            DispatchQueue.main.async {
                os_log(.debug, log: self.logger, "❌ WebView: Setting isLoading = false (didFailProvisionalNavigation)")
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
