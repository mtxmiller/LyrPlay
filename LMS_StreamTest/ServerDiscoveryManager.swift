// File: ServerDiscoveryManager.swift
// Simple LMS server discovery using standard UDP broadcast protocol
import Foundation
import os.log

class ServerDiscoveryManager: ObservableObject {
    
    // MARK: - Published State
    @Published var isDiscovering = false
    @Published var discoveredServers: [DiscoveredServer] = []
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ServerDiscovery")
    
    // MARK: - Public Interface
    
    /// Start LMS server discovery
    func startDiscovery() {
        guard !isDiscovering else { return }
        
        os_log(.info, log: logger, "🔍 Starting LMS server discovery")
        
        DispatchQueue.main.async {
            self.isDiscovering = true
            self.discoveredServers.removeAll()
        }
        
        // Use the same discovery logic as onboarding
        DispatchQueue.global(qos: .userInitiated).async {
            self.performUDPDiscovery { foundServers in
                DispatchQueue.main.async {
                    self.discoveredServers = Array(foundServers).sorted { $0.name < $1.name }
                    self.isDiscovering = false
                    
                    os_log(.info, log: self.logger, "🎯 Discovery complete: Found %d servers", foundServers.count)
                }
            }
        }
    }
    
    /// Stop discovery
    func stopDiscovery() {
        DispatchQueue.main.async {
            self.isDiscovering = false
        }
    }
    
    /// Validate a server is actually LMS
    func validateServer(_ server: DiscoveredServer, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(server.host):\(server.port)/jsonrpc.js") else {
            completion(false)
            return
        }
        
        let jsonRPC: [String: Any] = [
            "id": 1,
            "method": "slim.request", 
            "params": ["", ["version", "?"]]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 3.0
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let isValid = (data != nil && error == nil)
            DispatchQueue.main.async {
                completion(isValid)
            }
        }.resume()
    }
    
    // MARK: - Private Discovery Implementation
    
    private func performUDPDiscovery(completion: @escaping (Set<DiscoveredServer>) -> Void) {
        var foundServers: Set<DiscoveredServer> = []
        
        // Use the LMS discovery message: "eIPAD\0NAME\0JSON\0" (Qt client format)
        let discoveryMessage = "eIPAD\0NAME\0JSON\0"
        guard let discoveryData = discoveryMessage.data(using: .ascii) else {
            completion(foundServers)
            return
        }
        
        // Create UDP socket
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else {
            os_log(.error, log: logger, "❌ Failed to create UDP socket")
            completion(foundServers)
            return
        }
        
        // Enable broadcast
        var broadcast = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int>.size))
        
        // Set receive timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        // Send to port 3483 (LMS discovery port) 
        os_log(.info, log: logger, "🔍 Sending UDP discovery broadcast to 255.255.255.255:3483")
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(3483).bigEndian
        inet_pton(AF_INET, "255.255.255.255", &addr.sin_addr)
        
        let sendResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                discoveryData.withUnsafeBytes { bytes in
                    sendto(socket, bytes.bindMemory(to: UInt8.self).baseAddress, discoveryData.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        
        if sendResult > 0 {
            os_log(.info, log: logger, "📡 Sent LMS discovery packet")
            
            // Listen for responses
            var responseBuffer = [UInt8](repeating: 0, count: 1024)
            var senderAddr = sockaddr_in()
            var senderAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let startTime = Date()
            while Date().timeIntervalSince(startTime) < 5.0 {
                let bytesReceived = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(socket, &responseBuffer, responseBuffer.count, 0, sockPtr, &senderAddrLen)
                    }
                }
                
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
                        os_log(.info, log: logger, "📡 Got LMS response from %{public}s", serverIP)
                        
                        if let serverInfo = parseLMSResponse(responseData, serverIP: serverIP) {
                            foundServers.insert(serverInfo)
                            os_log(.info, log: logger, "✅ Found LMS server: %{public}s at %{public}s", serverInfo.name, serverIP)
                        }
                    }
                } else {
                    usleep(100000) // 100ms delay
                }
            }
        }
        
        close(socket)
        completion(foundServers)
    }
    
    private func parseLMSResponse(_ data: Data, serverIP: String) -> DiscoveredServer? {
        // Parse LMS discovery response format: TAG + length + data
        var offset = 0
        var serverName: String?
        var webPort: Int?
        
        while offset < data.count - 4 {
            // Extract 4-byte tag
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
            
            switch tag {
            case "NAME":
                serverName = String(data: valueData, encoding: .utf8)
            case "JSON":
                if let portString = String(data: valueData, encoding: .utf8) {
                    webPort = Int(portString)
                }
            default:
                break
            }
            
            offset += length
        }
        
        return DiscoveredServer(
            name: serverName ?? "LMS Server", 
            host: serverIP, 
            port: webPort ?? 9000
        )
    }
}