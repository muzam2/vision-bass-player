import SwiftUI
import AVFoundation
import KSPlayer

/// Global KSPlayer configuration. Called once from the App init.
enum FFmpegConfig {
    static func apply() {
        KSOptions.firstPlayerType = KSMEPlayer.self          // FFmpeg first: MKV, DTS, TrueHD, FLAC, AV1…
        KSOptions.secondPlayerType = KSAVPlayer.self         // fall back to AVPlayer if FFmpeg can't open it
        KSOptions.audioPlayerType = AudioEnginePlayer.self   // we tap its AVAudioEngine for the bass
        KSOptions.hardwareDecode = true                      // VideoToolbox for H.264/HEVC/AV1/ProRes
        KSOptions.isAutoPlay = true
        KSOptions.isSecondOpen = true
        KSOptions.preferredForwardBufferDuration = 4
        KSOptions.maxBufferDuration = 60
        KSOptions.logLevel = .warning
    }

    /// Per-item options. HDR10 / HLG / Dolby Vision are passed through to the display
    /// (`destinationDynamicRange = nil` lets KSPlayer pick the best mode the screen supports).
    static func makeOptions() -> KSOptions {
        let o = KSOptions()
        o.destinationDynamicRange = nil
        o.autoDeInterlace = true
        o.autoSelectEmbedSubtitle = true
        o.userAgent = "BassPlayer/0.2"
        o.videoAdaptable = false
        return o
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

    /// Current decoded frame (for the RealityKit screen). Nil when nothing is playing.
    var currentPixelBuffer: CVPixelBuffer? {
        guard let me = coordinator?.playerLayer?.player as? KSMEPlayer else { return nil }
        return me.videoOutput?.pixelBuffer?.cvPixelBuffer
    }

    init(bassLink: BassLink) {
        self.bassLink = bassLink
        tap = BassEngineTap(extractor: extractor)
        extractor.onPacket = { [weak bassLink] packet in bassLink?.send(packet) }
    }

    func start(coordinator: KSVideoPlayer.Coordinator, leadMs: Int) {
        self.coordinator = coordinator
        tap.leadMs = leadMs
        options.videoDelay = Double(leadMs) / 1000
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

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tap.detach()
        tapInstalled = false
    }

    private func poll() {
        guard let layer = coordinator?.playerLayer else { return }
        let player = layer.player
        backendName = player is KSMEPlayer ? "FFmpeg" : "AVPlayer"
        guard let me = player as? KSMEPlayer else { return }
        guard layer.state == .readyToPlay || layer.state == .bufferFinished || layer.state == .buffering || layer.state == .paused else { return }
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

    @EnvironmentObject private var bassLink: BassLink
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    @StateObject private var session: FFmpegSession
    @AppStorage("bass.leadMs") private var leadMs: Int = 0

    init(item: MediaItem, url: URL) {
        self.item = item
        self.url = url
        _session = StateObject(wrappedValue: FFmpegSession(bassLink: BassLinkHolder.shared))
    }

    var body: some View {
        KSVideoPlayerView(coordinator: coordinator, url: url, options: session.options, title: item.title)
            .overlay(alignment: .topTrailing) { statusChip.padding(12) }
            .onAppear {
                if bassLink.state == .off { bassLink.start() }
                session.start(coordinator: coordinator, leadMs: leadMs)
                ImmersiveScreenBridge.shared.frameSource = { [weak session] in session?.currentPixelBuffer }
            }
            .onDisappear {
                session.stop()
                ImmersiveScreenBridge.shared.frameSource = nil
            }
            .onChange(of: leadMs) { _, new in session.setLead(ms: new) }
    }

    private var statusChip: some View {
        HStack(spacing: 8) {
            Image(systemName: session.tapInstalled ? "waveform" : "waveform.slash")
            Text(session.tapInstalled ? "Bass tap · \(session.audioFormat)" : "Bass tap off")
            Text("·")
            Text(session.backendName)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .foregroundStyle(session.tapInstalled ? .green : .secondary)
        .allowsHitTesting(false)
    }
}

/// Lets the immersive screen (visionOS) pull frames from whichever player is active.
/// Kept platform-neutral so the shared player code compiles on tvOS too.
final class ImmersiveScreenBridge {
    static let shared = ImmersiveScreenBridge()
    /// Returns the latest decoded frame, or nil.
    var frameSource: (() -> CVPixelBuffer?)?
}
