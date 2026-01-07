import UIKit
import CarPlay
import os.log

@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")
    var interfaceController: CPInterfaceController?
    private var browseTemplate: CPListTemplate?

    // Cached data for fast template updates
    private var cachedNewMusic: [Album] = []
    private var cachedRandomReleases: [Album] = []
    private var cachedPlaylists: [Playlist] = []

    // MARK: - Services

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        let connectionStartTime = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: logger, "🚗 CARPLAY WILL CONNECT")

        self.interfaceController = interfaceController

        // Initialize coordinator if needed (non-blocking - connect is async)
        if AudioManager.shared.slimClient == nil {
            initializeCoordinator()
        }

        // PERFORMANCE FIX: Show template IMMEDIATELY with minimal content
        let immediateTemplate = buildImmediateHomeTemplate()
        self.browseTemplate = immediateTemplate

        // Configure Now Playing template with Up Next button and Shuffle button
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        nowPlayingTemplate.isUpNextButtonEnabled = true
        nowPlayingTemplate.add(self)  // Add self as observer for up next button taps

        // Add custom shuffle button with distinct icons for off/songs/albums
        // Start with off state - will update icon when state changes
        let shuffleImage = UIImage(systemName: "shuffle")!
        let shuffleButton = CPNowPlayingImageButton(image: shuffleImage) { [weak self] button in
            os_log(.info, log: self?.logger ?? OSLog.default, "🔀 CarPlay shuffle button tapped")

            guard let coordinator = AudioManager.shared.slimClient else {
                os_log(.error, log: self?.logger ?? OSLog.default, "❌ Coordinator unavailable for shuffle")
                return
            }

            // Toggle shuffle and update button icon
            coordinator.toggleShuffleMode { newMode in
                DispatchQueue.main.async {
                    self?.updateShuffleButtonIcon(for: newMode)
                }
            }
        }
        nowPlayingTemplate.updateNowPlayingButtons([shuffleButton])

        // Set template immediately - user sees UI right away
        interfaceController.setRootTemplate(immediateTemplate, animated: false) { [weak self] success, error in
            guard let self = self else { return }

            if let error = error {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: %{public}s", error.localizedDescription)
            } else if !success {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: success=false, no error")
            } else {
                let elapsed = CFAbsoluteTimeGetCurrent() - connectionStartTime
                os_log(.info, log: self.logger, "🚗 CARPLAY UI VISIBLE in %.3f seconds", elapsed)
            }
        }

        // CONNECTION STATE CHECK: Only load data if coordinator is connected
        // Give connection a brief moment to establish (coordinator.connect() is async)
        // Increased to 3s for better reliability on slower networks
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            if let coordinator = AudioManager.shared.slimClient, coordinator.isConnected {
                os_log(.info, log: self.logger, "✅ Coordinator connected - loading home template data")
                self.refreshHomeTemplateData()
            } else {
                os_log(.error, log: self.logger, "❌ Coordinator not connected after 3s - showing error state")
                self.showConnectionError()
            }
        }

        os_log(.info, log: logger, "🚗 CARPLAY CONNECTED SUCCESSFULLY")
    }

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        os_log(.info, log: logger, "🚗 CARPLAY WILL DISCONNECT")
        os_log(.info, log: logger, "  Template Scene: %{public}s", String(describing: templateApplicationScene))
        os_log(.info, log: logger, "  Interface Controller: %{public}s", String(describing: interfaceController))

        self.interfaceController = nil
        os_log(.info, log: logger, "  ✅ Interface controller cleared")
        os_log(.info, log: logger, "🚗 CARPLAY DISCONNECTED")
    }

    // MARK: - Browse Actions

    private func handleResumePlayback() {
        os_log(.info, log: logger, "🚗 Resume playback requested from CarPlay Browse")

        // Ensure coordinator is initialized (may not be if only CarPlay scene is active)
        if AudioManager.shared.slimClient == nil {
            os_log(.info, log: logger, "⚠️ Coordinator not initialized - creating now...")
            initializeCoordinator()

            // CRITICAL FIX: Wait for connection before attempting recovery
            // coordinator.connect() is async - give it time to establish connection
            os_log(.info, log: logger, "⏳ Waiting 2s for coordinator to connect before recovery...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.attemptRecovery()
            }
        } else {
            // Coordinator already exists - attempt recovery immediately
            attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ Cannot resume - no coordinator available after init")
            return
        }

        os_log(.info, log: logger, "✅ Attempting playlist recovery with playback enabled...")
        coordinator.performPlaylistRecovery(shouldPlay: true)
    }

    private func initializeCoordinator() {
        let settings = SettingsManager.shared
        let audioManager = AudioManager.shared

        os_log(.info, log: logger, "🔧 Initializing SlimProto coordinator from CarPlay...")

        // Create coordinator with audio manager
        let coordinator = SlimProtoCoordinator(audioManager: audioManager)

        // Connect coordinator to audio manager
        audioManager.setSlimClient(coordinator)

        // Configure with server settings
        coordinator.updateServerSettings(
            host: settings.activeServerHost,
            port: UInt16(settings.activeServerSlimProtoPort)
        )

        // Connect to server
        coordinator.connect()

        os_log(.info, log: logger, "✅ Coordinator initialized and connected")
    }

    private func pushNowPlayingTemplate() {
        guard let interfaceController = interfaceController else {
            os_log(.error, log: logger, "❌ Cannot push Now Playing - no interface controller")
            return
        }

        os_log(.info, log: logger, "📱 Pushing Now Playing template onto navigation stack...")

        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        interfaceController.pushTemplate(nowPlayingTemplate, animated: true) { success, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ Failed to push Now Playing template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self.logger, "✅ Now Playing template pushed successfully")
            } else {
                os_log(.error, log: self.logger, "❌ Failed to push Now Playing template: success=false, no error")
            }
        }
    }

    // MARK: - Scene Lifecycle

    func sceneDidBecomeActive(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE BECAME ACTIVE")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE WILL RESIGN ACTIVE")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE ENTERING FOREGROUND")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE ENTERED BACKGROUND")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE DID DISCONNECT")
    }
    
    // MARK: - Playlist and Up Next Functionality
    
    private func showPlaylists() {
        os_log(.info, log: logger, "📂 Showing playlists in CarPlay")

        fetchPlaylists { [weak self] playlists in
            self?.displayPlaylists(playlists)
        }
    }

    private func displayPlaylists(_ playlists: [Playlist]) {
        var playlistItems: [CPListItem] = []

        for playlist in playlists {
            let item = CPListItem(
                text: playlist.name,
                detailText: playlist.trackCountDisplay,
                image: nil,
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )

            item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.handlePlaylistSelection(playlist: playlist)
                completion()
            }

            playlistItems.append(item)
        }

        let playlistsTemplate = CPListTemplate(
            title: "Playlists",
            sections: [CPListSection(items: playlistItems)]
        )

        interfaceController?.pushTemplate(playlistsTemplate, animated: true)
        os_log(.info, log: logger, "✅ Displayed %d playlists", playlistItems.count)
    }
    
    private func handlePlaylistSelection(playlist: Playlist) {
        os_log(.info, log: logger, "🎵 Selected playlist: %{public}s (%{public}s)", playlist.name, playlist.id)

        // Check if this is a file-based playlist (has URL) or database playlist (has numeric ID)
        if playlist.url != nil && playlist.originalNumericId == nil {
            // File-based playlist - "playlists tracks" command doesn't work with file URLs
            // Just load it directly
            os_log(.info, log: logger, "📂 File-based playlist detected, loading directly: %{public}s", playlist.name)
            self.loadPlaylistDirectly(playlist: playlist)
        } else if playlist.originalNumericId != nil {
            // Database playlist - fetch tracks first to show track listing
            fetchPlaylistTracks(playlist: playlist) { [weak self] tracks in
                guard let self = self else { return }

                if tracks.isEmpty {
                    // Fallback: just load the playlist directly
                    os_log(.info, log: self.logger, "📂 No tracks found, loading playlist directly: %{public}s", playlist.name)
                    self.loadPlaylistDirectly(playlist: playlist)
                } else {
                    os_log(.info, log: self.logger, "🎶 Found %d tracks, displaying: %{public}s", tracks.count, playlist.name)
                    self.displayPlaylistTracks(tracks, playlist: playlist)
                }
            }
        } else {
            // No numeric ID and no URL - just load it
            os_log(.info, log: logger, "📂 Loading playlist directly: %{public}s", playlist.name)
            self.loadPlaylistDirectly(playlist: playlist)
        }
    }
    
    private func loadPlaylistDirectly(playlist: Playlist) {
        guard let coordinator = AudioManager.shared.slimClient else {
            showErrorMessage("No connection to LMS server")
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress
        os_log(.info, log: logger, "📂 Loading playlist directly: %{public}s (Player: %{public}s)", playlist.name, playerID)

        // Use different command format for file URLs vs database playlists
        let jsonRPCCommand: [String: Any]
        if let numericId = playlist.originalNumericId {
            // Database playlist with numeric ID - use "playlistcontrol" command
            // LMS automatically starts from beginning (play_index is unreliable)
            os_log(.debug, log: logger, "Using playlistcontrol with ID: %d", numericId)
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlistcontrol", "cmd:load", "playlist_id:\(numericId)"]]
            ]
        } else if let url = playlist.url {
            // File-based playlist - use "playlist load" command with URL and title
            // Material skin passes both URL and title
            let decodedUrl = url.removingPercentEncoding ?? url
            os_log(.debug, log: logger, "Using playlist load with URL: %{public}s", decodedUrl)
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "load", decodedUrl, playlist.name]]
            ]
        } else {
            // Fallback - use the ID directly
            os_log(.debug, log: logger, "Using playlist play with ID: %{public}s", playlist.id)
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "play", playlist.id]]
            ]
        }

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if !response.isEmpty {
                    os_log(.info, log: self.logger, "✅ Playlist loaded successfully: %{public}s", playlist.name)
                    // Push to Now Playing
                    self.pushNowPlayingTemplate()
                } else {
                    os_log(.error, log: self.logger, "❌ Failed to load playlist")
                    self.showErrorMessage("Failed to load playlist. Please check connection and try again.")
                }
            }
        }
    }
    
    private func displayPlaylistTracks(_ tracks: [PlaylistTrack], playlist: Playlist) {
        // Limit to first 16 tracks for performance (CarPlay limitation)
        let tracksToDisplay = Array(tracks.prefix(16))

        // Load artwork for tracks
        loadArtworkForTracks(tracksToDisplay) { [weak self] artworkCache in
            guard let self = self else { return }

            var trackItems: [CPListItem] = []

            // Add "Play All" option at the top
            let playAllItem = CPListItem(
                text: "Play All",
                detailText: "Play entire playlist",
                image: nil,
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )

            playAllItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.loadPlaylistDirectly(playlist: playlist)
                completion()
            }
            trackItems.append(playAllItem)

            // Add individual tracks with artwork
            for track in tracksToDisplay {
                // Use coverID if available, otherwise use track ID as fallback (LMS App pattern)
                let artworkKey = track.artworkURL ?? track.id
                let artwork = artworkCache[artworkKey]

                let item = CPListItem(
                    text: track.title,
                    detailText: track.detailText,
                    image: artwork,
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )

                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    // Use the playlist index from LMS, not the array index
                    if let playlistIndex = track.playlistIndex {
                        self?.playPlaylistTrack(playlist: playlist, trackIndex: playlistIndex, track: track)
                    } else {
                        os_log(.error, log: self?.logger ?? OSLog.default, "❌ Track missing playlist index")
                    }
                    completion()
                }

                trackItems.append(item)
            }

            let tracksTemplate = CPListTemplate(
                title: playlist.name,
                sections: [CPListSection(items: trackItems)]
            )

            self.interfaceController?.pushTemplate(tracksTemplate, animated: true)
            os_log(.info, log: self.logger, "✅ Displayed %d tracks for playlist %{public}s", trackItems.count - 1, playlist.name)
        }
    }
    
    private func playPlaylistTrack(playlist: Playlist, trackIndex: Int, track: PlaylistTrack) {
        os_log(.info, log: logger, "🎯 Playing track %d from playlist: %{public}s", trackIndex, track.title)

        guard let coordinator = AudioManager.shared.slimClient else {
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress

        // Use playlistcontrol with play_index to load and start at specific track
        if let numericId = playlist.originalNumericId {
            let loadCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlistcontrol", "cmd:load", "playlist_id:\(numericId)", "play_index:\(trackIndex)"]]
            ]

            coordinator.sendJSONRPCCommandDirect(loadCommand) { [weak self] loadResponse in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    if !loadResponse.isEmpty {
                        os_log(.info, log: self.logger, "✅ Successfully loaded playlist at track: %{public}s", track.title)
                        self.pushNowPlayingTemplate()
                    } else {
                        os_log(.error, log: self.logger, "❌ Failed to load playlist")
                    }
                }
            }
        } else {
            os_log(.error, log: logger, "❌ Cannot play specific track from non-database playlist")
        }
    }
    
    private func showUpNextQueue() {
        os_log(.info, log: logger, "📋 Showing Up Next queue in CarPlay")

        fetchPlayerStatus { [weak self] status in
            guard let self = self, let status = status else { return }
            self.displayUpNextQueue(from: status)
        }
    }
    
    private func displayUpNextQueue(from status: [String: Any]) {
        // Get playlist info
        let currentIndex = status["playlist_cur_index"] as? Int ?? 0
        let totalTracks = status["playlist_tracks"] as? Int ?? 0
        let playlistName = status["playlist_name"] as? String ?? "Current Queue"

        // Extract track data with both coverID and track ID
        var trackDataArray: [(title: String, artist: String?, duration: Double?, playlistIndex: Int?, trackID: String?, coverID: String?, isCurrentTrack: Bool)] = []

        if let playlistLoop = status["playlist_loop"] as? [[String: Any]] {
            // Limit to first 16 tracks for performance
            let tracksToShow = Array(playlistLoop.prefix(16))

            for (index, trackData) in tracksToShow.enumerated() {
                let title = trackData["title"] as? String ?? "Unknown Track"
                let artist = trackData["artist"] as? String
                let duration = trackData["duration"] as? Double
                let playlistIndex = trackData["playlist index"] as? Int
                let isCurrentTrack = (index == 0)

                // Get track ID
                let trackID: String?
                if let stringID = trackData["id"] as? String {
                    trackID = stringID
                } else if let intID = trackData["id"] as? Int {
                    trackID = String(intID)
                } else {
                    trackID = nil
                }

                // Get coverID if available
                let coverID: String?
                if let stringCoverID = trackData["coverid"] as? String {
                    coverID = stringCoverID
                } else if let intCoverID = trackData["coverid"] as? Int {
                    coverID = String(intCoverID)
                } else {
                    coverID = nil
                }

                trackDataArray.append((title, artist, duration, playlistIndex, trackID, coverID, isCurrentTrack))
            }
        }

        // Load artwork using coverID if available, otherwise track ID as fallback (LMS App pattern)
        var uniqueArtworkIDs = Set<String>()
        for trackData in trackDataArray {
            if let artworkID = trackData.coverID ?? trackData.trackID {
                uniqueArtworkIDs.insert(artworkID)
            }
        }

        var artworkCache: [String: UIImage] = [:]
        let group = DispatchGroup()
        let cacheLock = NSLock()

        for artworkID in uniqueArtworkIDs {
            group.enter()
            loadArtwork(coverID: artworkID) { image in
                if let image = image {
                    cacheLock.lock()
                    artworkCache[artworkID] = image
                    cacheLock.unlock()
                }
                group.leave()
            }
        }

        // Wait for artwork to load (2s timeout for faster playlist/album view display)
        DispatchQueue.global().async {
            _ = group.wait(timeout: .now() + 2.0)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                var queueItems: [CPListItem] = []

                for trackData in trackDataArray {
                    var detailText = trackData.artist ?? ""
                    if let dur = trackData.duration, dur > 0 {
                        let minutes = Int(dur) / 60
                        let seconds = Int(dur) % 60
                        let timeStr = String(format: "%d:%02d", minutes, seconds)
                        detailText = trackData.artist != nil ? "\(trackData.artist!) • \(timeStr)" : timeStr
                    }

                    let displayText = trackData.isCurrentTrack ? "▶︎ \(trackData.title)" : trackData.title

                    // Use coverID if available, otherwise track ID as fallback
                    let artworkKey = trackData.coverID ?? trackData.trackID
                    let artwork = artworkKey != nil ? artworkCache[artworkKey!] : nil

                    let item = CPListItem(
                        text: displayText,
                        detailText: detailText,
                        image: artwork,
                        accessoryImage: nil,
                        accessoryType: trackData.isCurrentTrack ? .none : .disclosureIndicator
                    )

                    // Add handler for non-current tracks to allow jumping
                    if !trackData.isCurrentTrack, let trackIndex = trackData.playlistIndex {
                        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                            self?.jumpToTrack(trackIndex)
                            completion()
                        }
                    }

                    queueItems.append(item)
                }

                // Show message if no tracks
                if queueItems.isEmpty {
                    let emptyItem = CPListItem(
                        text: "No Tracks",
                        detailText: "Queue is empty",
                        image: nil,
                        accessoryImage: nil,
                        accessoryType: .none
                    )
                    queueItems.append(emptyItem)
                }

                let upNextTemplate = CPListTemplate(
                    title: "Up Next (\(currentIndex + 1)/\(totalTracks))",
                    sections: [CPListSection(items: queueItems)]
                )

                self.interfaceController?.pushTemplate(upNextTemplate, animated: true)
                os_log(.info, log: self.logger, "✅ Displayed Up Next queue with %d tracks", queueItems.count)
            }
        }
    }
    
    private func skipToNext() {
        guard let coordinator = AudioManager.shared.slimClient else { return }
        coordinator.sendLockScreenCommand("next")
    }

    private func skipToPrevious() {
        guard let coordinator = AudioManager.shared.slimClient else { return }
        coordinator.sendLockScreenCommand("previous")
    }

    private func jumpToTrack(_ trackIndex: Int) {
        os_log(.info, log: logger, "⏭️ Jumping to track index: %d", trackIndex)

        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available")
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playlist", "index", trackIndex]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if !response.isEmpty {
                    os_log(.info, log: self.logger, "✅ Successfully jumped to track %d", trackIndex)
                    // Pop back to Now Playing screen (one level up from Up Next)
                    self.interfaceController?.popTemplate(animated: true)
                } else {
                    os_log(.error, log: self.logger, "❌ Failed to jump to track")
                }
            }
        }
    }

    // MARK: - Playlist ID Helper

    /// Gets the correct LMS playlist identifier to use in JSON-RPC commands
    /// Priority: 1) originalNumericId, 2) url (decoded), 3) id (fallback)
    private func getPlaylistIdentifier(_ playlist: Playlist) -> String {
        if let numericId = playlist.originalNumericId {
            os_log(.debug, log: logger, "📋 Using numeric ID for playlist: %d", numericId)
            return String(numericId)
        } else if let encodedUrl = playlist.url {
            // URL-decode the URL for JSON-RPC commands (LMS expects decoded URLs)
            let decodedUrl = encodedUrl.removingPercentEncoding ?? encodedUrl
            os_log(.debug, log: logger, "📋 Using URL for playlist: %{public}s (decoded from: %{public}s)", decodedUrl, encodedUrl)
            return decodedUrl
        } else {
            os_log(.debug, log: logger, "📋 Using string ID for playlist: %{public}s", playlist.id)
            return playlist.id
        }
    }

    // MARK: - Data Parsing Helpers

    private func parsePlaylists(_ data: [[String: Any]]) -> [Playlist] {
        return data.compactMap { playlistData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: playlistData)
                return try JSONDecoder().decode(Playlist.self, from: jsonData)
            } catch {
                os_log(.error, log: logger, "❌ Failed to parse playlist: %{public}s", error.localizedDescription)
                return nil
            }
        }
    }

    private func parsePlaylistTracks(_ data: [[String: Any]]) -> [PlaylistTrack] {
        return data.compactMap { trackData in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: trackData)
                return try JSONDecoder().decode(PlaylistTrack.self, from: jsonData)
            } catch {
                os_log(.error, log: logger, "❌ Failed to parse track: %{public}s", error.localizedDescription)
                return nil
            }
        }
    }

    // MARK: - LMS Data Fetching Helpers

    private func fetchPlaylists(completion: @escaping ([Playlist]) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available for playlists")
            completion([])
            return
        }

        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["playlists", 0, 1000, "tags:su"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion([])
                return
            }

            DispatchQueue.main.async {
                guard let result = response["result"] as? [String: Any],
                      let playlistsLoop = result["playlists_loop"] as? [[String: Any]] else {
                    os_log(.error, log: self.logger, "❌ Invalid playlists response format")
                    completion([])
                    return
                }

                let playlists = self.parsePlaylists(playlistsLoop)
                completion(playlists)
            }
        }
    }

    private func fetchPlaylistTracks(playlist: Playlist, completion: @escaping ([PlaylistTrack]) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available for playlist tracks")
            completion([])
            return
        }

        // The playlists tracks query requires the playlist ID as a parameter string
        guard let numericId = playlist.originalNumericId else {
            os_log(.error, log: logger, "❌ Cannot fetch tracks - playlist has no numeric ID")
            completion([])
            return
        }

        os_log(.info, log: logger, "🔍 Fetching tracks for playlist: %{public}s (ID: %d)", playlist.name, numericId)

        // This is a server query, not a player command - use "" for player ID
        // IMPORTANT: Use the format from LMS App - "playlist_id:ID" as a string parameter
        // Tags: d=duration, a=artist, l=album, C=coverid (for artwork)
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["playlists", "tracks", 0, 1000, "playlist_id:\(numericId)", "tags:dalC"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion([])
                return
            }

            DispatchQueue.main.async {
                guard let result = response["result"] as? [String: Any],
                      let tracksLoop = result["playlisttracks_loop"] as? [[String: Any]] else {
                    os_log(.error, log: self.logger, "❌ Invalid playlist tracks response format")
                    completion([])
                    return
                }

                let tracks = self.parsePlaylistTracks(tracksLoop)
                os_log(.info, log: self.logger, "✅ Fetched %d tracks for playlist", tracks.count)
                completion(tracks)
            }
        }
    }

    private func fetchPlayerStatus(completion: @escaping ([String: Any]?) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available for player status")
            completion(nil)
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress
        // Request current track + next 24 tracks (25 total) for Up Next display
        // Tags: I=track_id, R=rating, a=artist, d=duration, C=coverid
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["status", "-", 25, "tags:IRadC"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion(nil)
                return
            }

            DispatchQueue.main.async {
                if let result = response["result"] as? [String: Any] {
                    completion(result)
                } else {
                    os_log(.error, log: self.logger, "❌ Invalid status response format")
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Artwork Loading

    private func loadArtwork(coverID: String?, completion: @escaping (UIImage?) -> Void) {
        guard let coverID = coverID, !coverID.isEmpty else {
            completion(nil)
            return
        }

        let settings = SettingsManager.shared
        // Use simple cover.jpg like LMS App does (not sized version)
        let urlString = "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/music/\(coverID)/cover.jpg"

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        // Create request with 3s timeout (matches other CarPlay artwork loading)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let image = UIImage(data: data) {
                completion(image)
            } else {
                completion(nil)
            }
        }.resume()
    }

    private func loadArtworkForTracks(_ tracks: [PlaylistTrack], completion: @escaping ([String: UIImage]) -> Void) {
        let group = DispatchGroup()
        var artworkCache: [String: UIImage] = [:]
        let cacheLock = NSLock()

        // Only load artwork for first 16 tracks to improve performance
        // CarPlay doesn't support lazy loading on scroll, so we load a limited set upfront
        let tracksToLoad = tracks.prefix(16)

        // Build list of unique IDs to fetch artwork for
        // Use coverID if available, otherwise use track ID as fallback (LMS App pattern)
        var uniqueArtworkIDs = Set<String>()
        for track in tracksToLoad {
            let artworkID = track.artworkURL ?? track.id
            uniqueArtworkIDs.insert(artworkID)
        }

        for artworkID in uniqueArtworkIDs {
            group.enter()
            loadArtwork(coverID: artworkID) { image in
                if let image = image {
                    cacheLock.lock()
                    artworkCache[artworkID] = image
                    cacheLock.unlock()
                }
                group.leave()
            }
        }

        // Wait for images to load (2s timeout for faster playlist/album view display)
        DispatchQueue.global().async {
            _ = group.wait(timeout: .now() + 2.0)
            DispatchQueue.main.async {
                completion(artworkCache)
            }
        }
    }

    // MARK: - Error Handling

    private func showErrorMessage(_ message: String) {
        let errorItem = CPListItem(
            text: "Error",
            detailText: message,
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )

        let errorTemplate = CPListTemplate(
            title: "LyrPlay",
            sections: [CPListSection(items: [errorItem])]
        )

        interfaceController?.pushTemplate(errorTemplate, animated: true)
        os_log(.error, log: logger, "🚗 CarPlay error: %{public}s", message)
    }

    /// Shows connection error state with retry button
    /// Called when initial CarPlay connection fails or network requests timeout
    private func showConnectionError() {
        os_log(.error, log: logger, "🚗 Showing connection error state in CarPlay")

        // Resume button - still available even when disconnected
        let resumeItem = CPListItem(
            text: "▶︎ Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )
        resumeItem.handler = { [weak self] item, completion in
            self?.handleResumePlayback()
            self?.pushNowPlayingTemplate()
            completion()
        }

        // Connection error item with retry action
        let errorItem = CPListItem(
            text: "⚠️ Cannot Connect to Server",
            detailText: "Check network connection and server status",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )

        // Retry button
        let retryItem = CPListItem(
            text: "🔄 Retry Connection",
            detailText: "Attempt to reconnect to LMS server",
            image: nil,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        retryItem.handler = { [weak self] item, completion in
            self?.retryConnection()
            completion()
        }

        let errorTemplate = CPListTemplate(
            title: "LyrPlay",
            sections: [CPListSection(items: [resumeItem, errorItem, retryItem])]
        )

        // Update the root template with error state
        interfaceController?.setRootTemplate(errorTemplate, animated: true) { [weak self] success, error in
            if let error = error {
                os_log(.error, log: self?.logger ?? OSLog.default, "❌ Failed to show error template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self?.logger ?? OSLog.default, "✅ Connection error state displayed")
            }
        }
    }

    /// Attempts to reconnect to LMS server and refresh CarPlay UI
    /// Called when user taps "Retry Connection" button in error state
    private func retryConnection() {
        os_log(.info, log: logger, "🔄 User requested connection retry from CarPlay")

        // Show loading state
        let loadingItem = CPListItem(
            text: "Connecting...",
            detailText: "Attempting to connect to LMS server",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )

        let loadingTemplate = CPListTemplate(
            title: "LyrPlay",
            sections: [CPListSection(items: [loadingItem])]
        )

        interfaceController?.setRootTemplate(loadingTemplate, animated: true)

        // Reinitialize coordinator if needed
        if AudioManager.shared.slimClient == nil {
            os_log(.info, log: logger, "🔧 Reinitializing coordinator for retry...")
            initializeCoordinator()
        } else {
            // Coordinator exists - attempt reconnection
            os_log(.info, log: logger, "🔧 Coordinator exists - attempting reconnect...")
            AudioManager.shared.slimClient?.connect()
        }

        // Check connection status after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            if let coordinator = AudioManager.shared.slimClient, coordinator.isConnected {
                os_log(.info, log: self.logger, "✅ Retry successful - connection established")

                // Show immediate template with resume button
                let immediateTemplate = self.buildImmediateHomeTemplate()
                self.browseTemplate = immediateTemplate
                self.interfaceController?.setRootTemplate(immediateTemplate, animated: true)

                // Load full data in background
                self.refreshHomeTemplateData()
            } else {
                os_log(.error, log: self.logger, "❌ Retry failed - still not connected")
                // Show error state again
                self.showConnectionError()
            }
        }
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        os_log(.info, log: logger, "🎵 Up Next button tapped on Now Playing screen")
        showUpNextQueue()
    }

    // MARK: - Material-Style Home Page

    /// Builds an immediate template with just the Resume item - no network calls
    /// This allows CarPlay UI to appear instantly on connection
    private func buildImmediateHomeTemplate() -> CPListTemplate {
        // Resume Playback item - always available immediately
        let resumeItem = CPListItem(
            text: "▶︎ Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )
        resumeItem.handler = { [weak self] item, completion in
            self?.handleResumePlayback()
            self?.pushNowPlayingTemplate()
            completion()
        }

        // Loading indicator item
        let loadingItem = CPListItem(
            text: "Loading...",
            detailText: "Fetching music library",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )

        let section = CPListSection(items: [resumeItem, loadingItem])
        return CPListTemplate(title: "LyrPlay", sections: [section])
    }

    /// Fetches all home page data in PARALLEL, then updates the template
    private func refreshHomeTemplateData() {
        let fetchStartTime = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: logger, "🔄 Starting parallel data fetch for CarPlay home")

        let group = DispatchGroup()

        // Fetch all data sources in parallel
        group.enter()
        fetchNewMusicWithArtwork { [weak self] albums in
            self?.cachedNewMusic = albums
            os_log(.debug, log: self?.logger ?? OSLog.default, "✅ New Music loaded: %d albums", albums.count)
            group.leave()
        }

        group.enter()
        fetchRandomReleasesWithArtwork { [weak self] albums in
            self?.cachedRandomReleases = albums
            os_log(.debug, log: self?.logger ?? OSLog.default, "✅ Random Releases loaded: %d albums", albums.count)
            group.leave()
        }

        group.enter()
        fetchPlaylists { [weak self] playlists in
            self?.cachedPlaylists = playlists
            os_log(.debug, log: self?.logger ?? OSLog.default, "✅ Playlists loaded: %d items", playlists.count)
            group.leave()
        }

        // TIMEOUT FIX: Use group.wait with timeout instead of group.notify
        // This prevents infinite loading if network requests hang
        // Increased to 10s for better reliability on slower networks (artwork loading can be slow)
        DispatchQueue.global().async { [weak self] in
            let result = group.wait(timeout: .now() + 10.0)

            DispatchQueue.main.async {
                guard let self = self else { return }

                if result == .timedOut {
                    let elapsed = CFAbsoluteTimeGetCurrent() - fetchStartTime
                    os_log(.error, log: self.logger, "❌ Data fetch TIMED OUT after %.3f seconds - showing error", elapsed)
                    self.showConnectionError()
                } else {
                    let elapsed = CFAbsoluteTimeGetCurrent() - fetchStartTime
                    os_log(.info, log: self.logger, "🔄 All data fetched in %.3f seconds - updating template", elapsed)
                    self.updateHomeTemplateWithData()
                }
            }
        }
    }

    /// Updates the home template with cached data
    private func updateHomeTemplateWithData() {
        guard let interfaceController = interfaceController else {
            os_log(.error, log: logger, "❌ No interface controller for template update")
            return
        }

        var items: [CPListTemplateItem] = []

        // Item 1: Resume Playback (always first)
        let resumeItem = CPListItem(
            text: "▶︎ Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )
        resumeItem.handler = { [weak self] item, completion in
            self?.handleResumePlayback()
            self?.pushNowPlayingTemplate()
            completion()
        }
        items.append(resumeItem)

        // Add New Music row if we have albums
        if let newMusicRow = buildAlbumImageRow(cachedNewMusic, title: "New Music") {
            items.append(newMusicRow)
        }

        // Add Random Releases row if we have albums
        if let randomRow = buildAlbumImageRow(cachedRandomReleases, title: "Random Releases") {
            items.append(randomRow)
        }

        // Build sections
        var sections: [CPListSection] = []

        // Section 1: Resume + Album rows (no header)
        sections.append(CPListSection(items: items))

        // Section 2: Playlists with header
        if !cachedPlaylists.isEmpty {
            let playlistItems = cachedPlaylists.prefix(10).map { playlist -> CPListItem in
                let item = CPListItem(
                    text: playlist.name,
                    detailText: playlist.trackCountDisplay,
                    image: nil,
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )
                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    self?.handlePlaylistSelection(playlist: playlist)
                    completion()
                }
                return item
            }
            let playlistsSection = CPListSection(items: playlistItems, header: "Playlists", sectionIndexTitle: nil)
            sections.append(playlistsSection)
        }

        // Create updated template
        let updatedTemplate = CPListTemplate(title: "LyrPlay", sections: sections)
        self.browseTemplate = updatedTemplate

        // Update the root template
        interfaceController.setRootTemplate(updatedTemplate, animated: true) { [weak self] success, error in
            if let error = error {
                os_log(.error, log: self?.logger ?? OSLog.default, "❌ Failed to update template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self?.logger ?? OSLog.default, "✅ Home template updated with full content")
            }
        }
    }

    // MARK: - Legacy buildHomeTemplate (kept for reference, no longer used on connect)

    private func buildHomeTemplate(completion: @escaping (CPListTemplate) -> Void) {
        var items: [CPListTemplateItem] = []

        // Item 1: Resume Playback
        let resumeItem = CPListItem(
            text: "▶︎ Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .none
        )
        resumeItem.handler = { [weak self] item, completion in
            self?.handleResumePlayback()
            self?.pushNowPlayingTemplate()
            completion()
        }
        items.append(resumeItem)

        // Fetch sections sequentially to preserve order
        fetchNewMusicWithArtwork { [weak self] newMusicAlbums in
            guard let self = self else { return }

            // Add New Music row
            if let newMusicRow = self.buildAlbumImageRow(newMusicAlbums, title: "New Music") {
                items.append(newMusicRow)
            }

            // Then fetch Random Releases
            self.fetchRandomReleasesWithArtwork { randomAlbums in
                // Add Random Releases row
                if let randomRow = self.buildAlbumImageRow(randomAlbums, title: "Random Releases") {
                    items.append(randomRow)
                }

                // Finally add playlists
                self.fetchPlaylists { playlists in
                    // Add playlist items
                    let playlistItems = playlists.prefix(10).map { playlist -> CPListItem in
                        let item = CPListItem(
                            text: playlist.name,
                            detailText: playlist.trackCountDisplay,
                            image: nil,
                            accessoryImage: nil,
                            accessoryType: .disclosureIndicator
                        )
                        item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                            self?.handlePlaylistSelection(playlist: playlist)
                            completion()
                        }
                        return item
                    }

                    // Create two sections
                    var sections: [CPListSection] = []

                    // Section 1: Resume + Album rows (no header)
                    sections.append(CPListSection(items: items))

                    // Section 2: Playlists with header
                    if !playlistItems.isEmpty {
                        let playlistsSection = CPListSection(items: playlistItems, header: "Playlists", sectionIndexTitle: nil)
                        sections.append(playlistsSection)
                    }

                    let template = CPListTemplate(title: "LyrPlay", sections: sections)
                    completion(template)
                }
            }
        }
    }

    private func buildAlbumImageRow(_ albums: [Album], title: String) -> CPListImageRowItem? {
        guard !albums.isEmpty else { return nil }

        // Create grid images (up to 6 items for CPListImageRowItem)
        // Render each image into a new bitmap context to ensure unique UIImage instances
        let gridImages = albums.prefix(6).map { album -> UIImage in
            if let artwork = album.artwork {
                // Render into a new graphics context to create a fresh UIImage
                let renderer = UIGraphicsImageRenderer(size: artwork.size)
                return renderer.image { context in
                    artwork.draw(at: .zero)
                }
            }
            return createPlaceholderImage()
        }

        let imageRowItem = CPListImageRowItem(text: title, images: gridImages)

        // Set up tap handler for each image
        imageRowItem.listImageRowHandler = { [weak self] (item: CPListImageRowItem, index: Int, completion: @escaping () -> Void) in
            guard index < albums.count else {
                completion()
                return
            }
            self?.playAlbum(albums[index])
            completion()
        }

        // Handler for tapping the title text - show full list
        imageRowItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
            if title == "New Music" {
                self?.showFullNewMusicList()
            } else if title == "Random Releases" {
                self?.showFullRandomReleasesList()
            }
            completion()
        }

        return imageRowItem
    }

    private func buildPlaylistImageRow(_ playlists: [Playlist]) -> CPListImageRowItem? {
        guard !playlists.isEmpty else { return nil }

        // Create grid images (up to 6 items)
        let gridImages = playlists.prefix(6).map { playlist -> UIImage in
            return createPlaylistPlaceholderImage()
        }

        let imageRowItem = CPListImageRowItem(text: "Playlists", images: gridImages)

        // Set up tap handler for each image
        imageRowItem.listImageRowHandler = { [weak self] (item: CPListImageRowItem, index: Int, completion: @escaping () -> Void) in
            guard index < playlists.count else {
                completion()
                return
            }
            self?.handlePlaylistSelection(playlist: playlists[index])
            completion()
        }

        // Handler for tapping the title text - show full playlists
        imageRowItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
            self?.showPlaylists()
            completion()
        }

        return imageRowItem
    }

    private func createPlaceholderImage() -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Gray background
            UIColor.systemGray4.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Music note icon
            let iconSize: CGFloat = 100
            let iconRect = CGRect(x: (size.width - iconSize) / 2,
                                 y: (size.height - iconSize) / 2,
                                 width: iconSize,
                                 height: iconSize)
            if let icon = UIImage(systemName: "music.note")?.withTintColor(.systemGray, renderingMode: .alwaysOriginal) {
                icon.draw(in: iconRect)
            }
        }
    }

    private func createPlaylistPlaceholderImage() -> UIImage {
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Teal background
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Music list icon
            let iconSize: CGFloat = 100
            let iconRect = CGRect(x: (size.width - iconSize) / 2,
                                 y: (size.height - iconSize) / 2,
                                 width: iconSize,
                                 height: iconSize)
            if let icon = UIImage(systemName: "music.note.list")?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                icon.draw(in: iconRect)
            }
        }
    }

    private func showFullNewMusicList() {
        // TODO: Implement full New Music list view
        os_log(.info, log: logger, "📋 Show full New Music list")
    }

    private func showFullRandomReleasesList() {
        // TODO: Implement full Random Releases list view
        os_log(.info, log: logger, "📋 Show full Random Releases list")
    }

    private func fetchNewMusicWithArtwork(completion: @escaping ([Album]) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            completion([])
            return
        }

        // Material skin: ["albums"] with ["sort:new", "tags:aajlqswyKSS24"]
        // Request 6 albums for faster CarPlay loading
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["albums", 0, 6, "sort:new", "tags:ajlqy"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion([])
                return
            }

            DispatchQueue.main.async {
                guard let result = response["result"] as? [String: Any],
                      let albumsLoop = result["albums_loop"] as? [[String: Any]] else {
                    completion([])
                    return
                }

                let albums = albumsLoop.compactMap { albumData -> Album? in
                    guard let id = albumData["id"] as? String ?? (albumData["id"] as? Int).map(String.init),
                          let name = albumData["album"] as? String else {
                        return nil
                    }

                    let artist = albumData["artist"] as? String ?? "Unknown Artist"
                    let artworkTrackId = albumData["artwork_track_id"] as? String

                    return Album(id: id, name: name, artist: artist, artworkTrackId: artworkTrackId, artwork: nil)
                }

                // Load artwork for all albums
                self.loadArtworkForAlbums(albums, completion: completion)
            }
        }
    }

    private func fetchRandomReleasesWithArtwork(completion: @escaping ([Album]) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            completion([])
            return
        }

        // Material skin: ["albums"] with ["sort:random", "tags:aajlqswyKSS24"]
        // Request 6 albums for faster CarPlay loading
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["albums", 0, 6, "sort:random", "tags:ajlqy"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion([])
                return
            }

            DispatchQueue.main.async {
                guard let result = response["result"] as? [String: Any],
                      let albumsLoop = result["albums_loop"] as? [[String: Any]] else {
                    completion([])
                    return
                }

                let albums = albumsLoop.compactMap { albumData -> Album? in
                    guard let id = albumData["id"] as? String ?? (albumData["id"] as? Int).map(String.init),
                          let name = albumData["album"] as? String else {
                        return nil
                    }

                    let artist = albumData["artist"] as? String ?? "Unknown Artist"
                    let artworkTrackId = albumData["artwork_track_id"] as? String

                    return Album(id: id, name: name, artist: artist, artworkTrackId: artworkTrackId, artwork: nil)
                }

                // Load artwork for all albums
                self.loadArtworkForAlbums(albums, completion: completion)
            }
        }
    }

    private func loadArtworkForAlbums(_ albums: [Album], completion: @escaping ([Album]) -> Void) {
        guard !albums.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let settings = SettingsManager.shared

        // Create a thread-safe dictionary to store results
        var results: [Int: Album] = [:]
        let lock = NSLock()

        for (index, album) in albums.enumerated() {
            group.enter()

            // Use artwork_track_id for artwork URL (NOT album id!)
            // LMS uses artwork_track_id to map to the correct cover art
            guard let artworkId = album.artworkTrackId else {
                os_log(.debug, log: self.logger, "⚠️ No artwork_track_id for album %{public}s (ID: %{public}s)", album.name, album.id)
                lock.lock()
                results[index] = album
                lock.unlock()
                group.leave()
                continue
            }

            let urlString = "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/music/\(artworkId)/cover.jpg"

            guard let url = URL(string: urlString) else {
                os_log(.error, log: self.logger, "❌ Invalid artwork URL for album ID: %{public}s", album.id)
                lock.lock()
                results[index] = album
                lock.unlock()
                group.leave()
                continue
            }

            // Capture album and index in closure
            let albumCopy = album
            let indexCopy = index

            // Create request with 3s timeout (matches other CarPlay artwork loading)
            var request = URLRequest(url: url)
            request.timeoutInterval = 3.0

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                defer { group.leave() }

                if let error = error {
                    os_log(.error, log: self?.logger ?? OSLog.default,
                           "❌ Artwork load failed for %{public}s: %{public}s", albumCopy.name, error.localizedDescription)
                    lock.lock()
                    results[indexCopy] = albumCopy
                    lock.unlock()
                    return
                }

                if let data = data, let image = UIImage(data: data) {
                    let updatedAlbum = Album(id: albumCopy.id, name: albumCopy.name, artist: albumCopy.artist, artworkTrackId: albumCopy.artworkTrackId, artwork: image)
                    lock.lock()
                    results[indexCopy] = updatedAlbum
                    lock.unlock()
                } else {
                    os_log(.error, log: self?.logger ?? OSLog.default,
                           "❌ Failed to create image for %{public}s", albumCopy.name)
                    lock.lock()
                    results[indexCopy] = albumCopy
                    lock.unlock()
                }
            }.resume()
        }

        group.notify(queue: .main) {
            // Reconstruct array in original order, preserving exact album positions
            // Use map instead of compactMap to ensure indexes stay aligned
            let sortedAlbums = albums.enumerated().map { index, originalAlbum in
                results[index] ?? originalAlbum
            }
            completion(sortedAlbums)
        }
    }

    /// Handle album selection - shows track list instead of immediate play
    private func playAlbum(_ album: Album) {
        os_log(.info, log: logger, "🎵 Selected album: %{public}s by %{public}s", album.name, album.artist)

        // Fetch album tracks and show track list (similar to playlist behavior)
        fetchAlbumTracks(album: album) { [weak self] tracks in
            guard let self = self else { return }

            if tracks.isEmpty {
                // Fallback: just load the album directly if no tracks found
                os_log(.info, log: self.logger, "📂 No tracks found, loading album directly: %{public}s", album.name)
                self.loadAlbumDirectly(album: album)
            } else {
                os_log(.info, log: self.logger, "🎶 Found %d tracks, displaying: %{public}s", tracks.count, album.name)
                self.displayAlbumTracks(tracks, album: album)
            }
        }
    }

    /// Fetches tracks for an album from LMS
    private func fetchAlbumTracks(album: Album, completion: @escaping ([PlaylistTrack]) -> Void) {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available for album tracks")
            completion([])
            return
        }

        os_log(.info, log: logger, "🔍 Fetching tracks for album: %{public}s (ID: %{public}s)", album.name, album.id)

        // Use "titles" query with album_id filter
        // Tags: d=duration, a=artist, l=album, C=coverid, t=tracknum
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["titles", 0, 100, "album_id:\(album.id)", "tags:daltC"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else {
                completion([])
                return
            }

            DispatchQueue.main.async {
                guard let result = response["result"] as? [String: Any],
                      let titlesLoop = result["titles_loop"] as? [[String: Any]] else {
                    os_log(.error, log: self.logger, "❌ Invalid album tracks response format")
                    completion([])
                    return
                }

                // Parse tracks from titles_loop response
                let tracks = titlesLoop.enumerated().compactMap { (index, trackData) -> PlaylistTrack? in
                    // Handle track ID
                    let trackId: String
                    if let stringId = trackData["id"] as? String {
                        trackId = stringId
                    } else if let intId = trackData["id"] as? Int {
                        trackId = String(intId)
                    } else {
                        trackId = UUID().uuidString
                    }

                    let title = trackData["title"] as? String ?? "Unknown Track"
                    let artist = trackData["artist"] as? String
                    let albumName = trackData["album"] as? String
                    let duration = trackData["duration"] as? Double
                    // Handle tracknum as Int or String
                    let trackNum: Int?
                    if let intNum = trackData["tracknum"] as? Int {
                        trackNum = intNum
                    } else if let strNum = trackData["tracknum"] as? String, let parsed = Int(strNum) {
                        trackNum = parsed
                    } else if let numNum = trackData["tracknum"] as? NSNumber {
                        trackNum = numNum.intValue
                    } else {
                        trackNum = nil
                    }

                    // Get coverid for artwork
                    let coverID: String?
                    if let stringCoverID = trackData["coverid"] as? String {
                        coverID = stringCoverID
                    } else if let intCoverID = trackData["coverid"] as? Int {
                        coverID = String(intCoverID)
                    } else {
                        coverID = nil
                    }

                    return PlaylistTrack(
                        id: trackId,
                        title: title,
                        artist: artist,
                        album: albumName,
                        duration: duration,
                        trackNumber: trackNum,
                        artworkURL: coverID,
                        albumID: album.id,
                        artistID: nil,
                        playlistIndex: index  // Use array index as track position in album
                    )
                }

                os_log(.info, log: self.logger, "✅ Fetched %d tracks for album", tracks.count)
                completion(tracks)
            }
        }
    }

    /// Display album tracks in a CarPlay list template
    private func displayAlbumTracks(_ tracks: [PlaylistTrack], album: Album) {
        // Sort tracks by track number for proper display order
        let sortedTracks = tracks.sorted {
            ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
        }

        // Limit to first 16 tracks for performance (CarPlay limitation)
        let tracksToDisplay = Array(sortedTracks.prefix(16))

        // Load artwork for tracks
        loadArtworkForTracks(tracksToDisplay) { [weak self] artworkCache in
            guard let self = self else { return }

            var trackItems: [CPListItem] = []

            // Add "Play All" option at the top
            let playAllItem = CPListItem(
                text: "Play All",
                detailText: "Play entire album",
                image: album.artwork,  // Use album artwork for Play All
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )

            playAllItem.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                self?.loadAlbumDirectly(album: album)
                completion()
            }
            trackItems.append(playAllItem)

            // Add individual tracks with artwork
            for (index, track) in tracksToDisplay.enumerated() {
                // Use coverID if available, otherwise use track ID as fallback
                let artworkKey = track.artworkURL ?? track.id
                let artwork = artworkCache[artworkKey]

                // Format detail text with track number if available
                var detailText = track.artist ?? album.artist
                if let trackNum = track.trackNumber {
                    detailText = "Track \(trackNum) • \(detailText)"
                }

                // Format duration
                if let duration = track.duration, duration > 0 {
                    let minutes = Int(duration) / 60
                    let seconds = Int(duration) % 60
                    let timeStr = String(format: "%d:%02d", minutes, seconds)
                    detailText = "\(detailText) • \(timeStr)"
                }

                let item = CPListItem(
                    text: track.title,
                    detailText: detailText,
                    image: artwork ?? album.artwork,  // Fall back to album artwork
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )

                item.handler = { [weak self] (item: CPSelectableListItem, completion: @escaping () -> Void) in
                    // Use trackNumber-1 since LMS loads albums in track number order (1-based to 0-based)
                    let trackIndex = (track.trackNumber ?? 1) - 1
                    self?.playAlbumTrack(album: album, trackIndex: trackIndex, track: track)
                    completion()
                }

                trackItems.append(item)
            }

            let tracksTemplate = CPListTemplate(
                title: album.name,
                sections: [CPListSection(items: trackItems)]
            )

            self.interfaceController?.pushTemplate(tracksTemplate, animated: true)
            os_log(.info, log: self.logger, "✅ Displayed %d tracks for album %{public}s", trackItems.count - 1, album.name)
        }
    }

    /// Plays album starting from a specific track
    private func playAlbumTrack(album: Album, trackIndex: Int, track: PlaylistTrack) {
        os_log(.info, log: logger, "🎯 Playing track %d from album: %{public}s", trackIndex, track.title)

        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ No coordinator available")
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress

        // Use playlistcontrol with play_index to load album and start at specific track
        let loadCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playlistcontrol", "cmd:load", "album_id:\(album.id)", "play_index:\(trackIndex)"]]
        ]

        coordinator.sendJSONRPCCommandDirect(loadCommand) { [weak self] loadResponse in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if !loadResponse.isEmpty {
                    os_log(.info, log: self.logger, "✅ Successfully loaded album at track: %{public}s", track.title)
                    self.pushNowPlayingTemplate()
                } else {
                    os_log(.error, log: self.logger, "❌ Failed to load album at track")
                }
            }
        }
    }

    /// Loads and plays entire album from the beginning
    private func loadAlbumDirectly(album: Album) {
        os_log(.info, log: logger, "📂 Loading album directly: %{public}s", album.name)

        guard let coordinator = AudioManager.shared.slimClient else {
            showErrorMessage("No connection to LMS server")
            return
        }

        let playerID = SettingsManager.shared.playerMACAddress
        let jsonRPCCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playlistcontrol", "cmd:load", "album_id:\(album.id)"]]
        ]

        coordinator.sendJSONRPCCommandDirect(jsonRPCCommand) { [weak self] response in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if !response.isEmpty {
                    os_log(.info, log: self.logger, "✅ Album loaded successfully: %{public}s", album.name)
                    self.pushNowPlayingTemplate()
                } else {
                    os_log(.error, log: self.logger, "❌ Failed to load album")
                    self.showErrorMessage("Failed to load album. Please check connection and try again.")
                }
            }
        }
    }

    // MARK: - Shuffle Button Icon Updates

    /// Updates shuffle button icon based on LMS shuffle mode
    /// - Parameter mode: LMS shuffle mode (0=off, 1=songs, 2=albums)
    private func updateShuffleButtonIcon(for mode: Int) {
        guard let nowPlayingTemplate = interfaceController?.topTemplate as? CPNowPlayingTemplate else {
            return
        }

        // Choose SF Symbol based on shuffle mode
        let iconName: String
        switch mode {
        case 1:
            iconName = "shuffle.fill"  // Songs shuffle - FILLED (active/pressed look)
        case 2:
            iconName = "shuffle.circle"  // Albums shuffle - circle variant
        default:
            iconName = "shuffle"  // Off - outline (inactive)
        }

        guard let image = UIImage(systemName: iconName) else {
            os_log(.error, log: logger, "❌ Failed to load shuffle icon: %{public}s", iconName)
            return
        }

        // Create new button with updated icon
        let shuffleButton = CPNowPlayingImageButton(image: image) { [weak self] button in
            os_log(.info, log: self?.logger ?? OSLog.default, "🔀 CarPlay shuffle button tapped")

            guard let coordinator = AudioManager.shared.slimClient else {
                os_log(.error, log: self?.logger ?? OSLog.default, "❌ Coordinator unavailable")
                return
            }

            coordinator.toggleShuffleMode { newMode in
                DispatchQueue.main.async {
                    self?.updateShuffleButtonIcon(for: newMode)
                }
            }
        }

        nowPlayingTemplate.updateNowPlayingButtons([shuffleButton])
        os_log(.info, log: logger, "🔀 Shuffle button icon updated: %{public}s (mode %d)",
               iconName, mode)
    }
}

// MARK: - Supporting Models

struct Album {
    let id: String
    let name: String
    let artist: String
    let artworkTrackId: String?  // LMS artwork_track_id field for cover art URLs
    let artwork: UIImage?
}
