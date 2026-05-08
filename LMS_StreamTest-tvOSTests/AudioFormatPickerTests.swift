import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// Sanity check on the `SettingsManager.AudioFormat` enum that the tvOS
/// Settings Picker binds to. Catches accidental enum changes (e.g. someone
/// removing `.flac` while refactoring) before they reach a user.
struct AudioFormatPickerTests {

    @Test func allCases_includesFlacAndCompressed() {
        let all = SettingsManager.AudioFormat.allCases

        #expect(all.contains(.flac), "Lossless FLAC must remain a user-selectable option")
        #expect(all.contains(.compressed), "Compressed must remain a user-selectable option")
    }

    @Test func displayNames_areAllNonEmpty() {
        for fmt in SettingsManager.AudioFormat.allCases {
            #expect(!fmt.displayName.isEmpty, "AudioFormat \(fmt) is missing a displayName — Picker would render a blank row")
        }
    }
}
