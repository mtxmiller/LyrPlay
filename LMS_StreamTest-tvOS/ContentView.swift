import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "tv.and.hifispeaker.fill")
                .imageScale(.large)
                .font(.system(size: 96))
                .foregroundStyle(.tint)
            Text("LyrPlay tvOS")
                .font(.largeTitle)
            Text("Hello, tvOS — SlimProto target compiles.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
