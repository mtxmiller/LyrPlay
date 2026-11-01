import Foundation
import Testing
@testable import LMS_StreamTest_tvOS

/// The Audio Format presets against LMS's TranscodingHelper: the list is an
/// ordered wish list, and "Prefer native format" (LMS default) moves a file's
/// own type to the front when the player advertises it. So a preset may only
/// list a format it is happy to receive as it is (bd qtqa: Opus/Ogg streamed
/// FLAC; bd y9kp: WAV did too, and the screen's text had drifted from the lists).
struct AudioFormatPresetTests {
    static let presets = SettingsManager.AudioFormat.allCases.filter { $0 != .custom }

    @Test func theScreenListsExactlyTheCodesThePresetAdvertises() {
        for preset in Self.presets {
            let shown = preset.description.split(separator: ":").last!
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let advertised = preset.capabilities.split(separator: ",").map(String.init)
            #expect(shown == advertised, "\(preset.displayName)")
        }
    }

    @Test func onlyTheFLACPresetAdvertisesFLAC() {
        for preset in Self.presets {
            let codes = preset.capabilities.split(separator: ",").map(String.init)
            #expect(codes.contains("flc") == (preset == .flac), "\(preset.displayName)")
        }
    }

    /// An AAC file in m4a is type "mp4" to LMS: nothing promotes it, so the
    /// first of aac/mp3 in the list decides between passthrough and a lossy
    /// re-encode (stock mp4→mp3 rule).
    @Test func lossyPresetsPassAACThroughBeforeFallingBackToMP3() {
        for preset in [SettingsManager.AudioFormat.opus, .oggVorbis, .aacPreferred] {
            let codes = preset.capabilities.split(separator: ",").map(String.init)
            #expect(codes.firstIndex(of: "aac")! < codes.firstIndex(of: "mp3")!, "\(preset.displayName)")
        }
    }
}
