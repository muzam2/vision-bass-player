import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var jellyfin: JellyfinClient
    @EnvironmentObject private var plex: PlexClient
    @EnvironmentObject private var youtube: YouTubeClient
    @EnvironmentObject private var nas: NASClient
    @EnvironmentObject private var bassLink: BassLink
    @AppStorage("bass.leadMs") private var leadMs: Int = 0
    @State private var jfPassword = ""
    @State private var showAddShare = false

    var body: some View {
        NavigationStack {
            Form {
                playback
                jellyfinSection
                plexSection
                youtubeSection
                nasSection
                subwoofer
                diagnostics
                about
            }
            #if !os(tvOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddShare) { NASShareEditor() }
        }
    }

    // MARK: Sections

    private var playback: some View {
        Section {
            Picker("Player", selection: $library.backend) {
                ForEach(PlayerBackend.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Show TV episodes by default", isOn: $library.showEpisodes)
            Toggle("Resume where you left off", isOn: $library.resumePlayback)
            Toggle("Autoplay next item", isOn: $library.autoplayNext)
            SleepTimerRow()
        } header: {
            Label("Playback", systemImage: "play.circle")
        }
    }

    private var jellyfinSection: some View {
        Section {
            StatusRow(connected: jellyfin.isSignedIn, text: library.status(of: .jellyfin))
            TextField("Server, e.g. http://192.168.1.10:8096", text: $jellyfin.serverURL)
                #if !os(tvOS)
                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                #endif
            TextField("Username", text: $jellyfin.username)
                #if !os(tvOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            SecureField("Password", text: $jfPassword)
            if jellyfin.isSignedIn {
                Button("Sign out", role: .destructive) { jellyfin.signOut() }
            } else {
                Button { Task { await jellyfin.signIn(password: jfPassword) } } label: {
                    if jellyfin.isBusy { ProgressView() } else { Text("Sign in") }
                }
                .disabled(jellyfin.isBusy || jellyfin.serverURL.isEmpty || jellyfin.username.isEmpty)
            }
            if let err = jellyfin.errorMessage { ErrorText(err) }
        } header: {
            Label("Jellyfin", systemImage: AppTab.jellyfin.systemImage)
        }
    }

    private var plexSection: some View {
        Section {
            StatusRow(connected: plex.isSignedIn && plex.hasServer, text: library.status(of: .plex))
            if plex.isSignedIn {
                if !plex.servers.isEmpty {
                    Picker("Server", selection: Binding(
                        get: { plex.servers.first { $0.name == plex.serverName } },
                        set: { if let s = $0 { plex.select(server: s) } }
                    )) {
                        ForEach(plex.servers) { Text($0.name).tag(Optional($0)) }
                    }
                }
                Button { Task { await plex.discoverServers() } } label: {
                    if plex.isBusy { ProgressView() } else { Text(plex.servers.isEmpty ? "Find my servers" : "Refresh servers") }
                }
                .disabled(plex.isBusy)
                Button("Sign out", role: .destructive) { plex.signOut() }
            } else if plex.isAwaitingPin, let code = plex.pinCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On any device open plex.tv/link and enter")
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    ProgressView("Waiting for you to link…")
                }
                Button("Cancel") { plex.cancelPinSignIn() }
            } else if plex.isAwaitingPin {
                ProgressView("Requesting code…")
            } else {
                Button("Sign in with plex.tv") { plex.beginPinSignIn() }
                Text("You'll get a 4-letter code to type into plex.tv/link on your phone. The app never sees your password.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let err = plex.errorMessage { ErrorText(err) }
        } header: {
            Label("Plex", systemImage: AppTab.plex.systemImage)
        }
    }

    private var youtubeSection: some View {
        Section {
            Picker("Max quality", selection: $youtube.maxHeight) {
                ForEach(YouTubeClient.maxHeightChoices, id: \.self) { h in
                    Text(h == 2160 ? "4K (2160p)" : "\(h)p").tag(h)
                }
            }
            Toggle("HDR when available", isOn: $youtube.preferHDR)
            Toggle("SponsorBlock (skip sponsors, intros, outros)", isOn: $youtube.sponsorBlockEnabled)
            Text("No account. Streams come straight from YouTube's player API, so there are no ads.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Label("YouTube", systemImage: AppTab.youtube.systemImage)
        }
    }

    private var nasSection: some View {
        Section {
            if nas.shares.isEmpty {
                Text("No shares yet.").foregroundStyle(.secondary)
            }
            ForEach(nas.shares) { share in
                VStack(alignment: .leading, spacing: 2) {
                    Text(share.name).font(.headline)
                    Text("\(share.kind.label) · \(share.address)\(share.username.isEmpty ? " · guest" : " · \(share.username)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in idx.map { nas.shares[$0] }.forEach { nas.remove($0) } }
            Button { showAddShare = true } label: { Label("Add share", systemImage: "plus") }
        } header: {
            Label("NAS", systemImage: AppTab.nas.systemImage)
        } footer: {
            Text("SMB (Windows/Synology/Unraid shares) or WebDAV. Files play directly over the network.")
        }
    }

    private var subwoofer: some View {
        Section {
            StatusRow(connected: bassLink.state == .connected,
                      text: bassLink.state == .connected ? (bassLink.peripheralName ?? "Receiver") : bassLink.state.rawValue.capitalized)
            HStack {
                Button("Connect") { bassLink.start() }.disabled(bassLink.state != .off)
                Button("Disconnect") { bassLink.stop() }.disabled(bassLink.state == .off)
            }
            Toggle("Mute sub", isOn: $bassLink.muted)
            #if os(tvOS)
            AdjustRow(title: "Receiver delay", value: bassLink.extraDelayMs, unit: "ms",
                      minus: { bassLink.extraDelayMs = max(0, bassLink.extraDelayMs - 10) },
                      plus: { bassLink.extraDelayMs = min(400, bassLink.extraDelayMs + 10) })
            AdjustRow(title: "Bass lead", value: leadMs, unit: "ms",
                      minus: { leadMs = max(0, leadMs - 10) },
                      plus: { leadMs = min(300, leadMs + 10) })
            #else
            Stepper("Receiver delay: \(bassLink.extraDelayMs) ms", value: $bassLink.extraDelayMs, in: 0...400, step: 10)
            Stepper("Bass lead: \(leadMs) ms", value: $leadMs, in: 0...300, step: 10)
            #endif
            Text("Thump before the explosion? Raise receiver delay. Thump after? Raise bass lead (holds the headset audio and picture back so the sub catches up).")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Label("Subwoofer receiver", systemImage: "hifispeaker")
        }
    }

    private var diagnostics: some View {
        Section {
            LabeledContent("Packets sent", value: "\(bassLink.packetsSent)")
            LabeledContent("Packets dropped (link busy)", value: "\(bassLink.packetsDropped)")
            LabeledContent("Receiver buffer", value: "\(bassLink.receiverBufferFill) samples")
            LabeledContent("Receiver underruns", value: "\(bassLink.receiverUnderruns)")
        } header: {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            LabeledContent("Player", value: "KSPlayer · FFmpeg 6.1 (patched)")
            Text("Free-account sideloads expire after 7 days; reinstall from iloader to renew.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Label("About", systemImage: "info.circle")
        }
    }
}

// MARK: - Rows

struct StatusRow: View {
    let connected: Bool
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 10, height: 10)
            Text(text).lineLimit(1)
            Spacer()
            Text(connected ? "Connected" : "Off").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
    }
}

#if os(tvOS)
/// tvOS has no Stepper; two buttons do the job.
struct AdjustRow: View {
    let title: String
    let value: Int
    let unit: String
    let minus: () -> Void
    let plus: () -> Void
    var body: some View {
        HStack {
            Text("\(title): \(value) \(unit)")
            Spacer()
            Button("−10", action: minus)
            Button("+10", action: plus)
        }
    }
}
#endif

struct SleepTimerRow: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        HStack {
            Text(library.sleepTimerEnd.map { "Sleep timer: \(Int(max(0, $0.timeIntervalSinceNow / 60))) min left" } ?? "Sleep timer")
            Spacer()
            if library.sleepTimerEnd != nil {
                Button("Off") { library.sleepTimerEnd = nil }
            } else {
                ForEach([30, 60, 90], id: \.self) { m in
                    Button("\(m)m") { library.sleepTimerEnd = Date().addingTimeInterval(TimeInterval(m * 60)) }
                }
            }
        }
    }
}

/// Small always-visible strip showing the sub link (visionOS scene ornament).
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
