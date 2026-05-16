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

struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let albumCount: Int?
}

extension Artist {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "Artist")

    /// Parses an `artists_loop` JSON array from LMS `["artists", ...]` into Artist instances.
    /// Used by tvOS Search per-domain fan-out (98q.8) where each search fires
    /// `["artists", 0, 25, "tags:s", "search:<term>"]`. The `tags:s` flag adds sortable_name
    /// which we ignore. Entries missing id or name are skipped.
    static func parseLoop(_ data: [[String: Any]]) -> [Artist] {
        return data.compactMap { artistData -> Artist? in
            // id arrives as String OR Int from LMS depending on backend.
            let id: String
            if let s = artistData["id"] as? String {
                id = s
            } else if let n = artistData["id"] as? Int {
                id = String(n)
            } else {
                os_log(.error, log: parseLogger, "❌ Artist missing id, skipping")
                return nil
            }

            guard let name = artistData["artist"] as? String, !name.isEmpty else {
                os_log(.error, log: parseLogger, "❌ Artist %{public}s missing 'artist' field, skipping", id)
                return nil
            }

            return Artist(id: id, name: name, albumCount: nil)
        }
    }
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

// MARK: - Home Extra (Material Skin) Response

/// One row of Material's `home-extra` response — a labeled category whose items
/// are all the same kind. `items` carries strongly-typed payload so callers can
/// dispatch per kind without re-classifying strings.
struct HomeExtraSection: Identifiable {
    enum Items {
        case albums([Album])
        case artists([Artist])
        case favorites([FavoriteItem])
        case playlists([Playlist])
    }

    let id: String        // sort key, e.g. "new" / "recentlyplayed" / "artists_new" / "favorites"
    let title: String     // human-readable header for the shelf
    let items: Items

    var isEmpty: Bool {
        switch items {
        case .albums(let a):    return a.isEmpty
        case .artists(let a):   return a.isEmpty
        case .favorites(let f): return f.isEmpty
        case .playlists(let p): return p.isEmpty
        }
    }
}

/// Parsed `["material-skin", "home-extra", ...]` response.
///
/// `materialInstalled` is the routing signal for tvOS's LibraryView: a missing
/// `material_home` flag in the wire response means Material Skin is not loaded
/// on this LMS server and the caller should switch to BrowseLibraryView.
///
/// `sections` only contains non-empty shelves; empty `material_home_*_loop`
/// arrays are filtered out so SwiftUI renders no empty headers.
struct HomeExtraResponse {
    let materialInstalled: Bool
    let sections: [HomeExtraSection]
}

extension HomeExtraResponse {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "HomeExtraResponse")

    /// Album sort keys + display titles, in render order. Add/remove here to
    /// retune the v1 sort selection — keep the order, it's the on-screen order.
    private static let albumSorts: [(key: String, title: String)] = [
        ("new",            "New Music"),
        ("recentlyplayed", "Recently Played"),
        ("random",         "Random Albums"),
        ("popular",        "Popular"),
        ("playcount",      "Most Played"),
        ("changed",        "Recently Updated"),
    ]

    /// Artist sort keys + display titles, in render order.
    private static let artistSorts: [(key: String, title: String)] = [
        ("artists_new",            "New Artists"),
        ("artists_recentlyplayed", "Recently Heard Artists"),
        ("artists_popular",        "Popular Artists"),
        ("artists_playcount",      "Most Played Artists"),
    ]

    /// Parse the `result` dict from a `slim.request` envelope wrapping
    /// `["material-skin", "home-extra", ...]`. Pass the value of the `result`
    /// key, not the full JSON-RPC envelope.
    ///
    /// Empty shelves are filtered out. The `material_home` flag is the only
    /// signal we use for "is Material installed" — no separate detection probe.
    static func parse(_ result: [String: Any]) -> HomeExtraResponse {
        let materialInstalled = parseMaterialHomeFlag(result["material_home"])
        guard materialInstalled else {
            return HomeExtraResponse(materialInstalled: false, sections: [])
        }

        var sections: [HomeExtraSection] = []

        // Album shelves — strip `@idxN` from each item's id before parsing
        // (Plugin.pm:2295 rewrites ids when an album appears in multiple sorts).
        for sort in albumSorts {
            let loopKey = "material_home_\(sort.key)_loop"
            guard let loop = result[loopKey] as? [[String: Any]], !loop.isEmpty else { continue }
            let albums = Album.parseLoop(stripIdxSuffix(loop))
            guard !albums.isEmpty else { continue }
            sections.append(HomeExtraSection(id: sort.key, title: sort.title, items: .albums(albums)))
        }

        // Artist shelves — same `@idx` stripping (Plugin.pm:2203 also passes $idmod).
        for sort in artistSorts {
            let loopKey = "material_home_\(sort.key)_loop"
            guard let loop = result[loopKey] as? [[String: Any]], !loop.isEmpty else { continue }
            let artists = Artist.parseLoop(stripIdxSuffix(loop))
            guard !artists.isEmpty else { continue }
            sections.append(HomeExtraSection(id: sort.key, title: sort.title, items: .artists(artists)))
        }

        // Playlists — clean ids (Plugin.pm:2243 passes $idmod=undef).
        if let loop = result["material_home_playlists_loop"] as? [[String: Any]], !loop.isEmpty {
            let playlists = Playlist.parseLoop(loop)
            if !playlists.isEmpty {
                sections.append(HomeExtraSection(id: "playlists", title: "Playlists", items: .playlists(playlists)))
            }
        }

        // Radios — favorites shape under a different key (Plugin.pm:2218
        // passes $idmod=undef). Live testing (192.168.1.8) revealed the
        // items lack a top-level `id` field — `material-skin-query radios`
        // returns just {name,url,icon,ihe}. Synthesize id from url so
        // FavoriteItem.parseLoop's id requirement is satisfied. The
        // synthesized id then drives the tap dispatch in HomeExtraShelf,
        // which special-cases `section.id == "radios"` to play via the
        // raw URL instead of the favorites item_id command.
        if let loop = result["material_home_radios_loop"] as? [[String: Any]], !loop.isEmpty {
            let withIds = synthesizeIdFromUrl(loop)
            let radios = FavoriteItem.parseLoop(withIds)
            if !radios.isEmpty {
                sections.append(HomeExtraSection(id: "radios", title: "Radios", items: .favorites(radios)))
            }
        }

        // Favorites are NOT in this parser — they're fetched separately by
        // LibraryView via `["favorites","items"]` and appended as a section.
        // Reason: `material_home_favorites_obj` carries Jive-shape items
        // (text/icon/actions, NOT FavoriteItem fields) verified against the
        // 192.168.1.8 live server 2026-05-15, which would need a v2 Jive
        // base+commonParams merge parser. The direct favorites query gives
        // us the same content in a shape FavoriteItem.parseLoop already
        // speaks fluently.

        os_log(.info, log: parseLogger, "✅ home-extra parsed: %d non-empty shelves", sections.count)
        return HomeExtraResponse(materialInstalled: true, sections: sections)
    }

    /// `material_home` arrives as either Int 1 or String "1" depending on LMS
    /// serialization context; treat both as "installed."
    private static func parseMaterialHomeFlag(_ raw: Any?) -> Bool {
        if let n = raw as? Int { return n == 1 }
        if let s = raw as? String { return s == "1" }
        return false
    }

    /// Strip Plugin.pm:2295's `@idxN` suffix from each item's `id`. Safe to call
    /// on items without the suffix (no-op). Only applies to String ids; Int ids
    /// are passed through unchanged.
    private static func stripIdxSuffix(_ items: [[String: Any]]) -> [[String: Any]] {
        return items.map { item in
            guard let idString = item["id"] as? String,
                  let atRange = idString.range(of: "@idx") else {
                return item
            }
            var mutable = item
            mutable["id"] = String(idString[..<atRange.lowerBound])
            return mutable
        }
    }

    /// Synthesize `id` from `url` when missing. Used for the home-extra radios
    /// loop, whose `material-skin-query radios` results lack top-level ids.
    /// The synthesized id (the URL itself) doubles as the play-dispatch
    /// payload in HomeExtraShelf's `radios` branch.
    private static func synthesizeIdFromUrl(_ items: [[String: Any]]) -> [[String: Any]] {
        return items.map { item in
            if item["id"] != nil { return item }
            guard let url = item["url"] as? String, !url.isEmpty else { return item }
            var mutable = item
            mutable["id"] = url
            return mutable
        }
    }
}

// MARK: - Genre (BrowseLibraryView fallback)

/// Genre list entry from `["genres", 0, N]`. Used by the tvOS Library tab's
/// fallback view (when Material Skin is not installed) to render a list of
/// genres that drill into albums-filtered-by-genre.
struct Genre: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Library Shelf Catalog (tvOS home-extra shelf selection)

/// The catalog of home-extra shelves the tvOS Library tab can render. Single
/// source of truth for: home-extra request params, Settings toggle labels,
/// and persistence keys. `LibraryShelf.allCases` order defines on-screen
/// shelf order — reorder by hand here.
///
/// User-configurable via tvOS Settings → Library Shelves (per `D7=B` decision
/// 2026-05-15). Material stores its equivalent (`detailedHomeItems`) in
/// browser localStorage, not on the LMS server, so tvOS keeps its own state.
enum LibraryShelf: String, CaseIterable, Identifiable {
    case new
    case recentlyPlayed = "recentlyplayed"
    case random
    case popular
    case playcount
    case changed
    case artistsNew = "artists_new"
    case artistsRecentlyPlayed = "artists_recentlyplayed"
    case artistsPopular = "artists_popular"
    case artistsPlaycount = "artists_playcount"
    case playlists
    case radios
    case favorites

    var id: String { rawValue }

    /// How LibraryView fetches the data for this shelf. Most shelves come
    /// from the `home-extra` JSON-RPC; favorites is fetched separately
    /// because its `material_home_favorites_obj` shape requires the v2
    /// Jive base+commonParams merge parser we don't have yet.
    var dataSource: DataSource {
        switch self {
        case .favorites: return .separateFetch
        default:         return .homeExtra
        }
    }

    enum DataSource {
        /// Included as a `<rawValue>:1` param in the single home-extra request.
        case homeExtra
        /// Fetched via its own JSON-RPC request, results merged into the
        /// shelf list (currently only used by favorites).
        case separateFetch
    }

    /// Param appended to the `["material-skin", "home-extra", ...]` request
    /// when this shelf is enabled. Only meaningful for `dataSource == .homeExtra`.
    var requestParam: String { "\(rawValue):1" }

    /// Title shown in the Settings toggle AND as the shelf header on Library.
    var title: String {
        switch self {
        case .new:                   return "New Music"
        case .recentlyPlayed:        return "Recently Played"
        case .random:                return "Random Albums"
        case .popular:               return "Popular"
        case .playcount:             return "Most Played"
        case .changed:               return "Recently Updated"
        case .artistsNew:            return "New Artists"
        case .artistsRecentlyPlayed: return "Recently Heard Artists"
        case .artistsPopular:        return "Popular Artists"
        case .artistsPlaycount:      return "Most Played Artists"
        case .playlists:             return "Playlists"
        case .radios:                return "Radios"
        case .favorites:             return "Favorites"
        }
    }

    /// Whether this shelf is ON by default for first-run users. Picked to
    /// match a reasonable Material iPhone home — albums, artists, playlists,
    /// favorites, radios on; the more obscure sorts off. Users can toggle
    /// in Settings.
    var defaultEnabled: Bool {
        switch self {
        case .new, .recentlyPlayed, .random, .popular, .artistsNew,
             .playlists, .favorites, .radios:
            return true
        case .playcount, .changed, .artistsRecentlyPlayed,
             .artistsPopular, .artistsPlaycount:
            return false
        }
    }
}

extension Genre {
    private static let parseLogger = OSLog(subsystem: "com.lmsstream", category: "Genre")

    /// Parses a `genres_loop` JSON array. id arrives as String OR Int; name
    /// is the `genre` field. Skips entries missing either.
    static func parseLoop(_ data: [[String: Any]]) -> [Genre] {
        return data.compactMap { genreData -> Genre? in
            let id: String
            if let s = genreData["id"] as? String { id = s }
            else if let n = genreData["id"] as? Int { id = String(n) }
            else {
                os_log(.error, log: parseLogger, "❌ Genre missing id, skipping")
                return nil
            }

            guard let name = genreData["genre"] as? String, !name.isEmpty else {
                os_log(.error, log: parseLogger, "❌ Genre %{public}s missing 'genre' field, skipping", id)
                return nil
            }

            return Genre(id: id, name: name)
        }
    }
}

