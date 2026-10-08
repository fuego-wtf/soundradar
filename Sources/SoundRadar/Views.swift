import SwiftUI

struct ContentView: View {
    @State private var model = RadarModel()

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                header
                DisplayMap(model: model)
                    .frame(minHeight: 220)
            }
            .padding(12)

            AppList(model: model)
                .frame(minHeight: 200)
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            let playing = model.playingApps
            if playing.isEmpty {
                Label("Nothing is playing sound", systemImage: "speaker.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Label(playing.map(\.name).joined(separator: ", "), systemImage: "speaker.wave.3.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Spacer()
            Toggle("Background apps", isOn: $model.showBackgroundApps)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Display map

struct DisplayMap: View {
    let model: RadarModel

    var body: some View {
        GeometryReader { geo in
            let union = model.displays.reduce(CGRect.null) { $0.union($1.frame) }
            if union.isNull {
                Text("No displays").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let pad: CGFloat = 8
                let scale = min((geo.size.width - 2 * pad) / union.width,
                                (geo.size.height - 2 * pad) / union.height)
                let offset = CGPoint(x: (geo.size.width - union.width * scale) / 2,
                                     y: (geo.size.height - union.height * scale) / 2)
                let map = { (r: CGRect) -> CGRect in
                    CGRect(x: (r.minX - union.minX) * scale + offset.x,
                           y: (r.minY - union.minY) * scale + offset.y,
                           width: r.width * scale, height: r.height * scale)
                }
                let playingPIDs = Set(model.playingApps.map(\.id))

                ZStack(alignment: .topLeading) {
                    ForEach(model.displays) { d in
                        let r = map(d.frame)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(d.isMain ? 0.5 : 0.25), lineWidth: 1))
                            .overlay(alignment: .bottomLeading) {
                                Text(d.isMain ? "\(d.name) (main)" : d.name)
                                    .font(.caption2).foregroundStyle(.secondary).padding(4)
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                    // Quiet windows, faint, back to front.
                    ForEach(model.allWindows.reversed().filter { !playingPIDs.contains($0.pid) }) { w in
                        let r = map(w.frame)
                        Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                    // Windows of apps that are making sound.
                    ForEach(model.playingApps) { app in
                        ForEach(app.windows) { w in
                            let r = map(w.frame)
                            SoundingWindow(app: app, live: app.isPlaying)
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .onTapGesture { model.bringToFront(app.id) }
                                .help("\(app.name): click to bring to front")
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

struct SoundingWindow: View {
    let app: AppRow
    let live: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(live ? 0.35 : 0.15))
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.orange, lineWidth: 2)
                .scaleEffect(pulse ? 1.12 : 1)
                .opacity(pulse ? 0 : 1)
            VStack(spacing: 2) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                }
                Image(systemName: live ? "speaker.wave.3.fill" : "speaker.wave.1")
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: - App list

struct AppList: View {
    let model: RadarModel

    var body: some View {
        List {
            if !model.history.isEmpty {
                Section("Recent sounds") {
                    ForEach(model.history.prefix(8)) { e in
                        HStack {
                            Text(e.start, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "speaker.wave.2").foregroundStyle(.orange)
                            Text(e.name).fontWeight(.medium)
                            Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            let secs = max(1, Int(e.end.timeIntervalSince(e.start).rounded()))
                            Text("\(secs)s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Apps (\(model.visibleApps.count))") {
                ForEach(model.visibleApps) { app in
                    AppRowView(app: app, location: model.whereIs(app)) { model.bringToFront(app.id) }
                }
            }
            if !model.orphans.isEmpty {
                Section("Audio processes without an app") {
                    ForEach(model.orphans, id: \.pid) { c in
                        HStack {
                            Image(systemName: c.isRunningOutput ? "speaker.wave.2" : "mic")
                                .foregroundStyle(c.isRunningOutput ? .orange : .red)
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
    }
}

struct AppRowView: View {
    let app: AppRow
    let location: String
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app").frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(app.isPlaying ? .semibold : .regular)
                if app.isPlaying || app.recentlyPlayed || app.isRecording {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if app.isRecording {
                Image(systemName: "mic.fill").foregroundStyle(.red).help("Using audio input")
            }
            if app.isPlaying {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.orange)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else if app.recentlyPlayed {
                Image(systemName: "speaker.wave.1").foregroundStyle(.orange.opacity(0.6))
            }
            Text("pid \(app.id)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button("Show", action: activate).controlSize(.small)
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
