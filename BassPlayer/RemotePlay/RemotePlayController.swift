import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import KSPlayer

/// Remote Play: the consoles, pairing, and the one live stream. App-wide (the stream outlives
/// its window, like `PlaybackController`, so the cinema can take over the picture).
@MainActor
final class RemotePlayController: ObservableObject {
    static let shared = RemotePlayController()

    enum StreamState: Equatable {
        case idle
        case waking
        case connecting
        case streaming
        case failed(String)

        var isActive: Bool { self == .waking || self == .connecting || self == .streaming }
    }

    @Published private(set) var consoles: [PSConsole] = []
    @Published var settings: RemotePlaySettings { didSet { saveSettings() } }
    /// Last account ID typed or received, offered for the next pairing.
    @Published var accountIDText: String { didSet { UserDefaults.standard.set(accountIDText, forKey: "rp.accountID") } }
    @Published private(set) var hostStates: [UUID: Chiaki.HostState] = [:]
    @Published private(set) var probing: Set<UUID> = []

    @Published private(set) var state: StreamState = .idle
    @Published private(set) var activeConsole: PSConsole?
    @Published private(set) var controllerName: String?
    @Published var loginPinRequest: LoginPinRequest?
    /// True while the stream is shown on the cinema screen instead of its window.
    @Published var cinemaShowing = false
    /// Fast-changing numbers live in their own object so only the stats label redraws.
    let stats = RemotePlayStats()

    struct LoginPinRequest: Identifiable { let id = UUID(); let incorrect: Bool }

    private var session: ChiakiSession?
    private var decoder: RemotePlayVideoDecoder?
    private var audio: RemotePlayAudio?
    private let input = RemotePlayInput()
    let frameSink = RemotePlayFrameSink()
    private var statsTimer: Timer?
    private var connectTask: Task<Void, Never>?

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "rp.settings"), let s = try? JSONDecoder().decode(RemotePlaySettings.self, from: data) {
            settings = s
        } else {
            settings = RemotePlaySettings()
        }
        accountIDText = d.string(forKey: "rp.accountID") ?? ""
        consoles = RemotePlayVault.load()
        if DemoData.isEnabled, consoles.isEmpty {
            consoles = [PSConsole(name: "PS5", host: "192.168.0.50", isPS5: true, nickname: "PS5-Living-Room",
                                  registKey: Data(repeating: 0x30, count: 16), rpKey: Data(repeating: 1, count: 16),
                                  mac: nil, accountID: Data(repeating: 2, count: 8)),
                        PSConsole(name: "Bedroom", host: "192.168.0.51", isPS5: true)]
            hostStates[consoles[0].id] = .ready
            hostStates[consoles[1].id] = .standby
        }
        input.onControllerChange = { [weak self] name in
            Task { @MainActor in self?.controllerName = name }
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "rp.settings") }
    }

    // MARK: - Consoles

    @discardableResult
    func addConsole(host: String, isPS5: Bool) -> PSConsole {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = PSConsole(name: isPS5 ? "PS5 at \(h)" : "PS4 at \(h)", host: h, isPS5: isPS5)
        consoles.append(c)
        persist()
        refresh(c)
        return c
    }

    func update(_ console: PSConsole) {
        guard let i = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[i] = console
        persist()
    }

    func remove(_ console: PSConsole) {
        consoles.removeAll { $0.id == console.id }
        hostStates[console.id] = nil
        persist()
    }

    func console(_ id: UUID) -> PSConsole? { consoles.first { $0.id == id } }

    private func persist() {
        guard !DemoData.isEnabled else { return }
        RemotePlayVault.save(consoles)
    }

    /// Asks every console (or one) whether it is on, in rest mode or not answering.
    func refresh(_ only: PSConsole? = nil) {
        guard !DemoData.isEnabled else { return }
        for c in only.map({ [$0] }) ?? consoles where !probing.contains(c.id) {
            probing.insert(c.id)
            let host = c.host
            Task.detached(priority: .utility) {
                let r = Chiaki.probe(host: host)
                await MainActor.run {
                    self.probing.remove(c.id)
                    self.hostStates[c.id] = r?.state
                    if let r, var updated = self.console(c.id) {
                        var changed = false
                        if r.isPS5 != updated.isPS5 { updated.isPS5 = r.isPS5; changed = true }
                        if let n = r.name, updated.nickname == nil, updated.name != n { updated.name = n; changed = true }
                        if changed { self.update(updated) }
                    }
                }
            }
        }
    }

    // MARK: - Pairing

    /// Pairs with the console. `pin` may contain spaces.
    func pair(_ console: PSConsole, pin: String, accountID: Data) async throws {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let pinValue = UInt32(digits) else {
            throw PayloadPairing.Failure(errorDescription: "The PIN has 8 digits")
        }
        guard accountID.count == 8 else {
            throw PayloadPairing.Failure(errorDescription: "The account ID isn't valid (8 bytes: base64, 16 hex digits or the number)")
        }
        DiagLog.log("pairing with \(console.host) (\(console.isPS5 ? "PS5" : "PS4"))", "rp")
        let result: ChiakiRegistration.Result = try await withCheckedThrowingContinuation { cont in
            let once = OnceBox()
            var registration: ChiakiRegistration?
            registration = ChiakiRegistration(host: console.host, isPS5: console.isPS5, accountID: accountID, pin: pinValue) { r in
                guard once.take() else { return }
                cont.resume(with: r)
                // Free on a background queue (rp_regist_free joins the finished thread).
                let keep = registration
                registration = nil
                DispatchQueue.global().async { keep?.cancel() }
            }
            if registration == nil, once.take() {
                cont.resume(throwing: PayloadPairing.Failure(errorDescription: "Couldn't start pairing (is the address right?)"))
            }
            // Safety net: the console answers within seconds or not at all.
            let keepAlive = registration
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                if once.take() {
                    cont.resume(throwing: PayloadPairing.Failure(errorDescription: "The console didn't answer the pairing request"))
                    keepAlive?.cancel()
                }
            }
        }
        var c = self.console(console.id) ?? console
        c.registKey = result.registKey
        c.rpKey = result.rpKey
        c.mac = result.mac
        c.accountID = accountID
        c.isPS5 = result.isPS5 || c.isPS5
        if !result.nickname.isEmpty { c.nickname = result.nickname }
        update(c)
        accountIDText = PSNAccountID.base64(accountID)
        DiagLog.log("paired with \(c.displayName)", "rp")
        refresh(c)
    }

    // MARK: - Streaming

    func connect(_ console: PSConsole) {
        guard !state.isActive else { return }
        guard console.isPaired else { state = .failed("Pair this console first"); return }
        activeConsole = console
        stats.reset()
        state = .waking   // shown at once by the stream window that opens next
        connectTask = Task { await self.run(console) }
    }

    private func run(_ console: PSConsole) async {
        // Wake it first if it is in rest mode (or we don't know).
        state = .waking
        let host = console.host
        var probe = await Task.detached { Chiaki.probe(host: host) }.value
        if probe?.state != .ready {
            DiagLog.log("waking \(console.displayName) (state \(String(describing: probe?.state)))", "rp")
            if let e = await Task.detached(operation: { Chiaki.wake(console) }).value {
                DiagLog.log("wake-up failed: \(e)", "rp")
            }
            for _ in 0..<40 {
                if Task.isCancelled { state = .idle; return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                probe = await Task.detached { Chiaki.probe(host: host, timeoutMs: 800) }.value
                if probe?.state == .ready { break }
            }
            guard probe?.state == .ready else {
                state = .failed("The console didn't wake up. Is it on the same network and set to allow Remote Play from rest mode?")
                return
            }
            // A freshly woken PS5 needs a moment before it accepts a session.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if Task.isCancelled { state = .idle; return }
        state = .connecting
        hostStates[console.id] = .ready

        let decoder = RemotePlayVideoDecoder(hevc: settings.codec != .h264)
        let audio = RemotePlayAudio(bassLink: BassLinkHolder.shared)
        let session = ChiakiSession()
        let sink = frameSink
        decoder.onFrame = { pb, time in sink.push(pb, time: time) }
        session.onVideo = { buf, lost, recovered in decoder.decode(buf, framesLost: lost, recovered: recovered) }
        session.onAudioFormat = { ch, rate in audio.configure(channels: ch, sampleRate: rate) }
        session.onAudio = { pcm, frames in audio.push(pcm, frames: frames) }
        session.onEvent = { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        self.decoder = decoder
        self.audio = audio
        self.session = session
        input.motionEnabled = settings.motion
        input.triggerEffectsEnabled = settings.dualSenseEffects

        let config = ChiakiSession.Config(console: console, settings: settings)
        do {
            try await Task.detached { try session.start(config) }.value
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
            return
        }
        input.start(session: session)
        if let link = BassLinkHolder.shared, link.state == .off { link.start() }
        startStatsTimer()
        DiagLog.log("session started with \(console.displayName): \(settings.resolution.label) \(settings.fps60 ? 60 : 30) fps \(settings.codec.label)", "rp")
    }

    private func handle(_ e: ChiakiSession.Event) {
        switch e {
        case .connected:
            state = .streaming
            DiagLog.log("streaming", "rp")
        case .loginPinRequested(let incorrect):
            loginPinRequest = LoginPinRequest(incorrect: incorrect)
        case .quit(let text, let isError):
            DiagLog.log("session ended: \(text)", "rp")
            teardown()
            state = isError ? .failed(text) : .idle
        case .rumble(let l, let r):
            input.rumble(left: l, right: r)
        case .triggerEffects(let lt, let l, let rt, let r):
            input.triggerEffects(leftType: lt, left: l, rightType: rt, right: r)
        case .led:
            break
        case .nickname(let name):
            if var c = activeConsole, c.nickname == nil { c.nickname = name; update(c); activeConsole = c }
        }
    }

    func submitLoginPin(_ pin: String) {
        loginPinRequest = nil
        session?.setLoginPin(pin)
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        teardown()
        state = .idle
    }

    func sleepConsole() {
        session?.sleepConsole()
    }

    func requestKeyframe() {
        session?.requestKeyframe()
    }

    private func teardown() {
        statsTimer?.invalidate()
        statsTimer = nil
        input.stop()
        let session = self.session
        let audio = self.audio
        let decoder = self.decoder
        self.session = nil
        self.audio = nil
        self.decoder = nil
        frameSink.clear()
        // rp_session_free joins chiaki's threads; never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stop()
            audio?.stop()
            decoder?.invalidate()
            _ = session
        }
    }

    private var lastDecoded = 0
    private var lastStatsLog = Date()

    private func startStatsTimer() {
        statsTimer?.invalidate()
        lastDecoded = 0
        lastStatsLog = Date()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickStats() }
        }
    }

    private func tickStats() {
        guard let decoder = self.decoder else { return }
        let s = decoder.stats
        let fps = s.decoded - lastDecoded
        lastDecoded = s.decoded
        self.stats.update(fps: fps, stats: s, audioMs: self.audio?.bufferedMs ?? 0,
                          underruns: self.audio?.underruns ?? 0, codec: decoder.codec.rawValue)
        if Date().timeIntervalSince(lastStatsLog) >= 10 {
            lastStatsLog = Date()
            DiagLog.log("stream: \(s.width)x\(s.height) \(decoder.codec.rawValue)\(s.hdr ? " HDR" : "") \(fps) fps · decoded \(s.decoded) failed \(s.failed) lost \(s.lost) · audio \(Int(self.audio?.bufferedMs ?? 0)) ms, \(self.audio?.underruns ?? 0) underruns, \(self.audio?.trims ?? 0) trims · cinema \(self.frameSink.cinemaFrames)", "rp")
        }
    }

    // MARK: - Cinema

    #if os(visionOS)
    /// The cinema closed while a stream is running: bring the stream window back.
    func noteCinemaClosed(openWindow: OpenWindowAction) {
        guard cinemaShowing else { return }
        cinemaShowing = false
        frameSink.setCinema(false)
        if state.isActive { openWindow(id: RemotePlayWindow.id) }
    }
    #endif
}

/// One-shot flag for continuations that several callbacks race to resume.
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Numbers for the stream overlay, published once a second.
@MainActor
final class RemotePlayStats: ObservableObject {
    @Published private(set) var fps = 0
    @Published private(set) var size = ""
    @Published private(set) var failed = 0
    @Published private(set) var lost = 0
    @Published private(set) var audioMs = 0
    @Published private(set) var underruns = 0

    func reset() { fps = 0; size = ""; failed = 0; lost = 0; audioMs = 0; underruns = 0 }

    func update(fps: Int, stats s: RemotePlayVideoDecoder.Stats, audioMs: Double, underruns: Int, codec: String) {
        self.fps = fps
        let sz = s.width > 0 ? "\(s.width)×\(s.height) \(codec)\(s.hdr ? " HDR" : "")" : codec
        if size != sz { size = sz }
        if failed != s.failed { failed = s.failed }
        if lost != s.lost { lost = s.lost }
        self.audioMs = Int(audioMs)
        if self.underruns != underruns { self.underruns = underruns }
    }
}

/// Where decoded frames go: the stream window's display layer (any thread) and, while it is
/// open, the cinema screen (main thread, newest frame only).
final class RemotePlayFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?
    private var formatKey = ""
    private var pendingCinema: (CVPixelBuffer, CMTime)?
    private var cinemaScheduled = false
    private(set) var cinemaFrames = 0
    private var cinemaActive = false

    /// While the cinema shows the stream, frames go there instead of the window's layer.
    func setCinema(_ on: Bool) {
        lock.lock(); cinemaActive = on; if !on { pendingCinema = nil }; lock.unlock()
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); self.layer = layer; lock.unlock()
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); if self.layer === layer { self.layer = nil }; lock.unlock()
    }

    func clear() {
        lock.lock()
        let l = layer
        pendingCinema = nil
        lock.unlock()
        DispatchQueue.main.async { l?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }

    func push(_ pb: CVPixelBuffer, time: CMTime) {
        lock.lock()
        let l = layer
        let cinema = cinemaActive
        var schedule = false
        if cinema {
            pendingCinema = (pb, time)
            if !cinemaScheduled { cinemaScheduled = true; schedule = true }
        }
        lock.unlock()

        if let l, !cinema, let sample = makeSample(pb, time: time) {
            let r = l.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sample)
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.deliverCinema() }
        }
    }

    /// Main queue only.
    private func deliverCinema() {
        lock.lock()
        let f = pendingCinema
        pendingCinema = nil
        cinemaScheduled = false
        lock.unlock()
        guard let f, let push = ImmersiveScreenBridge.shared.pushFrame else { return }
        push(f.0, f.1, nil)
        cinemaFrames += 1
    }

    private func makeSample(_ pb: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        let key = "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))-\(CVPixelBufferGetPixelFormatType(pb))"
        if format == nil || key != formatKey {
            format = try? CMVideoFormatDescription(imageBuffer: pb)
            formatKey = key
        }
        guard let format else { return nil }
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard let sample = try? CMSampleBuffer(imageBuffer: pb, formatDescription: format, sampleTiming: timing) else { return nil }
        sample.sampleAttachments[0][.displayImmediately] = true
        return sample
    }
}

enum RemotePlayWindow {
    static let id = "remoteplay"
}
