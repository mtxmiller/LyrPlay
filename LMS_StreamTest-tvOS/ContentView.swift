import SwiftUI

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.large)
                .font(.system(size: 96))
                .foregroundStyle(.green)
            Text("Connected to LMS")
                .font(.largeTitle)
            Text(verbatim: "\(settings.serverHost):\(settings.serverWebPort)")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Player UI lands in 98q.5.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            Button(role: .destructive) {
                settings.resetConfiguration()
            } label: {
                Text("Reset configuration")
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
            }
            .padding(.top, 32)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
