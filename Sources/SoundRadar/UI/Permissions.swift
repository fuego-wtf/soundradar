import SwiftUI

/// Three opt-in abilities. Sound Radar works without any of them.
struct PermissionsView: View {
    let model: RadarModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sound Radar works right away").font(.title2.weight(.semibold))
                Text("It already shows which apps play sound and on which display. Each switch below adds one more ability. macOS asks you once for each.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        PermissionCard(
                            symbol: "slider.horizontal.3", title: "Volume per app and live levels",
                            detail: "Set each app from silent to 150%, and see how loud each one really is.",
                            system: "macOS: System Audio Recording",
                            state: model.mixer.permission == .granted ? .on : (model.mixer.permission == .denied ? .denied : .off),
                            action: { model.mixer.requestPermission() })
                        PermissionCard(
                            symbol: "text.below.photo", title: "Window names, on every desktop",
                            detail: "Name the exact window that plays, even when it sits on another desktop.",
                            system: "macOS: Screen Recording (only window names are read, never the screen)",
                            state: model.locator.screenRecordingGranted ? .on : .off,
                            action: { model.locator.requestScreenRecording() })
                        PermissionCard(
                            symbol: "macwindow", title: "Jump to the window",
                            detail: "Bring exactly that window forward, and un-minimize it.",
                            system: "macOS: Accessibility",
                            state: model.locator.accessibilityGranted ? .on : .off,
                            action: { model.locator.requestAccessibility() })
                        PermissionCard(
                            symbol: "safari", title: "Browser tabs",
                            detail: "Name the front tab in the playing Arc, Chrome or Safari window, and switch to it.",
                            system: "macOS: Automation, asked once per browser",
                            state: model.locator.browserTabsEnabled ? .on : .off,
                            action: { model.locator.browserTabsEnabled = true })
                    }
                }
            }
            HStack {
                Label("Nothing leaves your Mac. Sound is measured, never recorded.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).buttonStyle(.glassProminent).tint(.playing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

enum PermissionState { case on, off, denied }

struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let system: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.needsPermission).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(system).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            switch state {
            case .on:
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Color.playing).font(.callout.weight(.medium))
            case .off:
                Button("Turn on", action: action).buttonStyle(.glassProminent).tint(.needsPermission)
                    .accessibilityLabel("Turn on \(title)")
            case .denied:
                Button("Open Settings", action: action).buttonStyle(.glass)
                    .accessibilityLabel("Open settings for \(title)")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
