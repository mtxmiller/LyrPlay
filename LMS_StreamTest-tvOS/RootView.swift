import SwiftUI

struct RootView: View {
    @StateObject private var settings = SettingsManager.shared

    var body: some View {
        if settings.isConfigured {
            ContentView()
        } else {
            NavigationStack {
                ServerConnectView()
            }
        }
    }
}

#Preview {
    RootView()
}
