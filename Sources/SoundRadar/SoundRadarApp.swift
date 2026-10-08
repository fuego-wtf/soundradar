import SwiftUI

@main
struct SoundRadarApp: App {
    init() {
        // Lets `swift run` show a normal Dock app too, not only the bundled .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Sound Radar") {
            ContentView()
        }
        .defaultSize(width: 900, height: 720)
    }
}
