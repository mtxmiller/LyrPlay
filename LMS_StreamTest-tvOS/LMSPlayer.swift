import Foundation

/// One LMS player, from JSON-RPC `players 0 100` (bd 9dtq, GH #103).
struct LMSPlayer: Identifiable, Equatable {
    let id: String          // playerid (MAC)
    let name: String
    let model: String
    let isConnected: Bool
    let isPoweredOn: Bool
    let isPlaying: Bool
}

/// Players synced together, from JSON-RPC `syncgroups ?`.
struct LMSSyncGroup: Equatable {
    let memberIDs: [String]
}

/// One row of the player picker: a single player, or a synced group shown
/// as one row (commands sent to any member act on the whole group).
struct PlayerChoice: Identifiable, Equatable {
    /// The player id commands go to. For a group, its first connected member.
    let id: String
    let name: String
    let members: [LMSPlayer]
    let isThisDevice: Bool

    var isGroup: Bool { members.count > 1 }
    var isConnected: Bool { members.contains { $0.isConnected } }
    var isPoweredOn: Bool { members.contains { $0.isPoweredOn } }
    var isPlaying: Bool { members.contains { $0.isPlaying } }
}

enum PlayerList {
    static func players(from result: [String: Any]) -> [LMSPlayer] {
        guard let loop = result["players_loop"] as? [[String: Any]] else { return [] }
        return loop.compactMap { item in
            guard let id = item["playerid"] as? String, !id.isEmpty else { return nil }
            return LMSPlayer(
                id: id,
                name: (item["name"] as? String) ?? id,
                model: (item["modelname"] as? String) ?? (item["model"] as? String) ?? "",
                isConnected: int(item["connected"]) == 1,
                isPoweredOn: int(item["power"]) == 1,
                isPlaying: int(item["isplaying"]) == 1
            )
        }
    }

    static func syncGroups(from result: [String: Any]) -> [LMSSyncGroup] {
        guard let loop = result["syncgroups_loop"] as? [[String: Any]] else { return [] }
        return loop.compactMap { item in
            guard let members = item["sync_members"] as? String else { return nil }
            let ids = members.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return ids.count > 1 ? LMSSyncGroup(memberIDs: ids) : nil
        }
    }

    /// Picker rows: this device first (with its group, if synced), then the
    /// other groups and players by name.
    static func choices(players: [LMSPlayer], groups: [LMSSyncGroup], thisDeviceID: String) -> [PlayerChoice] {
        let byID = Dictionary(players.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let thisID = thisDeviceID.lowercased()
        var grouped = Set<String>()
        var result: [PlayerChoice] = []

        for group in groups {
            let members = group.memberIDs.compactMap { byID[$0.lowercased()] }
            guard members.count > 1 else { continue }
            members.forEach { grouped.insert($0.id.lowercased()) }
            let containsThis = members.contains { $0.id.lowercased() == thisID }
            // Commands to this device's own id when it is in the group;
            // otherwise the first connected member.
            let target = containsThis
                ? thisDeviceID
                : (members.first { $0.isConnected } ?? members[0]).id
            result.append(PlayerChoice(
                id: target,
                name: members.map(\.name).joined(separator: " + "),
                members: members,
                isThisDevice: containsThis
            ))
        }
        for player in players where !grouped.contains(player.id.lowercased()) {
            result.append(PlayerChoice(
                id: player.id,
                name: player.name,
                members: [player],
                isThisDevice: player.id.lowercased() == thisID
            ))
        }
        return result.sorted { a, b in
            if a.isThisDevice != b.isThisDevice { return a.isThisDevice }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        case let b as Bool: return b ? 1 : 0
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

/// What another player is doing, from `<id> status - 1 tags:adlcKN`.
struct PlayerStatus: Equatable {
    var mode: String = "stop"          // play | pause | stop
    var time: Double = 0
    var duration: Double = 0
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var coverID: String? = nil
    var artworkURL: String? = nil
    var volume: Int = 0                // 0...100; negative = muted
    var repeatMode: Int = 0
    var shuffleMode: Int = 0
    var isPoweredOn: Bool = true
    var hasTrack: Bool = false

    var isPlaying: Bool { mode == "play" }

    static func parse(_ result: [String: Any]) -> PlayerStatus {
        var s = PlayerStatus()
        s.mode = (result["mode"] as? String) ?? "stop"
        s.time = PlayerList.double(result["time"]) ?? 0
        s.duration = PlayerList.double(result["duration"]) ?? 0
        s.volume = PlayerList.int(result["mixer volume"]) ?? 0
        s.repeatMode = PlayerList.int(result["playlist repeat"]) ?? 0
        s.shuffleMode = PlayerList.int(result["playlist shuffle"]) ?? 0
        s.isPoweredOn = (PlayerList.int(result["power"]) ?? 1) == 1

        if let track = (result["playlist_loop"] as? [[String: Any]])?.first {
            s.hasTrack = true
            s.title = (track["title"] as? String) ?? ""
            s.artist = (track["artist"] as? String) ?? ""
            s.album = (track["album"] as? String) ?? ""
            if s.duration == 0 { s.duration = PlayerList.double(track["duration"]) ?? 0 }
            if let c = track["coverid"] { s.coverID = "\(c)" }
            s.artworkURL = track["artwork_url"] as? String
            // Radio: the station is the track; the song is current_title.
            if let song = result["current_title"] as? String, !song.isEmpty,
               PlayerList.int(result["remote"]) == 1 {
                if s.album.isEmpty { s.album = s.title }
                s.title = song
            }
        }
        return s
    }
}
