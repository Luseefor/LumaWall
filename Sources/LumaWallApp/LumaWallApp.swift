import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    var body: some Scene {
        WindowGroup("LumaWall") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

private struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Home", systemImage: "house.fill")
                Label("Library", systemImage: "square.grid.2x2.fill")
                Label("Displays", systemImage: "display.2")
                Label("Playlists", systemImage: "rectangle.stack.fill")
                Label("Settings", systemImage: "gearshape.fill")
            }
            .navigationTitle("LumaWall")
        } detail: {
            ContentUnavailableView(
                "Your wallpaper engine",
                systemImage: "sparkles.rectangle.stack",
                description: Text("The independent LumaWall runtime is ready for its native renderer module.")
            )
        }
    }
}
