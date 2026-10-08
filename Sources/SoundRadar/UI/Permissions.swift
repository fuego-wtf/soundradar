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
                            symbol: "macwindow", title: "Window names and jump to window",
                            detail: "See which window plays, even on another desktop, and bring exactly that window forward.",
                            system: "macOS: Accessibility",
                            state: model.locator.accessibilityGranted ? .on : .off,
                            action: { model.locator.requestAccessibility() })
                        PermissionCard(
                            symbol: "safari", title: "Browser tabs",
                            detail: "Name the tab that plays in Arc, Chrome or Safari, and switch to it.",
                            system: "macOS: Automation, per browser",
                            state: .comingSoon, action: {})
                    }
                }
            }
            HStack {
                Label("Nothing leaves your Mac. Sound is measured, never recorded.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).buttonStyle(.glassProminent).tint(.sound)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

enum PermissionState { case on, off, denied, comingSoon }

struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let system: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.sound).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(system).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            switch state {
            case .on:
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
            case .off:
                Button("Turn on", action: action).buttonStyle(.glassProminent).tint(.sound)
                    .accessibilityLabel("Turn on \(title)")
            case .denied:
                Button("Open Settings", action: action).buttonStyle(.glass)
                    .accessibilityLabel("Open settings for \(title)")
            case .comingSoon:
                VStack(alignment: .trailing, spacing: 2) {
                    Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                        .accessibilityLabel("\(title), coming soon")
                    Text("Coming soon").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
