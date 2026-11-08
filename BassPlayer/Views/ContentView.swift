import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink
    @State private var selectedItem: MediaItem?

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
                    .id(item.id)
            } else {
                ContentUnavailableView("Pick something to watch", systemImage: "film",
                                       description: Text("Choose a film or episode from your library."))
            }
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            BassStatusOrnament()
        }
        #else
        .overlay(alignment: .bottomTrailing) {
            BassStatusOrnament().padding(24)
        }
        #endif
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var youtube: YouTubeClient
    @Binding var selectedItem: MediaItem?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $library.selectedSource) {
                ForEach(MediaSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                if !library.currentIsSignedIn {
                    ContentUnavailableView("Not connected", systemImage: "server.rack",
                                           description: Text("Open Settings to connect \(library.selectedSource.label)."))
                } else if library.items.isEmpty && library.currentIsBusy {
                    ProgressView("Loading library…")
                } else if library.items.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "tray",
                                           description: Text("Pull to refresh, or check the server has movie or TV libraries."))
                } else {
                    List(library.items, selection: $selectedItem) { item in
                        LibraryRow(item: item).tag(item)
                    }
                    .refreshable { await library.refresh() }
                    .searchable(text: $library.searchText,
                                prompt: library.selectedSource == .youtube ? "Search YouTube, or paste a link" : "Search titles")
                }
            }
        }
        .task(id: library.selectedSource) {
            if library.currentIsSignedIn && library.items.isEmpty { await library.refresh() }
        }
        .onChange(of: library.searchText) { _, text in
            if library.selectedSource == .youtube { youtube.scheduleSearch(text) }
        }
        .onSubmit(of: .search) {
            if library.selectedSource == .youtube { Task { await youtube.search(library.searchText) } }
        }
        .overlay(alignment: .bottom) {
            if let err = library.currentError {
                Text(err).font(.footnote).foregroundStyle(.red).padding(8)
                    .background(.regularMaterial, in: Capsule()).padding()
            }
        }
    }
}

struct LibraryRow: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.posterURL) { image in
                image.resizable().aspectRatio(2/3, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 48, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    if let s = item.subtitle { Text(s) }
                    if let r = item.runtimeText { Text(r) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(item.formatBadge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var jellyfin: JellyfinClient
    @EnvironmentObject private var plex: PlexClient
    @EnvironmentObject private var youtube: YouTubeClient
    @EnvironmentObject private var bassLink: BassLink
    @AppStorage("bass.leadMs") private var leadMs: Int = 0
    @State private var jfPassword = ""

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Backend", selection: $library.backend) {
                    ForEach(PlayerBackend.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show TV episodes in library", isOn: $library.showEpisodes)
            }

            Section("Jellyfin") {
                TextField("http://192.168.1.10:8096", text: $jellyfin.serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Username", text: $jellyfin.username)
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $jfPassword)
                if jellyfin.isSignedIn {
                    Button("Sign out of Jellyfin", role: .destructive) { jellyfin.signOut() }
                } else {
                    Button("Sign in") { Task { await jellyfin.signIn(password: jfPassword) } }
                        .disabled(jellyfin.isBusy || jellyfin.serverURL.isEmpty || jellyfin.username.isEmpty)
                }
                if let err = jellyfin.errorMessage { Text(err).foregroundStyle(.red).font(.footnote) }
            }

            Section("Plex") {
                if plex.isSignedIn {
                    if plex.servers.isEmpty && !plex.hasServer {
                        Button("Find my servers") { Task { await plex.discoverServers() } }
                    }
                    if !plex.servers.isEmpty {
                        Picker("Server", selection: Binding(
                            get: { plex.servers.first { $0.uri == plex.serverURL } },
                            set: { if let s = $0 { plex.select(server: s) } }
                        )) {
                            ForEach(plex.servers) { Text($0.name).tag(Optional($0)) }
                        }
                    } else if plex.hasServer {
                        LabeledContent("Server", value: plex.serverName)
                        Button("Refresh servers") { Task { await plex.discoverServers() } }
                    }
                    Button("Sign out of Plex", role: .destructive) { plex.signOut() }
                } else if plex.isAwaitingPin, let code = plex.pinCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On any device go to plex.tv/link and enter:")
                        Text(code).font(.system(size: 34, weight: .bold, design: .monospaced))
                        ProgressView("Waiting for you to link…")
                    }
                    Button("Cancel") { plex.cancelPinSignIn() }
                } else if plex.isAwaitingPin {
                    ProgressView("Requesting code…")
                } else {
                    Button("Sign in with plex.tv") { plex.beginPinSignIn() }
                }
                if let err = plex.errorMessage { Text(err).foregroundStyle(.red).font(.footnote) }
            }

            Section("YouTube") {
                Toggle("SponsorBlock (skip sponsors, intros, outros)", isOn: $youtube.sponsorBlockEnabled)
                Text("Streams come straight from YouTube's player API, so there are no ads. Search or paste a link in the library's search box.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Subwoofer receiver") {
                LabeledContent("Link", value: bassLink.state.rawValue.capitalized)
                if let name = bassLink.peripheralName { LabeledContent("Device", value: name) }
                HStack {
                    Button("Connect") { bassLink.start() }.disabled(bassLink.state != .off)
                    Button("Disconnect") { bassLink.stop() }.disabled(bassLink.state == .off)
                }
                #if os(tvOS)
                HStack {
                    Text("Receiver delay: \(bassLink.extraDelayMs) ms")
                    Spacer()
                    Button("−10") { bassLink.extraDelayMs = max(0, bassLink.extraDelayMs - 10) }
                    Button("+10") { bassLink.extraDelayMs = min(400, bassLink.extraDelayMs + 10) }
                }
                HStack {
                    Text("Bass lead (FFmpeg): \(leadMs) ms")
                    Spacer()
                    Button("−10") { leadMs = max(0, leadMs - 10) }
                    Button("+10") { leadMs = min(300, leadMs + 10) }
                }
                #else
                Stepper("Receiver delay: \(bassLink.extraDelayMs) ms", value: $bassLink.extraDelayMs, in: 0...400, step: 10)
                Stepper("Bass lead (FFmpeg): \(leadMs) ms", value: $leadMs, in: 0...300, step: 10)
                #endif
                Text("If the thump lands before the explosion, raise receiver delay. If it lands after, raise bass lead (holds the headset audio and picture back so the sub catches up).")
                    .font(.footnote).foregroundStyle(.secondary)
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

/// Small always-visible strip showing the sub link.
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
        #if os(visionOS)
        .glassBackgroundEffect()
        #else
        .background(.regularMaterial, in: Capsule())
        #endif
    }
}
