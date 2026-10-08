import SwiftUI

/// Sidebar destinations. Playing and Just heard share the radar; Library holds History and All apps.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case playing = "Playing", justHeard = "Just heard", history = "History", apps = "All apps"
    var id: String { rawValue }
    var isRadar: Bool { self == .playing || self == .justHeard }
}

struct ContentView: View {
    let model: RadarModel
    @AppStorage("onboarded") private var onboarded = false
    @State private var item: SidebarItem? = .playing
    @State private var selected: pid_t?
    @State private var showPermissions = false
    @State private var showMixer = true

    var body: some View {
        let current = item ?? .playing
        NavigationSplitView {
            Sidebar(model: model, item: $item)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch current {
                case .playing, .justHeard: radar(current)
                case .history: HistoryList(model: model).padding(16)
                case .apps: AllAppsList(model: model)
                }
            }
            .navigationTitle(current.rawValue)
        }
        .frame(minWidth: 900, minHeight: 560)
        .containerBackground(for: .window) { Stage() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { OutputDeviceChip() }
            ToolbarItem(placement: .primaryAction) {
                Button { showPermissions = true } label: { Image(systemName: "lock.shield") }
                    .help("Permissions")
                    .accessibilityLabel("Permissions")
            }
            if current.isRadar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showMixer.toggle() } label: { Image(systemName: "sidebar.trailing") }
                        .help(showMixer ? "Hide mixer" : "Show mixer")
                        .accessibilityLabel(showMixer ? "Hide mixer" : "Show mixer")
                }
            }
        }
        .background { shortcuts }
        .sheet(isPresented: $showPermissions, onDismiss: { onboarded = true }) {
            PermissionsView(model: model) { showPermissions = false }
        }
        .onAppear { if !onboarded { showPermissions = true } }
        .firstLaunchConfetti()
    }

    /// Chords live in real Buttons (always in the responder chain), not in commands.
    private var shortcuts: some View {
        Group {
            Button("Radar") { item = .playing }.keyboardShortcut("1", modifiers: .command)
            Button("History") { item = .history }.keyboardShortcut("2", modifiers: .command)
            Button("All apps") { item = .apps }.keyboardShortcut("3", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func radar(_ which: SidebarItem) -> some View {
        let sounding = model.playingApps
        let list = which == .justHeard ? sounding.filter { !$0.isPlaying } : sounding.filter(\.isPlaying)
        return VStack(alignment: .leading, spacing: 12) {
            PosterHeader(model: model, playing: sounding.filter(\.isPlaying).count)
            RadarMap(model: model, playing: sounding) { selected = $0 }
                .frame(maxHeight: .infinity)
            RecentSounds(model: model)
        }
        .padding(16)
        .inspector(isPresented: $showMixer) {
            MixerColumn(model: model, list: list,
                        emptyTitle: which == .justHeard ? "Nothing heard lately" : "Quiet. For now.",
                        selected: $selected)
                .padding(.horizontal, 12)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
    }
}

/// Floating glass sidebar: Radar (Playing, Just heard) and Library (History, All apps).
struct Sidebar: View {
    let model: RadarModel
    @Binding var item: SidebarItem?

    var body: some View {
        let sounding = model.playingApps
        let playing = sounding.filter(\.isPlaying).count
        List(selection: $item) {
            Section("Radar") {
                row(.playing, symbol: "speaker.wave.3.fill", tint: .playing, count: playing)
                row(.justHeard, symbol: "speaker.wave.1.fill", tint: .justHeard, count: sounding.count - playing)
            }
            Section("Library") {
                row(.history, symbol: "clock", tint: .secondary, count: 0)
                row(.apps, symbol: "square.grid.2x2", tint: .secondary, count: 0)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ it: SidebarItem, symbol: String, tint: Color, count: Int) -> some View {
        Label {
            HStack {
                Text(it.rawValue)
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(.num(11)).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .tag(it)
    }
}

/// Poster line: "2 playing" or "Who's making that noise?" in serif italic, with the mark beside it.
struct PosterHeader: View {
    let model: RadarModel
    let playing: Int

    var body: some View {
        HStack(spacing: 14) {
            PulsingMark(active: playing > 0).frame(width: 44, height: 44)
            Text(playing > 0 ? "\(playing) playing" : "Who's making that noise?")
                .font(.poster)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(playing > 0 ? "\(playing) playing" : "Nothing is playing")
    }
}

// MARK: - Recent sounds and history

struct SoundEventRow: View {
    let event: SoundEvent

    var body: some View {
        HStack {
            Text(event.start, format: .dateTime.hour().minute().second())
                .font(.num(12, weight: .regular)).foregroundStyle(.secondary)
            Image(systemName: "speaker.wave.2").foregroundStyle(Color.playing)
            Text(event.name).fontWeight(.medium)
            Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            let secs = max(1, Int(event.end.timeIntervalSince(event.start).rounded()))
            Text("\(secs)s").font(.num(12, weight: .regular)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .hoverHighlight(radius: 8)
    }
}

struct RecentSounds: View {
    let model: RadarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent sounds").font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
            if model.history.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(model.history.prefix(3)) { SoundEventRow(event: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct HistoryList: View {
    let model: RadarModel

    var body: some View {
        if model.history.isEmpty {
            EmptyPoster(title: "No sounds yet", detail: "Every sound burst is listed here.")
                .frame(maxHeight: .infinity)
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
        let visible = model.visibleApps
        VStack(spacing: 0) {
            HStack {
                Text("Apps (\(visible.count))").font(.system(.headline, design: .rounded))
                Spacer()
                Toggle("Background apps", isOn: $model.showBackgroundApps)
                    .toggleStyle(.switch).tint(.playing).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            List {
                ForEach(visible) { app in
                    AppRowView(app: app, location: model.whereLine(app)) { model.jump(to: app) }
                }
                if !model.orphans.isEmpty {
                    Section("Audio processes without an app") {
                        ForEach(model.orphans, id: \.pid) { c in
                            HStack {
                                Image(systemName: c.isRunningOutput ? "speaker.wave.2" : "mic")
                                    .foregroundStyle(c.isRunningOutput ? Color.playing : Color.muted)
                                    .frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(c.executableName)
                                    Text(c.executablePath).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text("pid \(c.pid)").font(.num(12, weight: .regular)).foregroundStyle(.secondary)
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
                Image(systemName: "mic.fill").foregroundStyle(Color.muted).help("Using audio input")
                    .accessibilityLabel("Using audio input")
            }
            if app.isPlaying {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.playing)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Playing")
            } else if app.recentlyPlayed {
                Image(systemName: "speaker.wave.1").foregroundStyle(Color.justHeard)
                    .accessibilityLabel("Played recently")
            }
            Text("pid \(app.id)").font(.num(12, weight: .regular)).foregroundStyle(.tertiary)
            Button("Show", action: activate).buttonStyle(.glass).controlSize(.small)
                .accessibilityLabel("Show \(app.name)")
        }
        .padding(.vertical, 2)
        .hoverHighlight()
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
