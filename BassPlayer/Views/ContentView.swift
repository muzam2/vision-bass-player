import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var jellyfin: JellyfinClient
    @EnvironmentObject private var bassLink: BassLink
    @State private var selectedItem: JellyfinItem?

    var body: some View {
        NavigationSplitView {
            LibraryView(selectedItem: $selectedItem)
                .navigationTitle("Bass Player")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        } detail: {
            if let item = selectedItem {
                PlayerView(item: item)
                    .id(item.Id)
            } else {
                ContentUnavailableView("Pick a film", systemImage: "film", description: Text("Choose something from your Jellyfin library."))
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            BassStatusOrnament()
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var jellyfin: JellyfinClient
    @Binding var selectedItem: JellyfinItem?

    var body: some View {
        Group {
            if !jellyfin.isSignedIn {
                ContentUnavailableView("Not signed in", systemImage: "server.rack", description: Text("Open Settings to connect your Jellyfin server."))
            } else if jellyfin.items.isEmpty && jellyfin.isBusy {
                ProgressView("Loading library…")
            } else {
                List(jellyfin.items, selection: $selectedItem) { item in
                    HStack(spacing: 12) {
                        AsyncImage(url: jellyfin.posterURL(for: item, maxHeight: 180)) { image in
                            image.resizable().aspectRatio(2/3, contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(.quaternary)
                        }
                        .frame(width: 48, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.Name).font(.headline)
                            HStack(spacing: 8) {
                                if let y = item.ProductionYear { Text(String(y)) }
                                if let r = item.runtimeText { Text(r) }
                                if let c = item.MediaSources?.first?.Container ?? item.Container {
                                    Text(c.uppercased()).font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item)
                }
                .refreshable { await jellyfin.loadMovies() }
            }
        }
        .task {
            if jellyfin.isSignedIn && jellyfin.items.isEmpty { await jellyfin.loadMovies() }
        }
        .overlay(alignment: .bottom) {
            if let err = jellyfin.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.red).padding(8).background(.regularMaterial, in: Capsule()).padding()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var jellyfin: JellyfinClient
    @EnvironmentObject private var bassLink: BassLink
    @State private var password = ""

    var body: some View {
        Form {
            Section("Jellyfin server") {
                TextField("http://192.168.1.10:8096", text: $jellyfin.serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Username", text: $jellyfin.username)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                if jellyfin.isSignedIn {
                    Button("Sign out", role: .destructive) { jellyfin.signOut() }
                } else {
                    Button("Sign in") { Task { await jellyfin.signIn(password: password) } }
                        .disabled(jellyfin.isBusy || jellyfin.serverURL.isEmpty || jellyfin.username.isEmpty)
                }
                if let err = jellyfin.errorMessage { Text(err).foregroundStyle(.red).font(.footnote) }
            }

            Section("Subwoofer receiver") {
                LabeledContent("Link", value: bassLink.state.rawValue.capitalized)
                if let name = bassLink.peripheralName { LabeledContent("Device", value: name) }
                HStack {
                    Button("Connect") { bassLink.start() }.disabled(bassLink.state != .off)
                    Button("Disconnect") { bassLink.stop() }.disabled(bassLink.state == .off)
                }
                Stepper("Extra delay: \(bassLink.extraDelayMs) ms", value: $bassLink.extraDelayMs, in: 0...400, step: 10)
                Toggle("Mute sub", isOn: $bassLink.muted)
            }

            Section("Diagnostics") {
                LabeledContent("Packets sent", value: "\(bassLink.packetsSent)")
                LabeledContent("Packets dropped (BLE busy)", value: "\(bassLink.packetsDropped)")
                LabeledContent("Receiver buffer", value: "\(bassLink.receiverBufferFill) samples")
                LabeledContent("Receiver underruns", value: "\(bassLink.receiverUnderruns)")
            }
        }
        .navigationTitle("Settings")
    }
}

/// Small always-visible strip under the window showing the sub link.
struct BassStatusOrnament: View {
    @EnvironmentObject private var bassLink: BassLink

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: bassLink.state == .connected ? "hifispeaker.fill" : "hifispeaker")
                .foregroundStyle(bassLink.state == .connected ? .green : .secondary)
            Text(bassLink.state == .connected ? "Sub connected" : bassLink.state.rawValue.capitalized)
            if bassLink.state == .off {
                Button("Connect sub") { bassLink.start() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
    }
}
