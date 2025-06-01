// File: ContentView.swift
import SwiftUI
import WebKit
import os.log

struct ContentView: View {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var slimClient: SlimProtoClient
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var hasConnected = false
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ContentView")
    
    init() {
        os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "ContentView"), "ContentView initializing")
        
        // Create AudioManager first
        let audioMgr = AudioManager()
        self._audioManager = StateObject(wrappedValue: audioMgr)
        
        // Create SlimProtoClient with the AudioManager
        self._slimClient = StateObject(wrappedValue: SlimProtoClient(audioManager: audioMgr))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Set background color to match your LMS skin (dark gray/black)
                Color.black
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea(.all)
                
                if let url = URL(string: "http://192.168.1.8:9000") {
                    WebView(url: url, isLoading: $isLoading, loadError: $loadError)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .ignoresSafeArea(.all)
                } else {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Invalid LMS URL")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text("Check your server configuration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                // Status bar - overlay style so it doesn't take up space
                if isLoading || loadError != nil {
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
                            HStack {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(8)
                        }
                        
                        Spacer()
                            .frame(height: 50) // Account for home indicator
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false) // Allow touches to pass through to WebView
                }
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            if !hasConnected {
                os_log(.info, log: logger, "ContentView onAppear, triggering connect")
                slimClient.connect()
                hasConnected = true
            }
        }
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
        // Don't reload unless absolutely necessary
        // The initial load happens in makeUIView
        os_log(.debug, log: logger, "updateUIView called - no action needed")
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
