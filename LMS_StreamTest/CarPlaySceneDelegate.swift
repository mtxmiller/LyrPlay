import UIKit
import CarPlay
import os.log

@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")
    var interfaceController: CPInterfaceController?
    private var browseTemplate: CPListTemplate?

        // MARK: - Services

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        os_log(.info, log: logger, "🚗 CARPLAY WILL CONNECT")
        os_log(.info, log: logger, "  Template Scene: %{public}s", String(describing: templateApplicationScene))
        os_log(.info, log: logger, "  Interface Controller: %{public}s", String(describing: interfaceController))
        os_log(.info, log: logger, "  Session: %{public}s", String(describing: templateApplicationScene.session))

        self.interfaceController = interfaceController
        os_log(.info, log: logger, "  ✅ Interface controller stored")

        // Initialize coordinator if needed
        if AudioManager.shared.slimClient == nil {
            initializeCoordinator()
        }

        // Create Browse list with CPListTemplate
        os_log(.info, log: logger, "  Creating Browse template...")

        // Create Resume Playback list item
        let resumeItem = CPListItem(
            text: "Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        resumeItem.handler = { [weak self] item, completion in
            guard let self = self else {
                completion()
                return
            }

            // Start playback
            self.handleResumePlayback()

            // Push Now Playing template onto navigation stack
            self.pushNowPlayingTemplate()

            completion()
        }

        // Create Playlists list item
        let playlistsItem = CPListItem(
            text: "Playlists",
            detailText: "Browse and play your music playlists",
            image: nil,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        playlistsItem.handler = { [weak self] item, completion in
            guard let self = self else {
                completion()
                return
            }

            // Show playlists
            self.showPlaylists()

            completion()
        }

        // Create section with all items (Up Next removed - it's now on Now Playing template)
        let browseSection = CPListSection(items: [resumeItem, playlistsItem])

        // Create Browse list template
        let browseTemplate = CPListTemplate(title: "LyrPlay", sections: [browseSection])
        self.browseTemplate = browseTemplate
        os_log(.info, log: logger, "  ✅ Browse template created with playlists")

        // Configure Now Playing template with Up Next button
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        nowPlayingTemplate.isUpNextButtonEnabled = true
        nowPlayingTemplate.add(self)  // Add self as observer for up next button taps
        os_log(.info, log: logger, "  ✅ Configured Now Playing template with Up Next button")

        // Set Browse template as root (NOT in a tab bar - CPNowPlayingTemplate can't be in tab bar)
        os_log(.info, log: logger, "  Setting Browse template as root...")
        interfaceController.setRootTemplate(browseTemplate, animated: false) { success, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self.logger, "  ✅ Browse template set successfully as root")
            } else {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: success=false, no error")
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
            // Include play_index:0 to start from the beginning
            os_log(.debug, log: logger, "Using playlistcontrol with ID: %d", numericId)
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlistcontrol", "cmd:load", "playlist_id:\(numericId)", "play_index:0"]]
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
        // Limit to first 25 tracks for performance (CarPlay limitation)
        let tracksToDisplay = Array(tracks.prefix(25))

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
            // Limit to first 25 tracks for performance
            let tracksToShow = Array(playlistLoop.prefix(25))

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

        // Wait for artwork to load (with timeout), then build UI
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

        URLSession.shared.dataTask(with: url) { data, response, error in
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

        // Only load artwork for first 25 tracks to improve performance
        // CarPlay doesn't support lazy loading on scroll, so we load a limited set upfront
        let tracksToLoad = tracks.prefix(25)

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

        // Wait for images to load (shorter timeout since we're loading fewer)
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

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        os_log(.info, log: logger, "🎵 Up Next button tapped on Now Playing screen")
        showUpNextQueue()
    }
}
