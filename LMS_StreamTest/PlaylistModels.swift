// File: PlaylistModels.swift
// Data models for CarPlay + tvOS playlist, library, and Up Next functionality.
import Foundation
import Combine
import UIKit
import os.log

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

extension PlaylistTrack {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "PlaylistTrack")

    /// Parses a playlist_loop / playlisttracks_loop JSON array from LMS into PlaylistTrack instances.
    /// Malformed entries are logged and skipped; the remainder are returned in input order.
    static func parseLoop(_ data: [[String: Any]]) -> [PlaylistTrack] {
        return data.compactMap { trackData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: trackData)
                return try JSONDecoder().decode(PlaylistTrack.self, from: jsonData)
            } catch {
                os_log(.error, log: parseLogger, "❌ Failed to parse track: %{public}s", error.localizedDescription)
                return nil
            }
        }
    }
}

extension Playlist {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "Playlist")

    /// Parses a playlists_loop JSON array from LMS into Playlist instances.
    /// Malformed entries are logged and skipped; the remainder are returned in input order.
    static func parseLoop(_ data: [[String: Any]]) -> [Playlist] {
        return data.compactMap { playlistData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: playlistData)
                return try JSONDecoder().decode(Playlist.self, from: jsonData)
            } catch {
                os_log(.error, log: parseLogger, "❌ Failed to parse playlist: %{public}s", error.localizedDescription)
                return nil
            }
        }
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
    
}

// MARK: - Artist Data Model

struct Artist: Identifiable {
    let id: String
    let name: String
    let albumCount: Int?
}

// MARK: - Album Data Model

/// Album list item from LMS `albums` JSON-RPC.
/// CarPlay eagerly loads `artwork: UIImage` into the struct for offline display.
/// tvOS callers leave `artwork == nil` and resolve via URL through `LMSArtworkURL` + AsyncImage.
struct Album {
    let id: String
    let name: String
    let artist: String
    let artworkTrackId: String?  // LMS artwork_track_id field for cover art URLs
    let artwork: UIImage?
    let year: Int?

    init(id: String, name: String, artist: String, artworkTrackId: String?, artwork: UIImage?, year: Int? = nil) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artworkTrackId = artworkTrackId
        self.artwork = artwork
        self.year = year
    }
}

extension Album {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "Album")

    /// Parses an albums_loop JSON array from LMS `["albums", ...]` into Album instances.
    /// Mirrors CarPlaySceneDelegate's inline parser shape (tags:ajly returns id/album/artist/artwork_track_id/year).
    /// `artwork` is always nil here; CarPlay populates it post-fetch, tvOS resolves via URL.
    /// Malformed entries (missing id or album name) are skipped.
    static func parseLoop(_ data: [[String: Any]]) -> [Album] {
        return data.compactMap { albumData -> Album? in
            // id arrives as String OR Int from LMS depending on backend.
            let id: String
            if let s = albumData["id"] as? String {
                id = s
            } else if let n = albumData["id"] as? Int {
                id = String(n)
            } else {
                os_log(.error, log: parseLogger, "❌ Album missing id, skipping")
                return nil
            }

            guard let name = albumData["album"] as? String else {
                os_log(.error, log: parseLogger, "❌ Album %{public}s missing 'album' field, skipping", id)
                return nil
            }

            let artist = albumData["artist"] as? String ?? ""
            let artworkTrackId = albumData["artwork_track_id"] as? String

            // year arrives as Int or numeric String depending on backend.
            let year: Int?
            if let n = albumData["year"] as? Int {
                year = n
            } else if let s = albumData["year"] as? String, let n = Int(s) {
                year = n
            } else {
                year = nil
            }

            return Album(
                id: id,
                name: name,
                artist: artist,
                artworkTrackId: artworkTrackId,
                artwork: nil,
                year: year
            )
        }
    }
}

// MARK: - Favorite Item Data Model

/// Single item from LMS `["favorites", "items"]` JSON-RPC.
/// Used by the tvOS Library tab's Favorites sub-view. v1 renders only items
/// with playable URLs; folder items (`hasitems == 1`) are filtered out by `parseLoop`.
/// See `LMS_StreamTest-5bs` for the v2 hierarchical-folder follow-up.
struct FavoriteItem: Identifiable {
    let id: String
    let name: String
    let url: String
    let icon: String?     // image / cover / icon URL — may be relative server path or absolute
    let type: String?     // "audio", "playlist", "link", etc.
    let isAudio: Bool
}

extension FavoriteItem {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "FavoriteItem")

    /// Parses a `loop_loop` array from `["favorites", "items"], ["want_url:1", "feedMode:1"]`.
    /// Filters: keeps only items with a non-empty `url` AND `hasitems != 1`.
    /// Folder items (radio aggregators, plugin sub-trees) are skipped in v1 — see `LMS_StreamTest-5bs`.
    static func parseLoop(_ data: [[String: Any]]) -> [FavoriteItem] {
        return data.compactMap { itemData -> FavoriteItem? in
            // Skip folder items (LMS marks them with hasitems:1).
            // Match both Int and String shapes — LMS is inconsistent across endpoints.
            let hasItemsInt = itemData["hasitems"] as? Int
            let hasItemsStr = itemData["hasitems"] as? String
            if hasItemsInt == 1 || hasItemsStr == "1" {
                return nil
            }

            // Require a non-empty playable URL.
            guard let url = itemData["url"] as? String, !url.isEmpty else {
                return nil
            }

            // id arrives as String OR Int from LMS depending on item source.
            let id: String
            if let s = itemData["id"] as? String {
                id = s
            } else if let n = itemData["id"] as? Int {
                id = String(n)
            } else {
                os_log(.error, log: parseLogger, "❌ FavoriteItem missing id, skipping")
                return nil
            }

            // LMS uses `name` for favorites items but `title` is a documented fallback.
            let name = (itemData["name"] as? String)
                ?? (itemData["title"] as? String)
                ?? "Unknown"

            // Artwork can arrive under any of these keys depending on item source.
            // Material's lmsList similarly probes image / cover / icon.
            let icon = (itemData["image"] as? String)
                ?? (itemData["cover"] as? String)
                ?? (itemData["icon"] as? String)

            let type = itemData["type"] as? String

            // isaudio is 0/1 Int (LMS pattern); accept String form too.
            let isAudio: Bool
            if let n = itemData["isaudio"] as? Int {
                isAudio = (n == 1)
            } else if let s = itemData["isaudio"] as? String {
                isAudio = (s == "1")
            } else {
                isAudio = false
            }

            return FavoriteItem(
                id: id,
                name: name,
                url: url,
                icon: icon,
                type: type,
                isAudio: isAudio
            )
        }
    }
}

