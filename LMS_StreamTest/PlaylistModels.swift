// File: PlaylistModels.swift
// Data models for CarPlay playlist and Up Next functionality
import Foundation

// MARK: - Playlist Data Models

struct Playlist: Identifiable, Codable {
    let id: String
    let name: String
    let trackCount: Int?
    let duration: Double?
    let url: String?
    let isModifiable: Bool?
    let originalNumericId: Int?  // Track original LMS numeric ID for playlists tracks command
    
    // Custom coding to handle LMS API response format
    enum CodingKeys: String, CodingKey {
        case id  // LMS returns "id" for playlists query
        case name = "playlist"
        case trackCount = "trackcount"  // LMS returns lowercase
        case duration
        case url
        case isModifiable = "modifiable"  // LMS returns without "is" prefix
        // Note: originalNumericId is NOT a server field - it's derived from id parsing
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle different ID formats from LMS
        var tempOriginalNumericId: Int?
        if let idString = try? container.decode(String.self, forKey: .id) {
            id = idString
        } else if let idInt = try? container.decode(Int.self, forKey: .id) {
            id = String(idInt)
            tempOriginalNumericId = idInt  // Preserve original numeric ID
        } else {
            id = UUID().uuidString
        }

        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown Playlist"
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        isModifiable = try container.decodeIfPresent(Bool.self, forKey: .isModifiable)

        // originalNumericId is derived from ID parsing above, not from server
        originalNumericId = tempOriginalNumericId
    }
    
    init(id: String, name: String, trackCount: Int? = nil, duration: Double? = nil, url: String? = nil, isModifiable: Bool? = nil, originalNumericId: Int? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.duration = duration
        self.url = url
        self.isModifiable = isModifiable
        self.originalNumericId = originalNumericId
    }

    // Computed property for display
    var trackCountDisplay: String {
        if let count = trackCount {
            return "\(count) tracks"
        }
        return "" // Don't show count if not available from LMS
    }
}

struct PlaylistTrack: Identifiable, Codable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let trackNumber: Int?
    let artworkURL: String?
    let albumID: String?
    let artistID: String?
    let playlistIndex: Int?  // LMS playlist index (important for playback)

    // Custom coding to handle LMS API response format
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case title
        case artist = "artist"
        case album = "album"
        case duration
        case trackNumber = "tracknum"
        case artworkURL = "coverid"
        case albumID = "album_id"
        case artistID = "artist_id"
        case playlistIndex = "playlist index"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle different ID formats
        if let idString = try? container.decode(String.self, forKey: .id) {
            id = idString
        } else if let idInt = try? container.decode(Int.self, forKey: .id) {
            id = String(idInt)
        } else {
            id = UUID().uuidString
        }

        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Unknown Track"
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)

        // Handle duration as both String and Double (LMS can return either)
        if let durationDouble = try? container.decode(Double.self, forKey: .duration) {
            duration = durationDouble
        } else if let durationString = try? container.decode(String.self, forKey: .duration),
                  let durationDouble = Double(durationString) {
            duration = durationDouble
        } else {
            duration = nil
        }

        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        playlistIndex = try container.decodeIfPresent(Int.self, forKey: .playlistIndex)

        // Build artwork URL if coverid is available
        if let coverID = try? container.decodeIfPresent(String.self, forKey: .artworkURL) {
            artworkURL = coverID.isEmpty ? nil : coverID
        } else {
            artworkURL = nil
        }

        // Handle album_id and artist_id as both Int and String
        if let albumIDString = try? container.decode(String.self, forKey: .albumID) {
            albumID = albumIDString
        } else if let albumIDInt = try? container.decode(Int.self, forKey: .albumID) {
            albumID = String(albumIDInt)
        } else {
            albumID = nil
        }

        if let artistIDString = try? container.decode(String.self, forKey: .artistID) {
            artistID = artistIDString
        } else if let artistIDInt = try? container.decode(Int.self, forKey: .artistID) {
            artistID = String(artistIDInt)
        } else {
            artistID = nil
        }
    }
    
    init(id: String, title: String, artist: String? = nil, album: String? = nil, duration: Double? = nil, trackNumber: Int? = nil, artworkURL: String? = nil, albumID: String? = nil, artistID: String? = nil, playlistIndex: Int? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.artworkURL = artworkURL
        self.albumID = albumID
        self.artistID = artistID
        self.playlistIndex = playlistIndex
    }

    // Computed property for display
    var detailText: String {
        if let artist = artist, let album = album {
            return "\(artist) • \(album)"
        } else if let artist = artist {
            return artist
        } else if let album = album {
            return album
        }
        return ""
    }
}

// MARK: - Up Next Queue Model

@MainActor
class UpNextQueue: ObservableObject {
    @Published var currentTrack: PlaylistTrack?
    @Published var upcomingTracks: [PlaylistTrack] = []
    @Published var previousTracks: [PlaylistTrack] = []
    @Published var currentIndex: Int = 0
    @Published var totalCount: Int = 0
    @Published var playlistName: String?
    @Published var isPlaying: Bool = false
    @Published var currentDuration: Double = 0.0
    @Published var currentTime: Double = 0.0
    
    var hasUpcoming: Bool { currentIndex < totalCount - 1 }
    var hasPrevious: Bool { currentIndex > 0 }
    var isEmpty: Bool { totalCount == 0 }
    
    // Computed properties for UI display
    var currentTrackDisplay: String {
        guard let track = currentTrack else { return "No Track Playing" }
        if let artist = track.artist {
            return "\(track.title) - \(artist)"
        }
        return track.title
    }
    
    var upcomingTracksDisplay: String {
        let count = upcomingTracks.count
        return count > 0 ? "\(count) upcoming" : "No upcoming tracks"
    }
    
    func updateWith(status: [String: Any]) {
        // Parse current track information
        if let playlistLoop = status["playlist_loop"] as? [[String: Any]],
           !playlistLoop.isEmpty {
            let currentTrackData = playlistLoop[0]
            currentTrack = parseTrack(from: currentTrackData)
        }
        
        // Parse queue information
        currentIndex = status["playlist_cur_index"] as? Int ?? 0
        totalCount = status["playlist_tracks"] as? Int ?? 0
        playlistName = status["playlist_name"] as? String
        
        // Parse playback state
        let mode = status["mode"] as? String ?? "stop"
        isPlaying = mode == "play"
        currentTime = status["time"] as? Double ?? 0.0
        currentDuration = status["duration"] as? Double ?? 0.0
        
        // Note: upcomingTracks would need to be populated via separate API call
        // for full playlist content, as status typically only includes current track
    }
    
    private func parseTrack(from data: [String: Any]) -> PlaylistTrack {
        let id = data["id"] as? String ?? UUID().uuidString
        let title = data["title"] as? String ?? "Unknown Track"
        let artist = data["artist"] as? String
        let album = data["album"] as? String
        let duration = data["duration"] as? Double
        let trackNumber = data["tracknum"] as? Int
        let artworkURL = data["coverid"] as? String
        let albumID = data["album_id"] as? String
        let artistID = data["artist_id"] as? String
        let playlistIndex = data["playlist index"] as? Int

        return PlaylistTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            trackNumber: trackNumber,
            artworkURL: artworkURL,
            albumID: albumID,
            artistID: artistID,
            playlistIndex: playlistIndex
        )
    }
}

// MARK: - LMS API Response Models

struct LMSPlaylistResponse: Codable {
    let playlistsLoop: [Playlist]
    let totalCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case playlistsLoop = "playlists_loop"
        case totalCount = "count"
    }
}

struct LMSTracksResponse: Codable {
    let tracksLoop: [PlaylistTrack]
    let totalCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case tracksLoop = "playlisttracks_loop"
        case totalCount = "count"
    }
}

// MARK: - Error Types

enum LMSPlaylistError: LocalizedError {
    case networkError(String)
    case invalidResponse
    case playlistNotFound(String)
    case serverError(String)
    case parsingError(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid server response"
        case .playlistNotFound(let id):
            return "Playlist not found: \(id)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .parsingError(let message):
            return "Data parsing error: \(message)"
        }
    }
}
