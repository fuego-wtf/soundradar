import SwiftUI

enum RadarTab: String, CaseIterable, Identifiable {
    case radar = "Radar", history = "History", apps = "All apps"
    var id: String { rawValue }
}

struct ContentView: View {
    let model: RadarModel
    @AppStorage("onboarded") private var onboarded = false
    @State private var tab: RadarTab = .radar
    @State private var selected: pid_t?
    @State private var showPermissions = false

    var body: some View {
        Group {
            switch tab {
            case .radar: radar
            case .history: HistoryList(model: model).padding(16)
            case .apps: AllAppsList(model: model)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .containerBackground(.thinMaterial, for: .window)
        .toolbar {
            ToolbarItem(placement: .navigation) { PlayingCapsule(model: model) }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(RadarTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            ToolbarItem(placement: .primaryAction) { OutputDeviceChip() }
            ToolbarItem(placement: .primaryAction) {
                Button { showPermissions = true } label: { Image(systemName: "lock.shield") }
                    .help("Permissions")
                    .accessibilityLabel("Permissions")
            }
        }
        .sheet(isPresented: $showPermissions, onDismiss: { onboarded = true }) {
            PermissionsView(model: model) { showPermissions = false }
        }
        .onAppear { if !onboarded { showPermissions = true } }
    }

    private var radar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 12) {
                RadarMap(model: model) { selected = $0 }
                    .frame(maxHeight: .infinity)
                RecentSounds(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MixerColumn(model: model, selected: $selected)
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
    }
}

/// Header capsule: "N sources playing".
struct PlayingCapsule: View {
    let model: RadarModel

    var body: some View {
        let n = model.playingApps.count
        Label(n == 0 ? "Quiet" : "\(n) source\(n == 1 ? "" : "s") playing",
              systemImage: n == 0 ? "speaker.slash" : "speaker.wave.3.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(n == 0 ? Color.secondary : Color.sound)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: n > 0)
            .accessibilityLabel(n == 0 ? "Nothing is playing" : "\(n) sources playing")
    }
}

// MARK: - Recent sounds and history

struct SoundEventRow: View {
    let event: SoundEvent

    var body: some View {
        HStack {
            Text(event.start, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Image(systemName: "speaker.wave.2").foregroundStyle(Color.sound)
            Text(event.name).fontWeight(.medium)
            Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            let secs = max(1, Int(event.end.timeIntervalSince(event.start).rounded()))
            Text("\(secs)s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

struct RecentSounds: View {
    let model: RadarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent sounds").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.history.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(model.history.prefix(4)) { SoundEventRow(event: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct HistoryList: View {
    let model: RadarModel

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("No sounds yet", systemImage: "clock",
                                   description: Text("Every sound burst is listed here."))
        } else {
            List(model.history) { SoundEventRow(event: $0) }
                .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - All apps

struct AllAppsList: View {
    @Bindable var model: RadarModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps (\(model.visibleApps.count))").font(.headline)
                Spacer()
                Toggle("Background apps", isOn: $model.showBackgroundApps)
                    .toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            List {
                ForEach(model.visibleApps) { app in
                    AppRowView(app: app, location: model.whereLine(app)) { model.jump(to: app) }
                }
                if !model.orphans.isEmpty {
                    Section("Audio processes without an app") {
                        ForEach(model.orphans, id: \.pid) { c in
                            HStack {
                                Image(systemName: c.isRunningOutput ? "speaker.wave.2" : "mic")
                                    .foregroundStyle(c.isRunningOutput ? Color.sound : .red)
                                    .frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(c.executableName)
                                    Text(c.executablePath).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text("pid \(c.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

struct AppRowView: View {
    let app: AppRow
    let location: String
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(app.isPlaying ? .semibold : .regular)
                if app.isSounding || app.isRecording {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if app.isRecording {
                Image(systemName: "mic.fill").foregroundStyle(.red).help("Using audio input")
                    .accessibilityLabel("Using audio input")
            }
            if app.isPlaying {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.sound)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Playing")
            } else if app.recentlyPlayed {
                Image(systemName: "speaker.wave.1").foregroundStyle(Color.sound.opacity(0.6))
                    .accessibilityLabel("Played recently")
            }
            Text("pid \(app.id)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button("Show", action: activate).buttonStyle(.glass).controlSize(.small)
                .accessibilityLabel("Show \(app.name)")
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if !app.outputDevices.isEmpty { parts.append("→ " + app.outputDevices.sorted().joined(separator: ", ")) }
        if !app.inputDevices.isEmpty { parts.append("mic: " + app.inputDevices.sorted().joined(separator: ", ")) }
        if !app.helpers.isEmpty { parts.append("via " + app.helpers.sorted().joined(separator: ", ")) }
        parts.append(location)
        return parts.joined(separator: " · ")
    }
}
