//
//  IntentHandler.swift
//  LyrPlayIntents
//
//  Siri Intents Extension for LyrPlay
//  Handles voice commands like "Hey Siri, play Taylor Swift in LyrPlay"
//

import Intents
import os.log

class IntentHandler: INExtension, INPlayMediaIntentHandling {

    private let logger = OSLog(subsystem: "com.lmsstream.intents", category: "IntentHandler")

    // MARK: - Timeout-Aware URLSession

    /// Ephemeral session with 4s total timeout (covers TCP connection + response).
    /// Siri kills extensions after ~10 seconds, so each HTTP call must finish fast.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 4.0
        config.timeoutIntervalForRequest = 4.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - App Group Settings

    private var sharedDefaults: UserDefaults? {
        return UserDefaults(suiteName: "group.elm.LyrPlay")
    }

    private var serverHost: String {
        return sharedDefaults?.string(forKey: "serverHost") ?? ""
    }

    private var serverWebPort: Int {
        return sharedDefaults?.integer(forKey: "serverWebPort") ?? 9000
    }

    private var serverUsername: String {
        return sharedDefaults?.string(forKey: "serverUsername") ?? ""
    }

    private var serverPassword: String {
        return sharedDefaults?.string(forKey: "serverPassword") ?? ""
    }

    private var playerMAC: String {
        return sharedDefaults?.string(forKey: "playerMAC") ?? ""
    }

    // MARK: - INPlayMediaIntentHandling

    override func handler(for intent: INIntent) -> Any {
        return self
    }

    func resolveMediaItems(for intent: INPlayMediaIntent,
                          with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {

        guard !serverHost.isEmpty else {
            os_log(.error, log: logger, "Server not configured in App Group")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        guard let searchTerm = intent.mediaSearch?.mediaName else {
            os_log(.error, log: logger, "No search term provided")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        os_log(.info, log: logger, "Searching for: %{public}s", searchTerm)

        // Search in priority order: Artists -> Albums -> Tracks -> Global
        searchArtists(query: searchTerm) { [weak self] artistResult in
            guard let self = self else { return }

            if let mediaItem = artistResult {
                os_log(.info, log: self.logger, "Found artist: %{public}s", mediaItem.title ?? "unknown")
                completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
                return
            }

            self.searchAlbums(query: searchTerm) { albumResult in
                if let mediaItem = albumResult {
                    os_log(.info, log: self.logger, "Found album: %{public}s", mediaItem.title ?? "unknown")
                    completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
                    return
                }

                self.searchTracks(query: searchTerm) { trackResult in
                    if let mediaItem = trackResult {
                        os_log(.info, log: self.logger, "Found track: %{public}s", mediaItem.title ?? "unknown")
                        completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
                        return
                    }

                    self.globalSearch(query: searchTerm) { globalResult in
                        if let mediaItem = globalResult {
                            os_log(.info, log: self.logger, "Found via global search: %{public}s", mediaItem.title ?? "unknown")
                            completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
                        } else {
                            os_log(.error, log: self.logger, "No results found for: %{public}s", searchTerm)
                            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                        }
                    }
                }
            }
        }
    }

    func handle(intent: INPlayMediaIntent,
               completion: @escaping (INPlayMediaIntentResponse) -> Void) {

        guard let mediaItem = intent.mediaItems?.first,
              let identifier = mediaItem.identifier,
              !identifier.isEmpty else {
            os_log(.error, log: logger, "No media identifier to play")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        guard !playerMAC.isEmpty else {
            os_log(.error, log: logger, "No player MAC configured")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        os_log(.info, log: logger, "Sending playback command directly: %{public}s", identifier)

        // Send playlistcontrol command directly to LMS from the extension.
        // No handoff to main app needed — LMS starts streaming to the player.
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerMAC, ["playlistcontrol", "cmd:load", identifier]]
        ]

        sendJSONRPCCommand(command) { [weak self] response in
            if let response = response, response["error"] == nil {
                os_log(.info, log: self?.logger ?? OSLog.default, "Playback started successfully")
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
            } else {
                os_log(.error, log: self?.logger ?? OSLog.default, "Playback command failed")
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }

    // MARK: - LMS Search Methods

    private func searchArtists(query: String, completion: @escaping (INMediaItem?) -> Void) {
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["artists", 0, 10, "tags:s", "search:\(query)"]]
        ]

        sendJSONRPCCommand(command) { [weak self] response in
            guard let self = self,
                  let result = response?["result"] as? [String: Any],
                  let artists = result["artists_loop"] as? [[String: Any]],
                  let firstArtist = artists.first,
                  let artistId = firstArtist["id"] as? Int,
                  let artistName = firstArtist["artist"] as? String else {
                os_log(.debug, log: self?.logger ?? OSLog.default, "No artists found")
                completion(nil)
                return
            }

            let mediaItem = INMediaItem(
                identifier: "artist_id:\(artistId)",
                title: artistName,
                type: .music,
                artwork: nil
            )
            completion(mediaItem)
        }
    }

    private func searchAlbums(query: String, completion: @escaping (INMediaItem?) -> Void) {
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["albums", 0, 10, "tags:ljy", "search:\(query)"]]
        ]

        sendJSONRPCCommand(command) { [weak self] response in
            guard let self = self,
                  let result = response?["result"] as? [String: Any],
                  let albums = result["albums_loop"] as? [[String: Any]],
                  let firstAlbum = albums.first,
                  let albumId = firstAlbum["id"] as? Int,
                  let albumTitle = firstAlbum["album"] as? String else {
                os_log(.debug, log: self?.logger ?? OSLog.default, "No albums found")
                completion(nil)
                return
            }

            let mediaItem = INMediaItem(
                identifier: "album_id:\(albumId)",
                title: albumTitle,
                type: .music,
                artwork: nil
            )
            completion(mediaItem)
        }
    }

    private func searchTracks(query: String, completion: @escaping (INMediaItem?) -> Void) {
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["tracks", 0, 10, "tags:dlt", "search:\(query)"]]
        ]

        sendJSONRPCCommand(command) { [weak self] response in
            guard let self = self,
                  let result = response?["result"] as? [String: Any],
                  let tracks = result["tracks_loop"] as? [[String: Any]],
                  let firstTrack = tracks.first,
                  let trackId = firstTrack["id"] as? Int,
                  let trackTitle = firstTrack["title"] as? String else {
                os_log(.debug, log: self?.logger ?? OSLog.default, "No tracks found")
                completion(nil)
                return
            }

            let mediaItem = INMediaItem(
                identifier: "track_id:\(trackId)",
                title: trackTitle,
                type: .music,
                artwork: nil
            )
            completion(mediaItem)
        }
    }

    private func globalSearch(query: String, completion: @escaping (INMediaItem?) -> Void) {
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["globalsearch", "items", 0, 10, "menu:1", "search:\(query)"]]
        ]

        sendJSONRPCCommand(command) { [weak self] response in
            guard let self = self,
                  let result = response?["result"] as? [String: Any],
                  let items = result["item_loop"] as? [[String: Any]],
                  let firstItem = items.first else {
                os_log(.debug, log: self?.logger ?? OSLog.default, "No global search results")
                completion(nil)
                return
            }

            var identifier: String?
            var title: String?

            if let artistId = firstItem["artist_id"] as? Int {
                identifier = "artist_id:\(artistId)"
                title = firstItem["artist"] as? String
            } else if let albumId = firstItem["album_id"] as? Int {
                identifier = "album_id:\(albumId)"
                title = firstItem["album"] as? String
            } else if let trackId = firstItem["track_id"] as? Int {
                identifier = "track_id:\(trackId)"
                title = firstItem["title"] as? String
            }

            guard let id = identifier, let itemTitle = title else {
                os_log(.debug, log: self.logger, "Could not extract identifier from global search result")
                completion(nil)
                return
            }

            let mediaItem = INMediaItem(
                identifier: id,
                title: itemTitle,
                type: .music,
                artwork: nil
            )
            completion(mediaItem)
        }
    }

    // MARK: - JSON-RPC Helper

    /// Send JSON-RPC command to LMS server.
    /// This is a standalone copy of the JSON-RPC pattern from SlimProtoCoordinator,
    /// because the Intents Extension runs in a separate process and cannot access
    /// the main app's classes.
    private func sendJSONRPCCommand(_ command: [String: Any],
                                   completion: @escaping ([String: Any]?) -> Void) {

        let urlString = "http://\(serverHost):\(serverWebPort)/jsonrpc.js"
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid server URL: %{public}s", urlString)
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("LyrPlay Siri Extension", forHTTPHeaderField: "User-Agent")

        // Add HTTP Basic Auth if credentials provided
        if !serverUsername.isEmpty {
            let authString = "\(serverUsername):\(serverPassword)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: command, options: [])
        } catch {
            os_log(.error, log: logger, "Failed to serialize JSON command: %{public}s", error.localizedDescription)
            completion(nil)
            return
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                os_log(.error, log: self.logger, "Network error: %{public}s", error.localizedDescription)
                completion(nil)
                return
            }

            guard let data = data else {
                os_log(.error, log: self.logger, "No data received")
                completion(nil)
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    completion(json)
                } else {
                    os_log(.error, log: self.logger, "Invalid JSON response")
                    completion(nil)
                }
            } catch {
                os_log(.error, log: self.logger, "JSON parse error: %{public}s", error.localizedDescription)
                completion(nil)
            }
        }

        task.resume()
    }
}
