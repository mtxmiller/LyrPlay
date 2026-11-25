import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// bd 9dtq (GH #103): choosing and controlling another LMS player.
struct ControlledPlayerTests {

    private let tv = "aa:bb:cc:00:00:01"

    private func playersResult() -> [String: Any] {
        ["count": 4, "players_loop": [
            ["playerid": "AA:BB:CC:00:00:01", "name": "Living Room", "modelname": "LyrPlay", "connected": 1, "power": 1, "isplaying": 0],
            ["playerid": "11:11:11:11:11:11", "name": "WiiM Ultra", "modelname": "SqueezeLite", "connected": 1, "power": 1, "isplaying": 1],
            ["playerid": "22:22:22:22:22:22", "name": "Bedroom", "model": "baby", "connected": "1", "power": 0, "isplaying": 0],
            ["playerid": "33:33:33:33:33:33", "name": "Garage Pi", "connected": 0, "power": 0, "isplaying": 0],
        ]]
    }

    @Test func players_parsesFlagsAsIntsOrStrings() {
        let players = PlayerList.players(from: playersResult())
        #expect(players.count == 4)
        #expect(players[1].name == "WiiM Ultra" && players[1].isPlaying && players[1].isConnected)
        #expect(players[2].model == "baby" && players[2].isConnected && !players[2].isPoweredOn)
        #expect(!players[3].isConnected)
    }

    @Test func choices_thisDeviceFirstThenByName() {
        let players = PlayerList.players(from: playersResult())
        let choices = PlayerList.choices(players: players, groups: [], thisDeviceID: tv)
        #expect(choices.map(\.name) == ["Living Room", "Bedroom", "Garage Pi", "WiiM Ultra"])
        #expect(choices[0].isThisDevice)
        #expect(!choices[2].isConnected)
    }

    @Test func choices_syncedGroupIsOneRowTargetingAConnectedMember() {
        let players = PlayerList.players(from: playersResult())
        let groups = PlayerList.syncGroups(from: ["syncgroups_loop": [
            ["sync_members": "33:33:33:33:33:33,11:11:11:11:11:11", "sync_member_names": "Garage Pi,WiiM Ultra"]
        ]])
        let choices = PlayerList.choices(players: players, groups: groups, thisDeviceID: tv)
        let group = try! #require(choices.first { $0.isGroup })
        #expect(group.name == "Garage Pi + WiiM Ultra")
        #expect(group.id == "11:11:11:11:11:11")   // Garage Pi is not connected
        #expect(choices.count == 3)
    }

    @Test func choices_groupWithThisDeviceIsThisDevice() {
        let players = PlayerList.players(from: playersResult())
        let groups = [LMSSyncGroup(memberIDs: ["11:11:11:11:11:11", "AA:BB:CC:00:00:01"])]
        let choices = PlayerList.choices(players: players, groups: groups, thisDeviceID: tv)
        #expect(choices[0].isThisDevice && choices[0].isGroup)
        #expect(choices[0].id == tv)
    }

    @Test func status_parsesLibraryTrack() {
        let status = PlayerStatus.parse([
            "mode": "play", "time": "51.2", "duration": 278.0, "mixer volume": 62,
            "playlist repeat": 2, "playlist shuffle": 1, "power": 1,
            "playlist_loop": [["title": "Coastline Static", "artist": "Marisol Vega",
                               "album": "Blue Hour Drive", "coverid": 12345]]
        ])
        #expect(status.isPlaying && status.hasTrack)
        #expect(status.time == 51.2 && status.duration == 278)
        #expect(status.title == "Coastline Static" && status.coverID == "12345")
        #expect(status.volume == 62 && status.repeatMode == 2 && status.shuffleMode == 1)
    }

    @Test func status_radioShowsTheSongAndKeepsTheStation() {
        let status = PlayerStatus.parse([
            "mode": "play", "remote": 1, "current_title": "Artist - Song",
            "playlist_loop": [["title": "Radio Paradise", "artwork_url": "/imageproxy/x/image.png"]]
        ])
        #expect(status.title == "Artist - Song")
        #expect(status.album == "Radio Paradise")
        #expect(status.duration == 0)
    }

    @Test func status_emptyPlaylistHasNoTrack() {
        let status = PlayerStatus.parse(["mode": "stop", "power": 0])
        #expect(!status.hasTrack && !status.isPoweredOn && !status.isPlaying)
    }
}
