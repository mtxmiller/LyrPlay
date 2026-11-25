import SwiftUI
import Combine
import os.log

/// "Playing on <player>" button above the Now Playing title (bd 9dtq,
/// design screens 1 and 3). Opens the player picker.
struct PlayingOnButton: View {
    let name: String
    let isRemote: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isRemote ? "hifispeaker" : "tv")
                    .font(.system(size: 22, weight: .semibold))
                Text("Playing on")
                    .font(.system(size: 22, weight: .medium))
                Text(verbatim: name)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 26)
            .frame(height: 60)
            .foregroundStyle(isFocused ? Color.black : Color.primary)
            .background(
                Capsule().fill(isFocused ? Color.white : Color.white.opacity(isRemote ? 0.22 : 0.10))
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
        }
        .buttonStyle(ChromelessButtonStyle())
        .focused($isFocused)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.15), value: isFocused)
        .accessibilityLabel("Playing on \(name). Choose player.")
    }
}

/// Side panel listing this Apple TV, other players and synced groups
/// (design screen 2). Picking a row makes Now Playing, Queue and Browse
/// control that player.
struct PlayerPickerView: View {
    @ObservedObject var controlled: ControlledPlayer
    let onDone: () -> Void

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose Player")
                    .font(.title2.weight(.bold))
                Text("Now Playing, Queue and Browse control the player you pick.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                if controlled.choices.isEmpty {
                    if controlled.isLoadingPlayers {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        Text("No players found on the server.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TVList(.settings) {
                        ForEach(controlled.choices) { choice in
                            PlayerChoiceRow(choice: choice, isSelected: isSelected(choice)) {
                                controlled.select(choice)
                                onDone()
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 64)
            .frame(width: 900)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.11).ignoresSafeArea())
        }
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .presentationBackground(.clear)
        .onAppear {
            os_log(.info, log: OSLog(subsystem: "com.lmsstream", category: "PlayerPicker"), "Picker appeared")
            controlled.refreshPlayers()
        }
        .onReceive(refreshTimer) { _ in controlled.refreshPlayers() }
    }

    private func isSelected(_ choice: PlayerChoice) -> Bool {
        if choice.isThisDevice { return !controlled.isRemote }
        guard let id = controlled.selectedID?.lowercased() else { return false }
        return choice.members.contains { $0.id.lowercased() == id }
    }
}

private struct PlayerChoiceRow: View {
    let choice: PlayerChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: choice.isThisDevice ? String(localized: "This Apple TV") : choice.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Selected")
                } else if choice.isConnected && !choice.isPoweredOn {
                    Text("Turns on when picked")
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
            .frame(minHeight: 76)
        }
        .buttonStyle(.plain)
        .tvListRow()
        .disabled(!choice.isConnected)
        .opacity(choice.isConnected ? 1 : 0.45)
    }

    private var icon: String {
        if choice.isThisDevice { return "tv" }
        if choice.isGroup { return "hifispeaker.2" }
        if !choice.isConnected { return "wifi.slash" }
        return "hifispeaker"
    }

    private var subtitle: String {
        var parts: [String] = []
        if choice.isThisDevice && choice.isGroup {
            parts.append(choice.name)
        } else if choice.isGroup {
            parts.append(String(localized: "\(choice.members.count) players, synced"))
        } else if !choice.members[0].model.isEmpty {
            parts.append(choice.members[0].model)
        }
        if !choice.isConnected {
            parts.append(String(localized: "Not connected to the server"))
        } else if !choice.isPoweredOn {
            parts.append(String(localized: "Off"))
        } else {
            parts.append(choice.isPlaying ? String(localized: "Playing") : String(localized: "Not playing"))
        }
        return parts.joined(separator: " · ")
    }
}
