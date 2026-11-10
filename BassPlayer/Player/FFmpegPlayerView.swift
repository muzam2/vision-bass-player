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
        // Off: "instant open" let audio start before any video was decoded (and after seeks,
        // with half the buffer), so on software-decoded YouTube the sound ran ahead while the
        // picture caught up. Now both must have preferredForwardBufferDuration buffered.
        KSOptions.isSecondOpen = false
        // Seconds of buffered media KSPlayer wants before it starts / resumes after a seek. 4 s
        // meant 3–9 s seek latency on 4K60 YouTube (fetch + software VP9 decode of 4 s of video
        // before the first frame); 1.5 s is enough with the 60 s max buffer behind it.
        KSOptions.preferredForwardBufferDuration = 1.5
        // The 90 Hz panel can't pace a display link at 23.976/24/25 Hz (it lands on 22.5 or
        // 18 Hz, the video falls ~0.2 s behind the audio clock and KSPlayer drops frames every
        // few hundred ms — the "jitter" seen on every film). Run the link at panel rate instead.
        KSOptions.preferredFrame = false
        KSOptions.maxBufferDuration = 60
        KSOptions.logLevel = .warning
        KSOptions.logger = DiagLog.shared                    // KSPlayer messages land in Settings → Diagnostics
        SubtitleModel.textFontSize = 40
    }

    /// Per-item options. HDR10 / HLG / Dolby Vision are passed through to the display
    /// (`destinationDynamicRange = nil` lets KSPlayer pick the best mode the screen supports).
    static func makeOptions() -> BassPlayerOptions {
        let o = BassPlayerOptions()
        o.destinationDynamicRange = nil
        // Off: it inserts the software `idet` filter into a VideoToolbox (hardware-frame)
        // pipeline, which can't be configured; KSPlayer still de-interlaces streams whose
        // field order says interlaced (KSOptions.process(assetTrack:)) by other means.
        o.autoDeInterlace = false
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
    /// Peak of the extracted sub-bass over the last poll interval, in dBFS (-120 = silence).
    @Published private(set) var bassLevelDb: Float = -120
    private var lastBassLog: Date = .distantPast

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
    private weak var sinkView: MetalPlayView?

    /// Mirror every rendered frame to the immersive screen while it is open. Dolby Vision
    /// profile 5 frames are colour-mapped first (the system renderer can't interpret IPT).
    private func installFrameSink(on view: MetalPlayView) {
        guard sinkView !== view else { return }
        sinkView = view
        view.frameSink = { [weak self] frame, pixelBuffer, time in
            guard let push = ImmersiveScreenBridge.shared.pushFrame else { return }
            var dovi: MTLTexture?
            if DoviFrameRenderer.needsMapping(frame), let self {
                dovi = self.doviRenderer.render(frame: frame)
            }
            push(pixelBuffer, time, dovi)
        }
        DiagLog.log("frame sink installed", "player")
    }

    /// Human-readable Dolby Vision status for the UI.
    var doviStatus: String? {
        guard let me = coordinator?.playerLayer?.player as? KSMEPlayer, let view = me.videoOutput as? MetalPlayView,
              let frame = view.currentFrame, let d = frame.dovi else { return nil }
        return d.needsMapping ? "DV P\(d.profile) mapped" : "DV P\(d.profile) base layer"
    }

    /// True once KSPlayer's MVC decoder has produced a stereo pair: frames are then full
    /// side-by-side whatever the item's declared format says.
    @Published private(set) var mvcStereo = false
    private var requestedStereo: StereoFormat = .mono
    private var requestedImmersiveStereo = false

    init(bassLink: BassLink) {
        self.bassLink = bassLink
        tap = BassEngineTap(extractor: extractor)
        extractor.onPacket = { [weak bassLink] packet in bassLink?.send(packet) }
    }

    /// Open-time options. Must run before the view is built: KSPlayer creates its player layer
    /// (and starts opening the URL) in makeUIView, which can precede onAppear.
    func configure(for item: MediaItem) {
        if let ua = item.userAgent { options.userAgent = ua }    // YouTube URLs are tied to the requesting client
        if item.source == .youtube {
            // YouTube plays from a local single-variant master (HLSVariantPicker) whose
            // playlists and segments are https: a file-opened HLS is limited to local protocols
            // unless whitelisted.
            options.formatContextOptions["protocol_whitelist"] = "file,http,https,tcp,tls,crypto,data"
        }
    }

    func start(coordinator: KSVideoPlayer.Coordinator, leadMs: Int, item: MediaItem? = nil, library: LibraryStore? = nil) {
        self.coordinator = coordinator
        self.item = item
        self.library = library
        tap.leadMs = leadMs
        options.videoDelay = Double(leadMs) / 1000
        sponsorSkipper = SponsorSkipper()
        finished = false
        reportedStart = false
        sleepFired = false
        if let item, let library {
            library.noteStarted(item)
            // YouTube resume needs the backported mov/hls seek fixes in Vendor/FFmpegKit.
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
        requestedStereo = format
        requestedImmersiveStereo = immersiveStereo
        // MVC decoded by edge264 arrives as full side-by-side; a declared-but-undecoded MVC
        // file is just the 2D base view.
        let effective: StereoFormat = mvcStereo ? .sbsFull : (format == .mvcPacked ? .mono : format)
        options.stereo = effective
        options.cropToOneEye = effective.isPacked && !immersiveStereo
        applyCrop()
        ImmersiveScreenBridge.shared.stereoFormat = effective
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
        if let view = me.videoOutput as? MetalPlayView { installFrameSink(on: view) }
        let mvc = me.tracks(mediaType: .video).contains { ($0 as? FFmpegAssetTrack)?.decodesStereoSideBySide == true }
        if mvc != mvcStereo {
            mvcStereo = mvc
            DiagLog.log("MVC stereo pair \(mvc ? "detected → full side-by-side" : "gone")", "player")
            setStereo(requestedStereo, immersiveStereo: requestedImmersiveStereo)
        }
        guard layer.state == .readyToPlay || layer.state == .bufferFinished || layer.state == .buffering || layer.state == .paused else { return }
        applyCrop()
        tap.attach(to: me.audioOutput)
        if let engine = (me.audioOutput as? AudioEnginePlayer)?.engine {
            let f = engine.mainMixerNode.outputFormat(forBus: 0)
            if f.sampleRate > 0 {
                audioFormat = "\(Int(f.sampleRate) / 1000) kHz · \(f.channelCount) ch"
            }
        }
        // "Installed" means the mixer tap really exists; the level proves samples flow through it.
        let s = extractor.stats()
        tapInstalled = tap.tapInstalled
        bassLevelDb = s.bassPeakDb
        if Date().timeIntervalSince(lastBassLog) > 10 {
            lastBassLog = Date()
            DiagLog.log(String(format: "tap %@: %d buffers, %d frames, %d packets · input peak %.0f dB · bass peak %.0f dB · BLE %@ sent %d dropped %d",
                               tap.tapInstalled ? "on" : "off", s.buffers, s.frames, s.packets, s.inputPeakDb, s.bassPeakDb,
                               bassLink.state.rawValue, bassLink.packetsSent, bassLink.packetsDropped), "bass")
        }
    }
}

/// Player view for one item. Playback itself belongs to `LibraryStore.playback` so it survives
/// this view (the cinema screen dismisses the player window while the film keeps going).
struct FFmpegPlayerView: View {
    let item: MediaItem
    let url: URL
    var onFinished: (() -> Void)? = nil

    @EnvironmentObject private var bassLink: BassLink
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("bass.leadMs") private var leadMs: Int = 0
    #if os(visionOS)
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    #endif

    private var playback: PlaybackController { library.playback }

    private var immersiveStereoActive: Bool {
        #if os(visionOS)
        return immersive.isOpen && (library.effectiveStereo(for: item).isPacked || playback.session?.mvcStereo == true)
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if let session = playback.session, playback.item?.id == item.id {
                playerView(session: session)
            } else {
                Color.black
            }
        }
        #if os(visionOS)
        .background(WindowSceneProbe { scene in if let scene { playback.windowScene = scene } })
        #endif
        .onAppear {
            if bassLink.state == .off { bassLink.start() }
            let session = playback.begin(item: item, url: url, library: library, leadMs: leadMs)
            session.setStereo(library.effectiveStereo(for: item), immersiveStereo: immersiveStereoActive)
            ImmersiveScreenBridge.shared.projection = library.effectiveProjection(for: item)
            if item.source == .youtube {
                Task { session.setSponsorSegments(await library.youtube.sponsorSegments(for: item)) }
            }
            ImmersiveScreenBridge.shared.avPlayer = nil
        }
        .onDisappear {
            if playback.detachedForImmersive {
                DiagLog.log("player window dismissed for the cinema screen; playback continues", "player")
                return
            }
            playback.end()
            ImmersiveScreenBridge.shared.stereoFormat = .mono
            ImmersiveScreenBridge.shared.projection = .flat
            #if os(visionOS)
            // The window was closed while the cinema screen was up: take the screen down too.
            if immersive.isOpen { immersive.closeRequest += 1 }
            #endif
        }
        .onChange(of: leadMs) { _, new in playback.session?.setLead(ms: new) }
        .onChange(of: library.effectiveStereo(for: item)) { _, new in playback.session?.setStereo(new, immersiveStereo: immersiveStereoActive) }
        .onChange(of: immersiveStereoActive) { _, _ in playback.session?.setStereo(library.effectiveStereo(for: item), immersiveStereo: immersiveStereoActive) }
        .onChange(of: library.effectiveProjection(for: item)) { _, new in ImmersiveScreenBridge.shared.projection = new }
        .onChange(of: playback.session?.finished ?? false) { _, done in if done { onFinished?() } }
    }

    @ViewBuilder
    private func playerView(session: FFmpegSession) -> some View {
        #if os(visionOS)
        FFmpegPlayerChrome(item: item, url: url, playback: playback, session: session)
        #else
        KSVideoPlayerView(coordinator: playback.coordinator, url: url, options: session.options, title: item.title,
                          subtitleDataSouce: item.subtitleURLs.isEmpty ? nil : URLSubtitleDataSouce(urls: item.subtitleURLs))
            .overlay(alignment: .topTrailing) { statusChip(session).padding(12) }
        #endif
    }

    private func statusChip(_ session: FFmpegSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.tapInstalled ? "waveform" : "waveform.slash")
            Text(session.tapInstalled ? "Bass tap · \(session.audioFormat) · \(session.bassLevelDb <= -119 ? "silent" : String(format: "%.0f dB", session.bassLevelDb))" : "Bass tap off")
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statusChip")
    }
}

/// Lets the immersive screen (visionOS) receive frames from whichever player is active.
/// Kept platform-neutral so the shared player code compiles on tvOS too.
final class ImmersiveScreenBridge {
    static let shared = ImmersiveScreenBridge()
    /// Set by the cinema screen while it is open: (decoded frame, presentation time,
    /// Dolby-Vision-mapped texture if the frame needed mapping).
    var pushFrame: ((PixelBufferProtocol, CMTime, MTLTexture?) -> Void)?
    /// Packing of the current film; the screen splits packed frames into two eyes.
    var stereoFormat: StereoFormat = .mono
    /// Flat screen or VR sphere.
    var projection: ScreenProjection = .flat
    /// Set when the AVPlayer backend is active (MV-HEVC): the screen then uses RealityKit's own
    /// video component, which renders stereo natively.
    var avPlayer: AVPlayer?
}

#if os(visionOS)
/// Reports the UIKit window scene a SwiftUI view ends up in (nil when it leaves a window).
struct WindowSceneProbe: UIViewRepresentable {
    var onChange: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.isUserInteractionEnabled = false
        v.onChange = onChange
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) { v.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onChange?(window?.windowScene)
        }
    }
}
#endif
