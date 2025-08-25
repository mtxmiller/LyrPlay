//
//  LMSDataModels.swift
//  LMS_StreamTest
//
//  Created by LyrPlay on 2025-01-30.
//

import Foundation

// MARK: - Response Models

/// Response model for artists query
struct ArtistsResponse: Codable {
    let count: Int
    let artists_loop: [Artist]?
    
    enum CodingKeys: String, CodingKey {
        case count
        case artists_loop
    }
}

/// Artist data model
struct Artist: Codable, Identifiable {
    let id: Int
    let artist: String
    let textkey: String?
    let favorites_url: String?
    
    var displayName: String {
        return artist.isEmpty ? "Unknown Artist" : artist
    }
    
    // For Identifiable protocol, convert Int id to String
    var stringID: String {
        return String(id)
    }
}

/// Response model for albums query  
struct AlbumsResponse: Codable {
    let count: Int
    let albums_loop: [Album]?
    
    enum CodingKeys: String, CodingKey {
        case count
        case albums_loop
    }
}

/// Album data model
struct Album: Codable, Identifiable {
    let id: Int
    let album: String
    let artist: String?
    let artist_id: Int?
    let year: Int?
    let artwork_url: String?
    let artwork_track_id: String?
    let compilation: Int?
    let performance: String?
    let favorites_title: String?
    let favorites_url: String?
    let textkey: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case album
        case artist
        case artist_id
        case year
        case artwork_url
        case artwork_track_id
        case compilation
        case performance
        case favorites_title
        case favorites_url
        case textkey
    }
    
    var displayName: String {
        return album.isEmpty ? "Unknown Album" : album
    }
    
    var displayArtist: String {
        return artist?.isEmpty == false ? artist! : "Unknown Artist"
    }
    
    var isCompilation: Bool {
        return compilation == 1
    }
    
    var displayYear: String? {
        guard let year = year, year > 0 else { return nil }
        return String(year)
    }
    
    // For Identifiable protocol and CarPlay identifiers
    var stringID: String {
        return String(id)
    }
}

/// Response model for playlists query
struct PlaylistsResponse: Codable {
    let count: Int
    let playlists_loop: [Playlist]?
    
    enum CodingKeys: String, CodingKey {
        case count
        case playlists_loop
    }
}

/// Playlist data model
struct Playlist: Codable, Identifiable {
    let id: Int
    let playlist: String
    let url: String?
    let remote: Int?
    let textkey: String?
    let favorites_url: String?
    
    var displayName: String {
        return playlist.isEmpty ? "Unknown Playlist" : playlist
    }
    
    var isRemote: Bool {
        return remote == 1
    }
    
    // For Identifiable protocol and CarPlay identifiers
    var stringID: String {
        return String(id)
    }
}

/// Response model for tracks query
struct TracksResponse: Codable {
    let count: Int
    let tracks_loop: [Track]?
    
    enum CodingKeys: String, CodingKey {
        case count
        case tracks_loop = "titles_loop"  // LMS returns "titles_loop" for track listings
    }
}

/// Track data model
struct Track: Codable, Identifiable {
    let id: Int  // LMS returns integer IDs for tracks
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let tracknum: String?
    let disc: Int?  // LMS returns disc as integer
    let year: String?  // LMS returns year as string in track listings
    let genre: String?
    let coverid: String?
    let artwork_url: String?
    let remote: Int?
    let url: String?
    
    // Additional fields that appear in LMS track responses
    let album_id: String?
    let artist_id: String?
    let genre_id: String?
    let artwork_track_id: String?
    let bitrate: String?
    let samplesize: String?
    let disccount: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case duration
        case tracknum
        case disc
        case year
        case genre
        case coverid
        case artwork_url
        case remote
        case url
        case album_id
        case artist_id
        case genre_id
        case artwork_track_id
        case bitrate
        case samplesize
        case disccount
    }
    
    var displayTitle: String {
        return title.isEmpty ? "Unknown Track" : title
    }
    
    var displayArtist: String {
        return artist?.isEmpty == false ? artist! : "Unknown Artist"
    }
    
    var displayAlbum: String {
        return album?.isEmpty == false ? album! : "Unknown Album"
    }
    
    var formattedDuration: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var trackNumber: Int? {
        guard let tracknum = tracknum else { return nil }
        return Int(tracknum)
    }
    
    var discNumber: Int? {
        return disc  // disc is now Int, no conversion needed
    }
    
    var isRemote: Bool {
        return remote == 1
    }
    
    // For Identifiable protocol and CarPlay identifiers
    var stringID: String {
        return String(id)
    }
}

/// Response model for search queries
struct SearchResponse: Codable {
    let count: Int
    let artists_loop: [Artist]?
    let albums_loop: [Album]?
    let tracks_loop: [Track]?
    let genres_loop: [Genre]?
    let playlists_loop: [Playlist]?
    
    enum CodingKeys: String, CodingKey {
        case count
        case artists_loop
        case albums_loop
        case tracks_loop
        case genres_loop
        case playlists_loop
    }
    
    var hasResults: Bool {
        return count > 0
    }
    
    var artistsCount: Int {
        return artists_loop?.count ?? 0
    }
    
    var albumsCount: Int {
        return albums_loop?.count ?? 0
    }
    
    var tracksCount: Int {
        return tracks_loop?.count ?? 0
    }
}

/// Genre data model for search results
struct Genre: Codable, Identifiable {
    let id: String
    let genre: String
    let textkey: String?
    
    var displayName: String {
        return genre.isEmpty ? "Unknown Genre" : genre
    }
}

/// Response model for player status
struct PlayerStatusResponse: Codable {
    let playlist_loop: [PlaylistTrack]?
    let playlist_timestamp: Double?
    let playlist_tracks: Int?
    let remotetitle: String?
    let current_title: String?
    let power: Int?
    let signalstrength: Int?
    let mode: String?
    let time: Double?
    let rate: Int?
    let duration: Double?
    let will_sleep_in: Int?
    let sync_master: String?
    let sync_slaves: String?
    let mixer: PlayerMixer?
    
    enum CodingKeys: String, CodingKey {
        case playlist_loop
        case playlist_timestamp
        case playlist_tracks
        case remotetitle
        case current_title
        case power
        case signalstrength
        case mode
        case time
        case rate
        case duration
        case will_sleep_in
        case sync_master
        case sync_slaves
        case mixer
    }
    
    var isPlaying: Bool {
        return mode == "play"
    }
    
    var isPaused: Bool {
        return mode == "pause"
    }
    
    var isStopped: Bool {
        return mode == "stop"
    }
    
    var isPoweredOn: Bool {
        return power == 1
    }
    
    var currentTrack: PlaylistTrack? {
        return playlist_loop?.first
    }
}

/// Playlist track model (for current queue)
struct PlaylistTrack: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let tracknum: String?
    let url: String?
    let remote: Int?
    let playlist_index: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case duration
        case tracknum
        case url
        case remote
        case playlist_index
    }
    
    var displayTitle: String {
        return title.isEmpty ? "Unknown Track" : title
    }
    
    var displayArtist: String {
        return artist?.isEmpty == false ? artist! : "Unknown Artist"
    }
    
    var displayAlbum: String {
        return album?.isEmpty == false ? album! : "Unknown Album"
    }
    
    var formattedDuration: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Player mixer information
struct PlayerMixer: Codable {
    let volume: Int?
    let mute: Int?
    
    var isMuted: Bool {
        return mute == 1
    }
    
    var volumeLevel: Int {
        return volume ?? 0
    }
}

/// Empty response for commands that don't return data
struct EmptyResponse: Codable {
    // This struct can be empty - LMS returns {} for successful commands
}

// MARK: - Helper Extensions

extension Artist {
    /// Create MPContentItem for CarPlay
    func toContentItem() -> MPContentItem {
        let item = MPContentItem(identifier: "artist_\(stringID)")
        item.title = displayName
        item.isContainer = true
        item.isPlayable = false  // Artists are containers for navigation, not directly playable
        return item
    }
}

extension Album {
    /// Create MPContentItem for CarPlay
    func toContentItem() -> MPContentItem {
        let item = MPContentItem(identifier: "album_\(stringID)")
        item.title = displayName
        item.subtitle = displayArtist
        if let year = displayYear {
            item.subtitle = "\(displayArtist) • \(year)"
        }
        item.isContainer = true
        item.isPlayable = false  // Albums are containers for navigation to tracks
        return item
    }
}

extension Playlist {
    /// Create MPContentItem for CarPlay
    func toContentItem() -> MPContentItem {
        let item = MPContentItem(identifier: "playlist_\(stringID)")
        item.title = displayName
        if isRemote {
            item.subtitle = "Remote Playlist"
        }
        item.isContainer = true
        item.isPlayable = true
        return item
    }
}

extension Track {
    /// Create MPContentItem for CarPlay
    func toContentItem() -> MPContentItem {
        let item = MPContentItem(identifier: "track_\(stringID)")
        item.title = displayTitle
        item.subtitle = displayArtist
        if !displayAlbum.isEmpty && displayAlbum != "Unknown Album" {
            item.subtitle = "\(displayArtist) • \(displayAlbum)"
        }
        item.isContainer = false
        item.isPlayable = true
        return item
    }
}

// MARK: - Import MediaPlayer Fix
import MediaPlayer

// This ensures MPContentItem is available at compile time