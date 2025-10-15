//
//  LMSJSONRPCClient.swift
//  LMS_StreamTest
//
//  Created by LyrPlay on 2025-01-30.
//

import Foundation
import OSLog

private let logger = OSLog(subsystem: "com.lmsstream", category: "JSONRPC")

// MARK: - JSON-RPC Client
class LMSJSONRPCClient {
    
    // MARK: - Properties
    private let host: String
    private let port: Int
    private let baseURL: URL
    private let session: URLSession
    private var requestID: Int = 0
    
    // MARK: - Constants
    private struct Constants {
        static let endpoint = "/jsonrpc.js"
        static let timeout: TimeInterval = 10.0
        static let contentType = "application/json"
    }
    
    // MARK: - Initialization
    init(host: String, port: Int) {
        self.host = host
        self.port = port
        self.baseURL = URL(string: "http://\(host):\(port)")!
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.timeout
        config.timeoutIntervalForResource = Constants.timeout * 2
        self.session = URLSession(configuration: config)
        
        os_log(.info, log: logger, "🌐 LMSJSONRPCClient initialized for %{public}s:%d", host, port)
    }
    
    // MARK: - Core JSON-RPC Method
    private func sendRequest<T: Codable>(_ command: [Any], to playerID: String = "", expecting responseType: T.Type) async throws -> T {
        // Generate unique request ID
        requestID += 1
        let currentRequestID = requestID
        
        // Create JSON-RPC request
        let request = JSONRPCRequest(
            id: currentRequestID,
            method: "slim.request",
            params: [playerID, command]
        )
        
        os_log(.debug, log: logger, "📤 Sending JSON-RPC request ID %d: %{public}@", currentRequestID, String(describing: command))
        
        // Create URL request
        let url = baseURL.appendingPathComponent(Constants.endpoint)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(Constants.contentType, forHTTPHeaderField: "Content-Type")
        
        // Serialize request
        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            os_log(.error, log: logger, "❌ Failed to encode JSON-RPC request: %{public}@", error.localizedDescription)
            throw LMSJSONRPCError.encodingError(error)
        }
        
        // Send request
        do {
            let (data, response) = try await session.data(for: urlRequest)
            
            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                os_log(.debug, log: logger, "📥 HTTP Response %d for request ID %d", httpResponse.statusCode, currentRequestID)
                
                guard httpResponse.statusCode == 200 else {
                    throw LMSJSONRPCError.httpError(httpResponse.statusCode)
                }
            }
            
            // Debug: Log the raw response
            if let responseString = String(data: data, encoding: .utf8) {
                os_log(.debug, log: logger, "📋 Raw JSON response: %{public}s", responseString)
            }
            
            // Parse JSON-RPC response
            let decoder = JSONDecoder()
            let jsonResponse = try decoder.decode(JSONRPCResponse<T>.self, from: data)
            
            // Check for JSON-RPC errors
            if let error = jsonResponse.error {
                os_log(.error, log: logger, "❌ JSON-RPC error for request ID %d: %{public}@", currentRequestID, error.message)
                throw LMSJSONRPCError.serverError(error.code, error.message)
            }
            
            // Check for missing result
            guard let result = jsonResponse.result else {
                os_log(.error, log: logger, "❌ Missing result in JSON-RPC response for request ID %d", currentRequestID)
                throw LMSJSONRPCError.missingResult
            }
            
            os_log(.debug, log: logger, "✅ JSON-RPC request ID %d completed successfully", currentRequestID)
            return result
            
        } catch let error as LMSJSONRPCError {
            throw error
        } catch {
            os_log(.error, log: logger, "❌ Network error for request ID %d: %{public}@", currentRequestID, error.localizedDescription)
            throw LMSJSONRPCError.networkError(error)
        }
    }
    
    // MARK: - Public API Methods
    
    /// Get list of artists
    func getArtists(start: Int = 0, count: Int = 100, libraryID: String? = nil) async throws -> ArtistsResponse {
        var command: [Any] = ["artists", start, count, "tags:s", "include_online_only_artists:1"]
        
        if let libraryID = libraryID {
            command.append("library_id:\(libraryID)")
        }
        
        return try await sendRequest(command, expecting: ArtistsResponse.self)
    }
    
    /// Get list of albums, optionally filtered by artist
    func getAlbums(start: Int = 0, count: Int = 100, artistID: String? = nil, libraryID: String? = nil) async throws -> AlbumsResponse {
        var command: [Any] = ["albums", start, count, "tags:jlays", "sort:album"]
        
        if let artistID = artistID {
            command.append("artist_id:\(artistID)")
        }
        
        if let libraryID = libraryID {
            command.append("library_id:\(libraryID)")
        }
        
        return try await sendRequest(command, expecting: AlbumsResponse.self)
    }
    
    /// Get list of playlists
    func getPlaylists(start: Int = 0, count: Int = 100) async throws -> PlaylistsResponse {
        let command: [Any] = ["playlists", start, count, "tags:su"]
        return try await sendRequest(command, expecting: PlaylistsResponse.self)
    }
    
    /// Get tracks from album or playlist
    func getTracks(albumID: String? = nil, playlistID: String? = nil, start: Int = 0, count: Int = 100) async throws -> TracksResponse {
        var command: [Any]
        
        if let playlistID = playlistID {
            command = ["playlists", "tracks", start, count, playlistID, "tags:gald"]
        } else if let albumID = albumID {
            command = ["tracks", start, count, "album_id:\(albumID)", "tags:gladiqrRtueJINpsy", "sort:tracknum"]
        } else {
            throw LMSJSONRPCError.invalidRequest("Must specify either albumID or playlistID")
        }
        
        return try await sendRequest(command, expecting: TracksResponse.self)
    }
    
    /// Search library content
    func search(query: String, start: Int = 0, count: Int = 50) async throws -> SearchResponse {
        let command: [Any] = ["search", start, count, "term:\(query)", "want_url:1"]
        return try await sendRequest(command, expecting: SearchResponse.self)
    }
    
    /// Get current player status
    func getPlayerStatus(playerID: String) async throws -> PlayerStatusResponse {
        let command: [Any] = ["status", "-", 1, "tags:cdegilopqrstuyAASYZV"]
        return try await sendRequest(command, to: playerID, expecting: PlayerStatusResponse.self)
    }
    
    // MARK: - Playback Commands
    
    /// Play a specific item
    func playItem(playerID: String, itemType: ItemType, itemID: String) async throws {
        let command: [Any] = ["playlistcontrol", "cmd:load", "\(itemType.rawValue):\(itemID)"]
        let _: EmptyResponse = try await sendRequest(command, to: playerID, expecting: EmptyResponse.self)
    }
    
    /// Add item to queue
    func addToQueue(playerID: String, itemType: ItemType, itemID: String) async throws {
        let command: [Any] = ["playlistcontrol", "cmd:add", "\(itemType.rawValue):\(itemID)"]
        let _: EmptyResponse = try await sendRequest(command, to: playerID, expecting: EmptyResponse.self)
    }
    
    /// Clear playlist and play item
    func playNow(playerID: String, itemType: ItemType, itemID: String) async throws {
        let command: [Any] = ["playlistcontrol", "cmd:load", "\(itemType.rawValue):\(itemID)"]
        let _: EmptyResponse = try await sendRequest(command, to: playerID, expecting: EmptyResponse.self)
    }
}

// MARK: - JSON-RPC Data Structures
extension LMSJSONRPCClient {
    
    struct JSONRPCRequest: Codable {
        let id: Int
        let method: String
        let params: [JSONValue]
        
        init(id: Int, method: String, params: [Any]) {
            self.id = id
            self.method = method
            self.params = params.map { JSONValue($0) }
        }
    }
    
    struct JSONRPCResponse<T: Codable>: Codable {
        let id: Int
        let method: String?
        let params: [JSONValue]?
        let result: T?
        let error: JSONRPCError?
    }
    
    struct JSONRPCError: Codable {
        let code: Int
        let message: String
    }
}

// MARK: - Item Types
enum ItemType: String {
    case track = "track_id"
    case album = "album_id"
    case artist = "artist_id"
    case playlist = "playlist_id"
    case genre = "genre_id"
}

// MARK: - Error Types
enum LMSJSONRPCError: LocalizedError {
    case networkError(Error)
    case httpError(Int)
    case encodingError(Error)
    case serverError(Int, String)
    case missingResult
    case invalidRequest(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .encodingError(let error):
            return "Encoding error: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code): \(message)"
        case .missingResult:
            return "Missing result in server response"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        }
    }
}

// MARK: - JSON Value Wrapper for Any Type
struct JSONValue: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let stringValue as String:
            try container.encode(stringValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            let jsonValues = arrayValue.map { JSONValue($0) }
            try container.encode(jsonValues)
        default:
            try container.encode(String(describing: value))
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else {
            value = ""
        }
    }
}