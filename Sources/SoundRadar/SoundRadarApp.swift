import SwiftUI

@main
struct SoundRadarApp: App {
    // One model for the window and the menu bar extra.
    @State private var model = RadarModel(locator: SoundLocator())
    @State private var solo = SoloCoordinator()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Lets `swift run` show a normal Dock app too, not only the bundled .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Sound Radar", id: "radar") {
            ContentView(model: model)
                .environment(solo)
        }
        .defaultSize(width: 980, height: 700)
        .windowToolbarStyle(.unified)

        MenuBarExtra("Sound Radar", systemImage: "speaker.wave.2.fill") {
            MenuBarMixer(model: model) {
                openWindow(id: "radar")
                NSApplication.shared.activate()
            }
            .environment(solo)
        }
        .menuBarExtraStyle(.window)
    }
}
