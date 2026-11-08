import SwiftUI
import AVFoundation
import Metal
import KSPlayer

/// Global KSPlayer configuration. Called once from the App init.
enum FFmpegConfig {
    static func apply() {
        KSOptions.firstPlayerType = KSMEPlayer.self          // FFmpeg first: MKV, DTS, TrueHD, FLAC, AV1…
        KSOptions.secondPlayerType = KSAVPlayer.self         // fall back to AVPlayer if FFmpeg can't open it
        KSOptions.audioPlayerType = AudioEnginePlayer.self   // we tap its AVAudioEngine for the bass
        KSOptions.hardwareDecode = true                      // VideoToolbox via FFmpeg hwaccel
        // Keep FFmpeg in charge of the HEVC bitstream (not KSPlayer's own VideoToolbox session):
        // that way the Dolby Vision RPU is parsed and attached to every frame, which the
        // profile 5 shader needs. Profile 7's enhancement layer is dropped by FFmpeg, so P7
        // plays as its HDR10 base layer; profile 8 is HDR10/HLG-compatible by design.
        KSOptions.asynchronousDecompression = false
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true
        KSOptions.preferredForwardBufferDuration = 4
        KSOptions.maxBufferDuration = 60
        KSOptions.logLevel = .warning
    }

    /// Per-item options. HDR10 / HLG / Dolby Vision are passed through to the display
    /// (`destinationDynamicRange = nil` lets KSPlayer pick the best mode the screen supports).
    static func makeOptions() -> BassPlayerOptions {
        let o = BassPlayerOptions()
        o.destinationDynamicRange = nil
        o.autoDeInterlace = true
        o.autoSelectEmbedSubtitle = true
        o.userAgent = "BassPlayer/0.2"
        o.videoAdaptable = false
        return o
    }
}

/// KSOptions with 3D awareness: when one eye of a packed frame is shown on a flat display,
/// report the un-squeezed aspect so the picture isn't stretched.
final class BassPlayerOptions: KSOptions {
    /// Stereo packing of the current file, and whether the flat view should crop to one eye.
    var stereo: StereoFormat = .mono
    var cropToOneEye = false

    override func customizeDar(sar: CGSize, par: CGSize) -> CGSize? {
        guard cropToOneEye, stereo.isPacked, par.width > 0, par.height > 0 else { return nil }
        let aspect = stereo.displayAspect(frameWidth: Double(par.width), frameHeight: Double(par.height))
        return CGSize(width: aspect * 1000, height: 1000)
    }
}

/// Owns the bass pipeline for one FFmpeg playback and exposes decoded frames for the immersive screen.
@MainActor
final class FFmpegSession: ObservableObject {
    let options = FFmpegConfig.makeOptions()
    let extractor = BassExtractor()
    let tap: BassEngineTap
    @Published private(set) var tapInstalled = false
    @Published private(set) var backendName = "—"
    @Published private(set) var audioFormat = "—"

    private weak var coordinator: KSVideoPlayer.Coordinator?
    private var pollTimer: Timer?
    private let bassLink: BassLink
    private var sponsorSkipper = SponsorSkipper()
    @Published private(set) var sponsorSkips = 0
    @Published private(set) var finished = false
    private var item: MediaItem?
    private weak var library: LibraryStore?
    private var lastProgressSave: Date = .distantPast
    private var lastServerReport: Date = .distantPast
    private var reportedStart = false
    private var lastKnownPosition: Double = 0
    private var lastKnownDuration: Double = 0
    private var sleepFired = false

    private lazy var doviRenderer = DoviFrameRenderer()
    private var lastFrameId: ObjectIdentifier?
    private var frameCounter = 0

    /// Current decoded frame for the RealityKit screen. Dolby Vision profile 5 frames are
    /// pre-mapped into a PQ texture because CoreImage can't interpret IPT. Nil when idle.
    var currentScreenFrame: ScreenFrame? {
        guard let me = coordinator?.playerLayer?.player as? KSMEPlayer, let output = me.videoOutput else { return nil }
        if let view = output as? MetalPlayView, let frame = view.currentFrame, DoviFrameRenderer.needsMapping(frame) {
            let id = ObjectIdentifier(frame)
            if id != lastFrameId { lastFrameId = id; frameCounter += 1 }
            guard let tex = doviRenderer.render(frame: frame) else { return nil }
            return ScreenFrame(pixelBuffer: nil, pqTexture: tex, id: frameCounter)
        }
        guard let pb = output.pixelBuffer?.cvPixelBuffer else { return nil }
        return ScreenFrame(pixelBuffer: pb, pqTexture: nil, id: Int(bitPattern: Unmanaged.passUnretained(pb).toOpaque()))
    }

    /// Human-readable Dolby Vision status for the UI.
    var doviStatus: String? {
        guard let me = coordinator?.playerLayer?.player as? KSMEPlayer, let view = me.videoOutput as? MetalPlayView,
              let frame = view.currentFrame, let d = frame.dovi else { return nil }
        return d.needsMapping ? "DV P\(d.profile) mapped" : "DV P\(d.profile) base layer"
    }

    init(bassLink: BassLink) {
        self.bassLink = bassLink
        tap = BassEngineTap(extractor: extractor)
        extractor.onPacket = { [weak bassLink] packet in bassLink?.send(packet) }
    }

    func start(coordinator: KSVideoPlayer.Coordinator, leadMs: Int, item: MediaItem? = nil, library: LibraryStore? = nil) {
        self.coordinator = coordinator
        self.item = item
        self.library = library
        tap.leadMs = leadMs
        options.videoDelay = Double(leadMs) / 1000
        if let ua = item?.userAgent { options.userAgent = ua }    // YouTube URLs are tied to the requesting client
        sponsorSkipper = SponsorSkipper()
        finished = false
        reportedStart = false
        sleepFired = false
        if let item, let library {
            library.noteStarted(item)
            if library.resumePlayback, let pos = library.savedPosition(for: item), pos > 30 {
                options.startPlayTime = pos        // KSPlayer seeks here once the file opens
            }
        }
        pollTimer?.invalidate()
        // KSVideoPlayerView owns the state callbacks, so we poll briefly until the engine exists.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func setLead(ms: Int) {
        tap.leadMs = ms
        options.videoDelay = Double(ms) / 1000
    }

    /// Apply the 3D mode. `immersiveStereo` = the cinema screen is showing both eyes, so the
    /// decoder must deliver the whole packed frame and the flat view keeps the squeezed picture.
    func setStereo(_ format: StereoFormat, immersiveStereo: Bool) {
        options.stereo = format
        options.cropToOneEye = format.isPacked && !immersiveStereo
        applyCrop()
        ImmersiveScreenBridge.shared.stereoFormat = format
    }

    private func applyCrop() {
        guard let me = coordinator?.playerLayer?.player as? KSMEPlayer, let view = me.videoOutput as? MetalPlayView else { return }
        view.contentsCrop = options.cropToOneEye ? options.stereo.leftEyeRect : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func setSponsorSegments(_ segments: [SponsorBlockClient.Segment]) {
        sponsorSkipper.segments = segments
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tap.detach()
        tapInstalled = false
        if let item, let library, lastKnownPosition > 0 {
            library.savePosition(lastKnownPosition, duration: lastKnownDuration, for: item)
            let pos = lastKnownPosition, dur = lastKnownDuration
            Task { await library.report(item, position: pos, duration: dur, state: .stopped) }
        }
    }

    private func trackProgress(layer: KSPlayerLayer) {
        guard let item, let library else { return }
        let player = layer.player
        let pos = player.currentPlaybackTime
        let dur = player.duration
        guard pos.isFinite, pos > 0 else { return }
        lastKnownPosition = pos
        lastKnownDuration = dur.isFinite ? dur : 0
        let now = Date()
        if !reportedStart, layer.state.isPlaying {
            reportedStart = true
            Task { await library.report(item, position: pos, duration: lastKnownDuration, state: .started) }
        }
        if now.timeIntervalSince(lastProgressSave) > 5 {
            lastProgressSave = now
            library.savePosition(pos, duration: lastKnownDuration, for: item)
        }
        if now.timeIntervalSince(lastServerReport) > 20, layer.state.isPlaying {
            lastServerReport = now
            Task { await library.report(item, position: pos, duration: lastKnownDuration, state: .progress) }
        }
        if layer.state == .playedToTheEnd, !finished {
            finished = true
            library.savePosition(lastKnownDuration, duration: lastKnownDuration, for: item)
        }
        if let end = library.sleepTimerEnd, now >= end, !sleepFired {
            sleepFired = true
            layer.pause()
            library.sleepTimerEnd = nil
        }
    }

    private func poll() {
        guard let layer = coordinator?.playerLayer else { return }
        let player = layer.player
        backendName = player is KSMEPlayer ? "FFmpeg" : "AVPlayer"
        trackProgress(layer: layer)
        // SponsorBlock: jump over marked segments.
        if !sponsorSkipper.segments.isEmpty, layer.state == .bufferFinished || layer.state == .readyToPlay,
           let target = sponsorSkipper.skipTarget(at: player.currentPlaybackTime) {
            sponsorSkips += 1
            layer.seek(time: target, autoPlay: true) { _ in }
        }
        guard let me = player as? KSMEPlayer else { return }
        guard layer.state == .readyToPlay || layer.state == .bufferFinished || layer.state == .buffering || layer.state == .paused else { return }
        applyCrop()
        tap.attach(to: me.audioOutput)
        if let engine = (me.audioOutput as? AudioEnginePlayer)?.engine {
            let f = engine.mainMixerNode.outputFormat(forBus: 0)
            if f.sampleRate > 0 {
                audioFormat = "\(Int(f.sampleRate)) Hz · \(f.channelCount) ch"
                if !tapInstalled { tapInstalled = true }
            }
        }
    }
}

/// SwiftUI player using KSPlayer's full-featured view (controls, subtitles, track picker).
struct FFmpegPlayerView: View {
    let item: MediaItem
    let url: URL
    var onFinished: (() -> Void)? = nil

    @EnvironmentObject private var bassLink: BassLink
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var session: FFmpegSession
    @AppStorage("bass.leadMs") private var leadMs: Int = 0
    #if os(visionOS)
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    #endif

    private var immersiveStereoActive: Bool {
        #if os(visionOS)
        return immersive.isOpen && library.effectiveStereo(for: item).isPacked
        #else
        return false
        #endif
    }

    init(item: MediaItem, url: URL, onFinished: (() -> Void)? = nil) {
        self.item = item
        self.url = url
        self.onFinished = onFinished
        _session = StateObject(wrappedValue: FFmpegSession(bassLink: BassLinkHolder.shared))
    }

    var body: some View {
        KSVideoPlayerView(coordinator: coordinator, url: url, options: session.options, title: item.title,
                          subtitleDataSouce: item.subtitleURLs.isEmpty ? nil : URLSubtitleDataSouce(urls: item.subtitleURLs))
            .overlay(alignment: .topTrailing) { statusChip.padding(12) }
            .onAppear {
                if bassLink.state == .off { bassLink.start() }
                session.start(coordinator: coordinator, leadMs: leadMs, item: item, library: library)
                session.setStereo(library.effectiveStereo(for: item), immersiveStereo: immersiveStereoActive)
                ImmersiveScreenBridge.shared.projection = library.effectiveProjection(for: item)
                if item.source == .youtube {
                    Task { session.setSponsorSegments(await library.youtube.sponsorSegments(for: item)) }
                }
                ImmersiveScreenBridge.shared.frameSource = { [weak session] in session?.currentScreenFrame }
                ImmersiveScreenBridge.shared.avPlayer = nil
            }
            .onDisappear {
                session.stop()
                ImmersiveScreenBridge.shared.frameSource = nil
                ImmersiveScreenBridge.shared.stereoFormat = .mono
                ImmersiveScreenBridge.shared.projection = .flat
            }
            .onChange(of: leadMs) { _, new in session.setLead(ms: new) }
            .onChange(of: library.effectiveStereo(for: item)) { _, new in session.setStereo(new, immersiveStereo: immersiveStereoActive) }
            .onChange(of: immersiveStereoActive) { _, _ in session.setStereo(library.effectiveStereo(for: item), immersiveStereo: immersiveStereoActive) }
            .onChange(of: library.effectiveProjection(for: item)) { _, new in ImmersiveScreenBridge.shared.projection = new }
            .onChange(of: session.finished) { _, done in if done { onFinished?() } }
    }

    private var statusChip: some View {
        HStack(spacing: 8) {
            Image(systemName: session.tapInstalled ? "waveform" : "waveform.slash")
            Text(session.tapInstalled ? "Bass tap · \(session.audioFormat)" : "Bass tap off")
            Text("·")
            Text(session.backendName)
            if let dv = session.doviStatus { Text("·"); Text(dv) }
            if session.sponsorSkips > 0 { Text("·"); Text("Skipped \(session.sponsorSkips)") }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .foregroundStyle(session.tapInstalled ? .green : .secondary)
        .allowsHitTesting(false)
    }
}

/// A frame for the immersive screen: either a raw decoded pixel buffer (CoreImage handles the
/// colour), or an already colour-mapped PQ BT.2020 texture (Dolby Vision profile 5).
struct ScreenFrame {
    let pixelBuffer: CVPixelBuffer?
    let pqTexture: MTLTexture?
    /// Changes whenever the content changes; lets the consumer skip duplicate uploads.
    let id: Int
}

/// Lets the immersive screen (visionOS) pull frames from whichever player is active.
/// Kept platform-neutral so the shared player code compiles on tvOS too.
final class ImmersiveScreenBridge {
    static let shared = ImmersiveScreenBridge()
    /// Returns the latest decoded frame, or nil.
    var frameSource: (() -> ScreenFrame?)?
    /// Packing of the current film; the screen splits packed frames into two eyes.
    var stereoFormat: StereoFormat = .mono
    /// Flat screen or VR sphere.
    var projection: ScreenProjection = .flat
    /// Set when the AVPlayer backend is active (MV-HEVC): the screen then uses RealityKit's own
    /// video component, which renders stereo natively.
    var avPlayer: AVPlayer?
}
