import SwiftUI
import UniformTypeIdentifiers

/// PlayStation tab: consoles, pairing and stream settings. Streaming itself opens its own
/// window (visionOS) or covers the screen (tvOS).
struct RemotePlayView: View {
    @ObservedObject private var rp = RemotePlayController.shared
    @State private var newHost = ""
    @State private var newIsPS5 = true
    @State private var path: [UUID] = []
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(tvOS)
    @State private var showStream = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if rp.state != .idle, let c = rp.activeConsole { activeSection(c) }
                consolesSection
                addSection
                streamSection
                aboutSection
            }
            #if !os(tvOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("PlayStation")
            .navigationDestination(for: UUID.self) { id in
                RemotePlayConsoleView(consoleID: id, play: { play($0) })
            }
            .toolbar {
                ToolbarItem {
                    Button { rp.refresh() } label: { Label("Check consoles", systemImage: "arrow.clockwise") }
                }
            }
            .onAppear { rp.refresh() }
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showStream) { RemotePlayStreamView() }
        .onChange(of: rp.state) { _, s in if s == .idle { showStream = false } }
        #endif
    }

    private func play(_ c: PSConsole) {
        rp.connect(c)
        #if os(visionOS)
        openWindow(id: RemotePlayWindow.id)
        #else
        showStream = true
        #endif
    }

    // MARK: Sections

    private func activeSection(_ c: PSConsole) -> some View {
        Section {
            HStack {
                Image(systemName: "gamecontroller.fill")
                VStack(alignment: .leading) {
                    Text(c.displayName).font(.headline)
                    Text(stateText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if rp.state.isActive {
                Button {
                    #if os(visionOS)
                    openWindow(id: RemotePlayWindow.id)
                    #else
                    showStream = true
                    #endif
                } label: { Label("Show stream", systemImage: "rectangle.on.rectangle") }
                Button(role: .destructive) { rp.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
            }
        } header: {
            Label("Now playing", systemImage: "play.circle")
        }
    }

    private var stateText: String {
        switch rp.state {
        case .idle: return "Not connected"
        case .waking: return "Waking the console…"
        case .connecting: return "Connecting…"
        case .streaming: return "Streaming" + (rp.controllerName.map { " · \($0)" } ?? " · no controller")
        case .failed(let e): return e
        }
    }

    private var consolesSection: some View {
        Section {
            if rp.consoles.isEmpty {
                Text("No consoles yet. Add your PS5 by its IP address below (Settings › Network › Connection Status on the console).")
                    .foregroundStyle(.secondary)
            }
            ForEach(rp.consoles) { c in
                NavigationLink(value: c.id) {
                    RemotePlayConsoleRow(console: c, state: rp.hostStates[c.id], checking: rp.probing.contains(c.id))
                }
            }
        } header: {
            Label("Consoles", systemImage: "playstation.logo")
        }
    }

    private var addSection: some View {
        Section {
            TextField("IP address, e.g. 192.168.0.50", text: $newHost)
                #if !os(tvOS)
                .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                #endif
            Picker("Console", selection: $newIsPS5) {
                Text("PS5").tag(true)
                Text("PS4").tag(false)
            }
            Button {
                let c = rp.addConsole(host: newHost, isPS5: newIsPS5)
                newHost = ""
                path.append(c.id)
            } label: { Label("Add console", systemImage: "plus.circle") }
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Label("Add a console", systemImage: "plus")
        } footer: {
            Text("The console and the headset must be on the same home network. Remote Play here is local only: no PlayStation Network sign-in.")
        }
    }

    private var streamSection: some View {
        Section {
            Picker("Resolution", selection: $rp.settings.resolution) {
                ForEach(RemotePlaySettings.Resolution.allCases) { Text($0.label).tag($0) }
            }
            Toggle("60 frames per second", isOn: $rp.settings.fps60)
            Picker("Video codec", selection: $rp.settings.codec) {
                ForEach(RemotePlaySettings.Codec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Bitrate", selection: $rp.settings.bitrateKbps) {
                Text("Automatic").tag(0)
                ForEach([10_000, 15_000, 20_000, 30_000, 40_000], id: \.self) { Text("\($0 / 1000) Mbit/s").tag($0) }
            }
            Toggle("Adaptive triggers (DualSense)", isOn: $rp.settings.dualSenseEffects)
            Toggle("Motion controls", isOn: $rp.settings.motion)
        } header: {
            Label("Stream", systemImage: "slider.horizontal.3")
        } footer: {
            Text("Changes apply from the next connection. H.265 looks better at the same bitrate; HDR needs HDR turned on in the console's Screen and Video settings. The PS5 sends at most 1080p over Remote Play.")
        }
    }

    private var aboutSection: some View {
        Section {
            Text("Pair once with the 8-digit PIN from Settings › System › Remote Play › Link Device and the account ID of the user signed in on the console. On a jailbroken PS5 the app can get both from the console itself (idlesauce's get-pin payload).")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Uses chiaki-ng (AGPL-3.0). Not affiliated with or endorsed by Sony Interactive Entertainment.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Label("About Remote Play", systemImage: "info.circle")
        }
    }
}

struct RemotePlayConsoleRow: View {
    let console: PSConsole
    let state: Chiaki.HostState?
    let checking: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: console.isPS5 ? "rectangle.portrait.fill" : "rectangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(console.displayName).font(.headline)
                Text("\(console.host) · \(console.isPS5 ? "PS5" : "PS4") · \(console.isPaired ? "paired" : "not paired")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if checking {
                ProgressView()
            } else {
                Text(label).font(.caption).foregroundStyle(color)
            }
        }
    }

    private var label: String {
        switch state {
        case .ready: return "On"
        case .standby: return "Rest mode"
        case .unknown: return "Unknown"
        case nil: return "Not answering"
        }
    }

    private var color: Color {
        switch state {
        case .ready: return .green
        case .standby: return .orange
        default: return .secondary
        }
    }
}

/// One console: play, pair (payload or manual), wake, edit, forget.
struct RemotePlayConsoleView: View {
    let consoleID: UUID
    let play: (PSConsole) -> Void
    @ObservedObject private var rp = RemotePlayController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var accountText = ""
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var payload: PayloadPairing?
    @State private var showImporter = false
    @State private var confirmForget = false

    var body: some View {
        Form {
            if let c = rp.console(consoleID) {
                playSection(c)
                pairSection(c)
                consoleSection(c)
            } else {
                Text("This console was removed.")
            }
        }
        #if !os(tvOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(rp.console(consoleID)?.displayName ?? "Console")
        .onAppear {
            if accountText.isEmpty {
                accountText = rp.console(consoleID)?.accountID.map(PSNAccountID.base64) ?? rp.accountIDText
            }
            if let c = rp.console(consoleID) { rp.refresh(c) }
        }
        .onDisappear { payload?.close(); payload = nil }
        #if !os(tvOS)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result {
                do {
                    _ = try PayloadPairing.importPayload(from: url)
                    show("Payload saved. Tap \u{201C}Get PIN from the PS5\u{201D}.", error: false)
                } catch {
                    show(error.localizedDescription, error: true)
                }
            }
        }
        #endif
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    // MARK: Sections

    private func playSection(_ c: PSConsole) -> some View {
        Section {
            if c.isPaired {
                Button { play(c) } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(rp.state.isActive)
                Button {
                    Task {
                        let e = await Task.detached { Chiaki.wake(c) }.value
                        if let e { show("Wake-up failed: \(e)", error: true) } else { show("Wake-up sent.", error: false) }
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        rp.refresh(c)
                    }
                } label: { Label("Wake from rest mode", systemImage: "power") }
            } else {
                Text("Pair this console below to play.").foregroundStyle(.secondary)
            }
            RemotePlayConsoleRow(console: c, state: rp.hostStates[c.id], checking: rp.probing.contains(c.id))
        } header: {
            Label("Play", systemImage: "gamecontroller")
        }
    }

    private func pairSection(_ c: PSConsole) -> some View {
        Section {
            if c.isPS5 {
                Button {
                    Task { await payloadPair(c) }
                } label: {
                    Label(PayloadPairing.hasCachedPayload ? "Get PIN from the PS5 (jailbroken)" : "Download payload and get PIN (jailbroken PS5)",
                          systemImage: "bolt.horizontal.circle")
                }
                .disabled(busy)
                #if !os(tvOS)
                Button { showImporter = true } label: { Label("Use a payload file…", systemImage: "doc") }
                    .disabled(busy)
                #endif
            }
            TextField("PIN (8 digits)", text: $pin)
                #if !os(tvOS)
                .keyboardType(.numberPad)
                #endif
            TextField("Account ID (base64, hex or number)", text: $accountText)
                #if !os(tvOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            Button {
                Task { await manualPair(c) }
            } label: { Label(c.isPaired ? "Pair again" : "Pair", systemImage: "link") }
                .disabled(busy || pin.filter(\.isNumber).count != 8 || PSNAccountID.parse(accountText) == nil)
            if busy { ProgressView() }
            if let message {
                Text(message).font(.callout).foregroundStyle(messageIsError ? Color.red : Color.secondary)
            }
        } header: {
            Label("Pairing", systemImage: "link")
        } footer: {
            Text(c.isPS5
                 ? "Jailbroken PS5: start the ELF loader (port 9021) and activate your account offline with offact, then tap the payload button: it gets a PIN and the right account ID from the console and pairs. Otherwise: on the console open Settings › System › Remote Play › Link Device and type the number here with your account ID."
                 : "On the PS4 open Settings › Remote Play Connection Settings › Add Device and type the number here with your account ID.")
        }
    }

    private func consoleSection(_ c: PSConsole) -> some View {
        Section {
            TextField("Name", text: Binding(get: { rp.console(consoleID)?.name ?? "" }, set: { v in
                if var x = rp.console(consoleID) { x.name = v; rp.update(x) }
            }))
            TextField("Address", text: Binding(get: { rp.console(consoleID)?.host ?? "" }, set: { v in
                if var x = rp.console(consoleID) { x.host = v.trimmingCharacters(in: .whitespaces); rp.update(x) }
            }))
            #if !os(tvOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            Toggle("PS5", isOn: Binding(get: { rp.console(consoleID)?.isPS5 ?? true }, set: { v in
                if var x = rp.console(consoleID) { x.isPS5 = v; rp.update(x) }
            }))
            Button(role: .destructive) { confirmForget = true } label: { Label("Forget this console", systemImage: "trash") }
                .confirmationDialog("Forget \(c.displayName)?", isPresented: $confirmForget) {
                    Button("Forget", role: .destructive) { rp.remove(c); dismiss() }
                }
        } header: {
            Label("Console", systemImage: "info.circle")
        }
    }

    // MARK: Actions

    private func payloadPair(_ c: PSConsole) async {
        busy = true
        defer { busy = false }
        do {
            let elf: Data
            if PayloadPairing.hasCachedPayload {
                elf = try Data(contentsOf: PayloadPairing.cachedURL)
            } else {
                show("Downloading the payload from GitHub…", error: false)
                elf = try await PayloadPairing.downloadPayload()
            }
            show("Sending the payload to \(c.host):9021…", error: false)
            let p = PayloadPairing()
            payload?.close()
            payload = p
            let code = try await p.run(host: c.host, payload: elf)
            pin = code.pinText
            accountText = code.accountText
            show("PIN \(code.pinText) received. Pairing…", error: false)
            try await rp.pair(c, pin: code.pinText, accountID: code.accountID)
            p.close()
            payload = nil
            show("Paired. You can play now.", error: false)
        } catch {
            payload?.close()
            payload = nil
            show(error.localizedDescription, error: true)
        }
    }

    private func manualPair(_ c: PSConsole) async {
        guard let account = PSNAccountID.parse(accountText) else { show("That account ID isn't valid", error: true); return }
        busy = true
        defer { busy = false }
        show("Pairing…", error: false)
        do {
            try await rp.pair(c, pin: pin, accountID: account)
            payload?.close()
            payload = nil
            show("Paired. You can play now.", error: false)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }
}
