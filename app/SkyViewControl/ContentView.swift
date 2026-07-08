import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("SkyView")
                .font(.largeTitle.bold())
            Text("Lamp control coming soon")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
