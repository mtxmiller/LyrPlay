//
//  CarPlayManager.swift
//  LMS_StreamTest
//
//  Created by LyrPlay on 2025-01-30.
//

import Foundation
import MediaPlayer
import OSLog

private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")

@available(iOS 14.0, *)
class CarPlayManager: NSObject, ObservableObject {
    
    // MARK: - Dependencies
    private let settingsManager: SettingsManager
    private let slimProtoCoordinator: SlimProtoCoordinator
    private var jsonRpcClient: LMSJSONRPCClient?
    
    // MARK: - CarPlay State
    private var contentManager: MPPlayableContentManager?
    private var contentItems: [String: MPContentItem] = [:]
    private var isInitialized = false
    
    // MARK: - Content Data Storage
    private var artists: [Artist] = []
    private var albums: [Album] = []
    private var playlists: [Playlist] = []
    private var albumsByArtist: [String: [Album]] = [:]  // artist_id -> albums
    private var tracksByAlbum: [String: [Track]] = [:]   // album_id -> tracks
    private var tracksByPlaylist: [String: [Track]] = [:]// playlist_id -> tracks
    
    // MARK: - Loading State
    private var isLoadingArtists = false
    private var isLoadingAlbums = false
    private var isLoadingPlaylists = false
    
    // MARK: - Content Structure for Server-Aware Layout
    private enum ContentSection: String, CaseIterable {
        case artists = "artists"
        case albums = "albums"
        case playlists = "playlists"
        case radio = "radio"
        case search = "search"
        case favorites = "favorites"
        case serverSettings = "server_settings"
        
        var displayName: String {
            switch self {
            case .artists: return "Artists"
            case .albums: return "Albums"
            case .playlists: return "Playlists"
            case .radio: return "Radio"
            case .search: return "Search Library"
            case .favorites: return "Favorites"
            case .serverSettings: return "Switch Server"
            }
        }
        
        var iconName: String {
            switch self {
            case .artists: return "person.2.fill"
            case .albums: return "opticaldisc.fill"
            case .playlists: return "music.note.list"
            case .radio: return "radio.fill"
            case .search: return "magnifyingglass"
            case .favorites: return "heart.fill"
            case .serverSettings: return "gear"
            }
        }
    }
    
    // MARK: - Initialization
    init(settingsManager: SettingsManager, slimProtoCoordinator: SlimProtoCoordinator) {
        self.settingsManager = settingsManager
        self.slimProtoCoordinator = slimProtoCoordinator
        super.init()
        
        os_log(.info, log: logger, "🚗 CarPlayManager initialized")
    }
    
    // MARK: - Public Interface
    func initialize() {
        guard !isInitialized else { return }
        
        // Initialize JSON-RPC client
        setupJSONRPCClient()
        
        // Set up CarPlay content manager
        contentManager = MPPlayableContentManager.shared()
        contentManager?.dataSource = self
        contentManager?.delegate = self
        
        // Listen for server changes
        setupServerChangeNotifications()
        
        isInitialized = true
        os_log(.info, log: logger, "✅ CarPlay initialized successfully")
        
        // Initial content load
        refreshContent()
    }
    
    func refreshContent() {
        guard isInitialized else { 
            os_log(.error, log: logger, "🔄 Cannot refresh CarPlay content - not initialized")
            return 
        }
        
        os_log(.info, log: logger, "🔄 Refreshing CarPlay content")
        contentItems.removeAll()
        contentManager?.reloadData()
        
        // Force a check to see if CarPlay is connected
        if let contentManager = contentManager {
            os_log(.info, log: logger, "🔄 ContentManager exists, data source: %{public}s", 
                   contentManager.dataSource != nil ? "SET" : "NOT SET")
            os_log(.info, log: logger, "🔄 ContentManager delegate: %{public}s", 
                   contentManager.delegate != nil ? "SET" : "NOT SET")
        } else {
            os_log(.error, log: logger, "🔄 ContentManager is nil!")
        }
    }
    
    func handleServerChange() {
        os_log(.info, log: logger, "🔄 Server changed, updating CarPlay content")
        setupJSONRPCClient()
        refreshContent()
    }
    
    // MARK: - Private Setup
    private func setupJSONRPCClient() {
        let serverHost = settingsManager.activeServerHost
        let serverPort = settingsManager.activeServerWebPort
        
        os_log(.info, log: logger, "🌐 Setting up JSON-RPC client for %{public}s:%d", serverHost, serverPort)
        
        jsonRpcClient = LMSJSONRPCClient(
            host: serverHost,
            port: serverPort
        )
    }
    
    private func setupServerChangeNotifications() {
        // We'll observe server changes via the published property in ContentView
        // The handleServerChange() method will be called directly from ContentView
        os_log(.info, log: logger, "🔔 Server change notifications configured")
    }
    
    private func createMainMenuItems() -> [MPContentItem] {
        var items: [MPContentItem] = []
        
        // Add main content sections
        for section in ContentSection.allCases {
            let item = MPContentItem(identifier: section.rawValue)
            item.title = section.displayName
            item.isContainer = true
            item.isPlayable = false
            
            // Add server name to title for server settings
            if section == .serverSettings {
                item.subtitle = "Current: \(settingsManager.currentActiveServer.displayName)"
            }
            
            items.append(item)
        }
        
        return items
    }
    
    private func createServerAwareTitle() -> String {
        return "LyrPlay - \(settingsManager.currentActiveServer.displayName)"
    }
    
    // MARK: - Content Loading Methods
    
    private func loadArtists() async {
        guard !isLoadingArtists, let jsonRpcClient = jsonRpcClient else { return }
        
        isLoadingArtists = true
        os_log(.info, log: logger, "🎵 Loading artists from server...")
        
        do {
            let response = try await jsonRpcClient.getArtists(start: 0, count: 100)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.artists = response.artists_loop ?? []
                self.isLoadingArtists = false
                
                os_log(.info, log: logger, "✅ Loaded %d artists", self.artists.count)
                
                // Clear cached content items for artists section
                self.contentItems.removeValue(forKey: "artists_content")
                self.contentManager?.reloadData()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoadingArtists = false
                os_log(.error, log: logger, "❌ Failed to load artists: %{public}@", error.localizedDescription)
            }
        }
    }
    
    private func loadAlbums(artistID: String? = nil) async throws {
        guard !isLoadingAlbums, let jsonRpcClient = jsonRpcClient else { return }
        
        isLoadingAlbums = true
        os_log(.info, log: logger, "💿 Loading albums from server (artistID: %{public}s)...", artistID ?? "all")
        
        do {
            let response = try await jsonRpcClient.getAlbums(start: 0, count: 100, artistID: artistID)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let loadedAlbums = response.albums_loop ?? []
                
                if let artistID = artistID {
                    // Store albums for specific artist
                    self.albumsByArtist[artistID] = loadedAlbums
                    os_log(.info, log: logger, "✅ Loaded %d albums for artist %{public}s", loadedAlbums.count, artistID)
                } else {
                    // Store all albums
                    self.albums = loadedAlbums
                    os_log(.info, log: logger, "✅ Loaded %d total albums", loadedAlbums.count)
                }
                
                self.isLoadingAlbums = false
                self.contentManager?.reloadData()
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isLoadingAlbums = false
                os_log(.error, log: logger, "❌ Failed to load albums: %{public}@", error.localizedDescription)
            }
            throw error
        }
    }
    
    private func loadPlaylists() async {
        guard !isLoadingPlaylists, let jsonRpcClient = jsonRpcClient else { return }
        
        isLoadingPlaylists = true
        os_log(.info, log: logger, "📋 Loading playlists from server...")
        
        do {
            let response = try await jsonRpcClient.getPlaylists(start: 0, count: 100)
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.playlists = response.playlists_loop ?? []
                self.isLoadingPlaylists = false
                
                os_log(.info, log: logger, "✅ Loaded %d playlists", self.playlists.count)
                
                // Clear cached content items for playlists section
                self.contentItems.removeValue(forKey: "playlists_content")
                self.contentManager?.reloadData()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isLoadingPlaylists = false
                os_log(.error, log: logger, "❌ Failed to load playlists: %{public}@", error.localizedDescription)
            }
        }
    }
    
    private func loadTracks(albumID: String) async throws {
        guard let jsonRpcClient = jsonRpcClient else { return }
        
        os_log(.info, log: logger, "🎵 Loading tracks for album %{public}s...", albumID)
        
        do {
            let response = try await jsonRpcClient.getTracks(albumID: albumID, start: 0, count: 100)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                let loadedTracks = response.tracks_loop ?? []
                
                // Store tracks for this album
                self.tracksByAlbum[albumID] = loadedTracks
                os_log(.info, log: logger, "✅ Loaded %d tracks for album %{public}s", loadedTracks.count, albumID)
                
                self.contentManager?.reloadData()
            }
        } catch {
            os_log(.error, log: logger, "❌ Failed to load tracks for album %{public}s: %{public}@", albumID, error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Playback Methods
    
    private func playTrack(_ track: Track) async throws {
        os_log(.info, log: logger, "🎵 CARPLAY PLAYTRACK: Starting playback for track: %{public}s", track.displayTitle)
        
        guard let jsonRpcClient = jsonRpcClient else {
            os_log(.error, log: logger, "❌ CARPLAY PLAYTRACK: No JSON-RPC client available")
            throw CarPlayError.serverUnavailable
        }
        
        // Get the current player ID from settings (MAC address)
        let playerID = settingsManager.playerMACAddress
        
        guard !playerID.isEmpty else {
            os_log(.error, log: logger, "❌ CARPLAY PLAYTRACK: Player MAC address is empty")
            throw CarPlayError.serverUnavailable
        }
        
        os_log(.info, log: logger, "🎵 CARPLAY PLAYTRACK: Sending command for track: %{public}s (ID: %{public}s) on player: %{public}s", 
               track.displayTitle, track.stringID, playerID)
        
        // Send play command to LMS server - this will:
        // 1. Clear current queue and play the track immediately
        // 2. LMS will send SlimProto commands to our connected client
        // 3. SlimProto will trigger AudioManager to start streaming
        try await jsonRpcClient.playItem(playerID: playerID, itemType: .track, itemID: track.stringID)
        
        os_log(.info, log: logger, "✅ CARPLAY PLAYTRACK: JSON-RPC command completed successfully for track: %{public}s", track.displayTitle)
        os_log(.info, log: logger, "🔄 CARPLAY PLAYTRACK: LMS should now be sending SlimProto commands to trigger audio playback")
    }
}

// MARK: - MPPlayableContentDataSource
@available(iOS 14.0, *)
extension CarPlayManager: MPPlayableContentDataSource {
    
    func numberOfChildItems(at indexPath: IndexPath) -> Int {
        os_log(.info, log: logger, "📊 numberOfChildItems at indexPath: %{public}@ (indices count: %d)", indexPath.debugDescription, indexPath.indices.count)
        
        // Root level - show main sections
        if indexPath.indices.count == 0 {
            let count = ContentSection.allCases.count
            os_log(.info, log: logger, "📊 Root level returning %d sections", count)
            return count
        }
        
        // First level - content within sections
        if indexPath.indices.count == 1 {
            let sectionIndex = indexPath[0]
            guard sectionIndex < ContentSection.allCases.count else { 
                os_log(.error, log: logger, "📊 Invalid section index %d", sectionIndex)
                return 0 
            }
            
            let section = ContentSection.allCases[sectionIndex]
            let count: Int
            
            switch section {
            case .artists:
                count = artists.count
                os_log(.info, log: logger, "📊 Artists section returning %d artists", count)
            case .albums:
                count = albums.count
                os_log(.info, log: logger, "📊 Albums section returning %d albums", count)
            case .playlists:
                count = playlists.count
                os_log(.info, log: logger, "📊 Playlists section returning %d playlists", count)
            case .radio, .search, .favorites, .serverSettings:
                count = 0
                os_log(.info, log: logger, "📊 %{public}s section returning %d (not implemented)", section.displayName, count)
            }
            
            return count
        }
        
        // Second level - albums under artist, tracks under album/playlist, etc.
        if indexPath.indices.count == 2 {
            let sectionIndex = indexPath[0]
            let itemIndex = indexPath[1]
            
            guard sectionIndex < ContentSection.allCases.count else { return 0 }
            let section = ContentSection.allCases[sectionIndex]
            
            switch section {
            case .artists:
                guard itemIndex < artists.count else { return 0 }
                let artist = artists[itemIndex]
                let albumCount = albumsByArtist[artist.stringID]?.count ?? 0
                os_log(.info, log: logger, "📊 Artist %{public}s has %d albums", artist.displayName, albumCount)
                return albumCount
            default:
                return 0
            }
        }
        
        // Third level - tracks under album
        if indexPath.indices.count == 3 {
            let sectionIndex = indexPath[0]
            let artistIndex = indexPath[1]
            let albumIndex = indexPath[2]
            
            guard sectionIndex < ContentSection.allCases.count else { return 0 }
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard artistIndex < artists.count else { return 0 }
                let artist = artists[artistIndex]
                
                guard let artistAlbums = albumsByArtist[artist.stringID],
                      albumIndex < artistAlbums.count else { return 0 }
                
                let album = artistAlbums[albumIndex]
                let trackCount = tracksByAlbum[album.stringID]?.count ?? 0
                os_log(.info, log: logger, "📊 Album %{public}s has %d tracks", album.displayName, trackCount)
                return trackCount
            }
        }
        
        os_log(.info, log: logger, "📊 Deep level returning 0")
        return 0
    }
    
    func contentItem(at indexPath: IndexPath) -> MPContentItem? {
        os_log(.info, log: logger, "🎯 contentItem at indexPath: %{public}@ (indices count: %d)", indexPath.debugDescription, indexPath.indices.count)
        
        // Root level - main menu sections
        if indexPath.indices.count == 1 {
            let sectionIndex = indexPath[0]
            guard sectionIndex < ContentSection.allCases.count else { 
                os_log(.error, log: logger, "🎯 Invalid section index %d for contentItem", sectionIndex)
                return nil 
            }
            
            let section = ContentSection.allCases[sectionIndex]
            let cacheKey = section.rawValue
            
            os_log(.info, log: logger, "🎯 Creating content item for section: %{public}s", section.displayName)
            
            if let cachedItem = contentItems[cacheKey] {
                os_log(.info, log: logger, "🎯 Returning cached item for %{public}s", section.displayName)
                return cachedItem
            }
            
            let item = MPContentItem(identifier: cacheKey)
            item.title = section.displayName
            item.isContainer = (section != .search && section != .serverSettings)
            item.isPlayable = false
            
            // Add server-aware subtitle for server settings
            if section == .serverSettings {
                let subtitle = "Current: \(settingsManager.currentActiveServer.displayName)"
                item.subtitle = subtitle
                os_log(.info, log: logger, "🎯 Server settings subtitle: %{public}s", subtitle)
            }
            
            os_log(.info, log: logger, "🎯 Created section item: %{public}s (container: %{public}s, playable: %{public}s)", 
                   item.title ?? "nil", 
                   item.isContainer ? "true" : "false",
                   item.isPlayable ? "true" : "false")
            
            contentItems[cacheKey] = item
            return item
        }
        
        // First level - actual content items (artists, albums, playlists)
        if indexPath.indices.count == 2 {
            let sectionIndex = indexPath[0]
            let itemIndex = indexPath[1]
            
            guard sectionIndex < ContentSection.allCases.count else { return nil }
            let section = ContentSection.allCases[sectionIndex]
            
            switch section {
            case .artists:
                guard itemIndex < artists.count else { return nil }
                let artist = artists[itemIndex]
                let item = artist.toContentItem()
                os_log(.info, log: logger, "🎯 Created artist item: %{public}s", artist.displayName)
                return item
                
            case .albums:
                guard itemIndex < albums.count else { return nil }
                let album = albums[itemIndex]
                let item = album.toContentItem()
                os_log(.info, log: logger, "🎯 Created album item: %{public}s by %{public}s", album.displayName, album.displayArtist)
                return item
                
            case .playlists:
                guard itemIndex < playlists.count else { return nil }
                let playlist = playlists[itemIndex]
                let item = playlist.toContentItem()
                os_log(.info, log: logger, "🎯 Created playlist item: %{public}s", playlist.displayName)
                return item
                
            default:
                return nil
            }
        }
        
        // Second level - albums under artist
        if indexPath.indices.count == 3 {
            let sectionIndex = indexPath[0]
            let artistIndex = indexPath[1] 
            let albumIndex = indexPath[2]
            
            guard sectionIndex < ContentSection.allCases.count else { return nil }
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard artistIndex < artists.count else { return nil }
                let artist = artists[artistIndex]
                
                guard let artistAlbums = albumsByArtist[artist.stringID],
                      albumIndex < artistAlbums.count else { return nil }
                
                let album = artistAlbums[albumIndex]
                let item = album.toContentItem()
                os_log(.info, log: logger, "🎯 Created artist album item: %{public}s by %{public}s", album.displayName, album.displayArtist)
                return item
            }
        }
        
        // Third level - tracks under album  
        if indexPath.indices.count == 4 {
            let sectionIndex = indexPath[0]
            let artistIndex = indexPath[1]
            let albumIndex = indexPath[2]
            let trackIndex = indexPath[3]
            
            guard sectionIndex < ContentSection.allCases.count else { return nil }
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard artistIndex < artists.count else { return nil }
                let artist = artists[artistIndex]
                
                guard let artistAlbums = albumsByArtist[artist.stringID],
                      albumIndex < artistAlbums.count else { return nil }
                
                let album = artistAlbums[albumIndex]
                
                guard let albumTracks = tracksByAlbum[album.stringID],
                      trackIndex < albumTracks.count else { return nil }
                
                let track = albumTracks[trackIndex]
                let item = track.toContentItem()
                os_log(.info, log: logger, "🎯 Created track item: %{public}s by %{public}s", track.displayTitle, track.displayArtist)
                return item
            }
        }
        
        os_log(.info, log: logger, "🎯 No content item for indexPath")
        return nil
    }
    
    func beginLoadingChildItems(at indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        os_log(.info, log: logger, "🔄 beginLoadingChildItems at indexPath: %{public}@", indexPath.debugDescription)
        
        // First level - load content for main sections
        if indexPath.indices.count == 1 {
            let sectionIndex = indexPath[0]
            guard sectionIndex < ContentSection.allCases.count else { 
                completionHandler(CarPlayError.invalidContent)
                return
            }
            
            let section = ContentSection.allCases[sectionIndex]
            
            Task {
                do {
                    switch section {
                    case .artists:
                        if artists.isEmpty {
                            await loadArtists()
                        }
                    case .albums:
                        if albums.isEmpty {
                            try await loadAlbums()
                        }
                    case .playlists:
                        if playlists.isEmpty {
                            await loadPlaylists()
                        }
                    default:
                        break
                    }
                    
                    DispatchQueue.main.async {
                        completionHandler(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        completionHandler(error)
                    }
                }
            }
            return
        }
        
        // Second level - load albums for specific artist
        if indexPath.indices.count == 2 {
            let sectionIndex = indexPath[0]
            let itemIndex = indexPath[1]
            
            guard sectionIndex < ContentSection.allCases.count else {
                completionHandler(CarPlayError.invalidContent)
                return
            }
            
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard itemIndex < artists.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let artist = artists[itemIndex]
                
                Task {
                    do {
                        // Load albums for this artist if not already loaded
                        if albumsByArtist[artist.stringID] == nil {
                            try await loadAlbums(artistID: artist.stringID)
                        }
                        
                        DispatchQueue.main.async {
                            completionHandler(nil)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            os_log(.error, log: logger, "❌ Failed to load albums for artist: %{public}@", error.localizedDescription)
                            completionHandler(error)
                        }
                    }
                }
                return
            }
        }
        
        // Third level - load tracks for specific album
        if indexPath.indices.count == 3 {
            let sectionIndex = indexPath[0]
            let artistIndex = indexPath[1]
            let albumIndex = indexPath[2]
            
            guard sectionIndex < ContentSection.allCases.count else {
                completionHandler(CarPlayError.invalidContent)
                return
            }
            
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard artistIndex < artists.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let artist = artists[artistIndex]
                
                guard let artistAlbums = albumsByArtist[artist.stringID],
                      albumIndex < artistAlbums.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let album = artistAlbums[albumIndex]
                
                Task {
                    do {
                        // Load tracks for this album if not already loaded
                        if tracksByAlbum[album.stringID] == nil {
                            try await loadTracks(albumID: album.stringID)
                        }
                        
                        DispatchQueue.main.async {
                            completionHandler(nil)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            os_log(.error, log: logger, "❌ Failed to load tracks for album: %{public}@", error.localizedDescription)
                            completionHandler(error)
                        }
                    }
                }
                return
            }
        }
        
        // Complete immediately for other levels
        DispatchQueue.main.async {
            completionHandler(nil)
        }
    }
}

// MARK: - MPPlayableContentDelegate  
@available(iOS 14.0, *)
extension CarPlayManager: MPPlayableContentDelegate {
    
    func playableContentManager(_ contentManager: MPPlayableContentManager, initiatePlaybackOfContentItemAt indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        os_log(.info, log: logger, "▶️ CARPLAY DELEGATE: initiatePlaybackOfContentItem called at indexPath: %{public}@", indexPath.debugDescription)
        os_log(.info, log: logger, "📱 CARPLAY DELEGATE: CarPlay is requesting playback initiation")
        
        // Handle track playback (4-level indexPath: section -> artist -> album -> track)
        if indexPath.indices.count == 4 {
            let sectionIndex = indexPath[0]
            let artistIndex = indexPath[1]
            let albumIndex = indexPath[2]
            let trackIndex = indexPath[3]
            
            guard sectionIndex < ContentSection.allCases.count else {
                completionHandler(CarPlayError.invalidContent)
                return
            }
            
            let section = ContentSection.allCases[sectionIndex]
            
            if section == .artists {
                guard artistIndex < artists.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let artist = artists[artistIndex]
                
                guard let artistAlbums = albumsByArtist[artist.stringID],
                      albumIndex < artistAlbums.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let album = artistAlbums[albumIndex]
                
                guard let albumTracks = tracksByAlbum[album.stringID],
                      trackIndex < albumTracks.count else {
                    completionHandler(CarPlayError.invalidContent)
                    return
                }
                
                let track = albumTracks[trackIndex]
                
                // Start playback via unified queue management
                Task {
                    do {
                        os_log(.info, log: logger, "🎵 CARPLAY: About to call playTrack for: %{public}s", track.displayTitle)
                        try await playTrack(track)
                        
                        // Wait a moment for audio to actually start before completing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            os_log(.info, log: logger, "✅ CARPLAY: playTrack completed successfully for: %{public}s", track.displayTitle)
                            os_log(.info, log: logger, "📱 CARPLAY: Calling completion handler with nil (success) - after audio start delay")
                            completionHandler(nil)
                            os_log(.info, log: logger, "📱 CARPLAY: Completion handler called successfully")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            os_log(.error, log: logger, "❌ CARPLAY: playTrack failed with error: %{public}@", error.localizedDescription)
                            os_log(.error, log: logger, "📱 CARPLAY: Calling completion handler with error")
                            completionHandler(error)
                            os_log(.error, log: logger, "📱 CARPLAY: Completion handler called with error")
                        }
                    }
                }
                return
            }
        }
        
        // For other content types (albums, playlists, etc.)
        os_log(.info, log: logger, "⚠️ Playback not yet implemented for this content type")
        DispatchQueue.main.async {
            completionHandler(CarPlayError.invalidContent)
        }
    }
    
    func playableContentManager(_ contentManager: MPPlayableContentManager, didUpdate context: MPPlayableContentManagerContext) {
        os_log(.info, log: logger, "🎛️ CarPlay context updated: %{public}@", context.debugDescription)
    }
}

// MARK: - Error Types
enum CarPlayError: LocalizedError {
    case notInitialized
    case serverUnavailable
    case invalidContent
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "CarPlay manager not initialized"
        case .serverUnavailable:
            return "LMS server unavailable"
        case .invalidContent:
            return "Invalid content requested"
        }
    }
}