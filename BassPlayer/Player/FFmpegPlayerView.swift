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
        KSOptions.preferredForwardBufferDuration = 1.0
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
    // Set on the main thread; `customizeDar` is called on the main thread by the display-link
    // loop and on the frame pump's queue in timestamped mode, hence the lock.
    private let lock = NSLock()
    private var _stereo: StereoFormat = .mono
    private var _cropToOneEye = false

    /// Stereo packing of the current file, and whether the flat view should crop to one eye.
    var stereo: StereoFormat {
        get { lock.withLock { _stereo } }
        set { lock.withLock { _stereo = newValue } }
    }

    var cropToOneEye: Bool {
        get { lock.withLock { _cropToOneEye } }
        set { lock.withLock { _cropToOneEye = newValue } }
    }

    override func customizeDar(sar: CGSize, par: CGSize) -> CGSize? {
        let (stereo, crop) = lock.withLock { (_stereo, _cropToOneEye) }
        guard crop, stereo.isPacked, par.width > 0, par.height > 0 else { return nil }
        let aspect = stereo.displayAspect(frameWidth: Double(par.width), frameHeight: Double(par.height))
        return CGSize(width: aspect * 1000, height: 1000)
    }
}

/// Owns the bass pipeline for one FFmpeg playback and exposes decoded frames for the immersive screen.
/// Measures how long the main thread takes to get round to a queued block: a timer on another
/// thread queues one every 20 ms and the block notes how late it ran. Tells "the main thread
/// was busy" apart from "the display link was not fired" when frames go missing.
final class MainThreadProbe: @unchecked Sendable {
    private var timer: DispatchSourceTimer?      // main thread only
    private var worst = 0.0                      // main thread only, as are the two below
    private var over50 = 0
    private var total = 0

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            let queued = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard let self else { return }
                let waited = CACurrentMediaTime() - queued
                self.total += 1
                if waited > self.worst { self.worst = waited }
                if waited > 0.05 { self.over50 += 1 }
            }
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func take() -> (worst: Double, over50: Int, total: Int) {
        defer { worst = 0; over50 = 0; total = 0 }
        return (worst, over50, total)
    }
}

/// The sub-bass level shown in the player's status line (see `FFmpegSession.bassMeter`).
@MainActor
final class BassMeter: ObservableObject {
    /// dBFS, whole decibels; -120 = silence.
    @Published private(set) var levelDb: Float = -120

    func set(_ db: Float) {
        let rounded = db.rounded()
        if rounded != levelDb { levelDb = rounded }
    }
}

/// "Bass tap · 48 kHz · 2 ch · -12 dB", or "Bass tap off".
struct BassTapLabel: View {
    let installed: Bool
    let audioFormat: String
    @ObservedObject var meter: BassMeter

    var body: some View {
        Text(installed ? "Bass tap · \(audioFormat) · \(meter.levelDb <= -119 ? "silent" : String(format: "%.0f dB", meter.levelDb))" : "Bass tap off")
    }
}

@MainActor
final class FFmpegSession: ObservableObject {
    let options = FFmpegConfig.makeOptions()
    let extractor = BassExtractor()
    let tap: BassEngineTap
    @Published private(set) var tapInstalled = false
    @Published private(set) var backendName = "—"
    @Published private(set) var audioFormat = "—"
    /// Peak of the extracted sub-bass over the last poll interval. It changes on almost every
    /// poll, so it is published by its own object: only `BassTapLabel` redraws, not every view
    /// that observes the session (which redrew the whole player twice a second and cost the
    /// render loop a display tick each time; see `logRenderStats`).
    let bassMeter = BassMeter()
    private var lastBassLog: Date = .distantPast
    private var lastRenderLog = Date()
    private var lastDroppedFrames: UInt32 = 0
    private var pollWorst = 0.0
    private var pollTotal = 0.0
    private var pollCount = 0
    private let mainProbe = MainThreadProbe()

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

    /// What the frame-pacing choice came to, as last logged ("timestamped", "display link …").
    private var pacingDescription = ""
    /// Mode, frames handed over and the last `render:` line, for the simulator tests' probe.
    private(set) var pacingProbe = "mode=- handed=0 render=-"
    private var lastRenderLine = "-"
    private var stallFrameCount = -1
    private var stallSince = Date()
    private var stallPosition = 0.0
    private var stallRecoveries: [Date] = []
    private var stallGiveUpLogged = Date.distantPast
    private weak var sinkView: MetalPlayView?

    /// Mirror every rendered frame to the immersive screen while it is open. Dolby Vision
    /// profile 5 frames are colour-mapped first (the system renderer can't interpret IPT).
    /// Only the display-link loop calls the sink, so `applyFramePacing` keeps the player in
    /// that mode while the screen is open.
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

    /// Ask the player for the frame-presentation mode chosen in Settings → Diagnostics, and log
    /// what it came to whenever that changes. Called at every poll and when the cinema screen
    /// opens or closes, so the switch also works on a film that is playing.
    private func applyFramePacing() {
        guard let view = (coordinator?.playerLayer?.player as? KSMEPlayer)?.videoOutput as? MetalPlayView else { return }
        // The cinema screen is fed through the frame sink, which timestamped mode bypasses.
        let cinemaOpen = ImmersiveScreenBridge.shared.pushFrame != nil
        let wanted = FramePacing.wantsTimestamped
        let request: MetalPlayView.PresentationMode = wanted && !cinemaOpen ? .timestamped : .displayLink
        if view.requestedPresentationMode != request { view.requestedPresentationMode = request }
        let description: String
        if view.activePresentationMode == .timestamped {
            description = "timestamped"
        } else if wanted, cinemaOpen {
            description = "display link (timestamped is on, but the cinema screen takes its frames from the display-link loop)"
        } else if wanted, let reason = view.presentationFallbackReason {
            description = "display link (timestamped is on, but \(reason))"
        } else if wanted {
            description = "display link (timestamped is on and starting)"
        } else {
            description = "display link"
        }
        if description != pacingDescription {
            pacingDescription = description
            DiagLog.log("frame pacing: \(description)", "player")
        }
        pacingProbe = "mode=\(view.activePresentationMode.rawValue) handed=\(view.framesHandedOver) render=\(lastRenderLine)"
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
            // googlevideo closes the connection after every segment; FFmpeg's keep-alive reuse
            // then fails and is retried ("keepalive request failed"), one wasted round trip per
            // segment and per seek.
            options.formatContextOptions["http_persistent"] = 0
            // A connection reset in the middle of a segment (2026-11-10 and 2026-11-20). FFmpeg's
            // HLS demuxer treats any read error as the end of the segment and moves on, so the
            // fMP4 parser is fed a cut-off fragment followed by the next segment: a burst of VP9
            // header errors, then no video frames at all while the audio (its own connection)
            // plays on. The `reconnect*` format options set here before never reached the
            // segment connections (HLS passes them a fixed list of options), so they did nothing.
            // Two layers now: FFmpeg resumes the cut-off download itself where the server allows
            // it, and `watchForVideoStall` reopens the stream if the picture stops anyway.
            options.reconnectNestedHTTP = true
            // A segment that fails to *open* is retried instead of skipped (5 s of film).
            options.formatContextOptions["seg_max_retry"] = 2
            options.seekSnap = nil
            if let master = item.directURL, master.isFileURL {
                Task { await learnSegments(master: master, userAgent: item.userAgent) }
            }
        }
    }

    /// FFmpeg's HLS demuxer seeks by reading the segment that contains the target and
    /// discarding everything up to the first keyframe at or after it — on YouTube that keyframe
    /// is the start of the *next* segment, so a seek fetched ~1.5 segments before the first
    /// frame (2.5–3 s). Seeking to the segment start instead makes the first packet usable.
    /// Read the media playlist once to know the boundaries (EXTINF durations are not constant).
    private func learnSegments(master: URL, userAgent: String?) async {
        guard let text = try? String(contentsOf: master, encoding: .utf8) else { return }
        var mediaURL: URL?
        var afterInf = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") { afterInf = true; continue }
            if afterInf, !line.isEmpty, !line.hasPrefix("#") { mediaURL = URL(string: line); break }
        }
        guard let mediaURL, mediaURL.scheme?.hasPrefix("http") == true else { return }
        var req = URLRequest(url: mediaURL, timeoutInterval: 15)
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let playlist = String(data: data, encoding: .utf8) else {
            DiagLog.log("media playlist not readable; seeks stay unsnapped", "youtube"); return
        }
        var starts: [Double] = [0]
        var t = 0.0
        var durations: [Double] = []
        for raw in playlist.components(separatedBy: .newlines) where raw.hasPrefix("#EXTINF:") {
            let num = raw.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
            if let d = Double(num), d > 0 { durations.append(d); t += d; starts.append(t) }
        }
        // Diagnostic (2026-11-21): the shape of YouTube's media playlist, for reproducing seek
        // problems off the headset. Tags only; segment addresses are reduced to their path keys.
        let lines = playlist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let byteRanges = lines.filter { $0.hasPrefix("#EXT-X-BYTERANGE") }.count
        let head = lines.prefix(14).map { $0.hasPrefix("#") ? String($0.prefix(100)) : "<uri \($0.count) chars>" }.joined(separator: " ¦ ")
        var shape = "?"
        if let uri = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }), let url = URL(string: uri) {
            let parts = url.path.split(separator: "/").map(String.init)
            shape = (url.host ?? "?") + " /" + stride(from: 0, to: parts.count, by: 2).map { parts[$0] }.prefix(40).joined(separator: "/") + (url.query == nil ? "" : " ?query")
        }
        DiagLog.log("media playlist shape: \(lines.count) lines, \(byteRanges) byte ranges ¦ \(head)", "youtube")
        DiagLog.log("media playlist segment address keys: \(shape); first durations \(durations.prefix(6).map { String(format: "%.3f", $0) }.joined(separator: " "))", "youtube")
        guard durations.count > 1 else { return }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        DiagLog.log(String(format: "media playlist: %d segments, median %.2f s, total %.0f s → seeks snap to segment starts", durations.count, median, t), "youtube")
        options.seekSnap = { want in
            // Largest segment start <= want (binary search); earlier rather than later so the
            // user never lands past what they aimed at.
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= want { lo = mid } else { hi = mid - 1 }
            }
            return starts[lo]
        }
    }

    func start(coordinator: KSVideoPlayer.Coordinator, leadMs: Int, item: MediaItem? = nil, library: LibraryStore? = nil) {
        self.coordinator = coordinator
        self.item = item
        self.library = library
        tap.leadMs = leadMs
        options.videoDelay = 0          // set from the lead actually applied, in poll()
        sponsorSkipper = SponsorSkipper()
        finished = false
        reportedStart = false
        sleepFired = false
        stallFrameCount = -1
        stallRecoveries = []
        mainProbe.start()
        lastRenderLog = Date()
        lastDroppedFrames = 0
        pacingDescription = ""
        _ = MainThreadStallTest.shared.takeCount()
        ImmersiveScreenBridge.shared.consumerChanged = { [weak self] in
            MainActor.assumeIsolated { self?.applyFramePacing() }
        }
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
            Task { @MainActor in
                guard let self else { return }
                self.poll()
                // After the poll, so the poll's own timing in the `render:` line stays honest.
                MainThreadStallTest.shared.stallIfDue(playing: self.coordinator?.playerLayer?.state == .bufferFinished)
            }
        }
    }

    func setLead(ms: Int) {
        tap.leadMs = ms
        syncVideoDelay()
    }

    /// The picture waits exactly as long as the headset's audio is held back.
    private func syncVideoDelay() {
        let lead = tap.effectiveLeadSeconds
        if options.videoDelay != lead { options.videoDelay = lead }
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
        mainProbe.stop()
        ImmersiveScreenBridge.shared.consumerChanged = nil
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

    /// YouTube only. The picture can stop for good while the sound carries on (see
    /// `configure`): no frame reaches the renderer although the player says it is playing and
    /// its clock keeps moving. A seek does not bring it back (tried on the headset 2026-11-20:
    /// three seeks, state went buffering → playing each time, still no frame), so the stream is
    /// opened again from scratch at the start of the current segment: a new demuxer and
    /// decoders in the same player. The film steps back a few seconds at most.
    private func watchForVideoStall(layer: KSPlayerLayer, player: KSMEPlayer) {
        guard item?.source == .youtube else { return }
        let now = Date()
        // Frames handed to the renderer, by the display-link loop or by the timestamped pump.
        let frames = sinkView?.framesHandedOver ?? 0
        let position = player.currentPlaybackTime
        guard layer.state == .bufferFinished, sinkView != nil, position.isFinite,
              UIApplication.shared.applicationState == .active,
              frames == stallFrameCount, position >= stallPosition else {
            // Not playing, not on screen (nothing is drawn then), frames are arriving, or the
            // position jumped back: start over.
            stallFrameCount = frames
            stallSince = now
            stallPosition = position.isFinite ? position : 0
            return
        }
        let frozenFor = now.timeIntervalSince(stallSince)
        guard frozenFor >= 3, position - stallPosition >= 2 else { return }
        stallRecoveries.removeAll { now.timeIntervalSince($0) > 120 }
        guard stallRecoveries.count < 3 else {
            if now.timeIntervalSince(stallGiveUpLogged) > 60 {
                stallGiveUpLogged = now
                DiagLog.log(String(format: "video stalled again at %.1f s; three recoveries in two minutes did not hold, leaving it alone for now", position), "player")
            }
            return
        }
        stallRecoveries.append(now)
        let restart = max(0, options.seekSnap?(position) ?? position)
        DiagLog.log(String(format: "video stalled at %.1f s: no frame for %.1f s while the clock moved %.1f s; opening the stream again at %.1f s (recovery %d)",
                           position, frozenFor, position - stallPosition, restart, stallRecoveries.count), "player")
        stallSince = now
        stallPosition = position
        options.startPlayTime = restart
        layer.reopen()
    }

    /// Every 10 s while playing, one `render:` line that starts with the presentation mode.
    ///
    /// Display link: how often the link really fired, the longest gap between ticks, frames
    /// shown and dropped. A 60 fps video needs at least 60 ticks a second with no gap much
    /// over 17 ms; anything less shows as judder however fast the decoder is.
    ///
    /// Timestamped: frames enqueued and how far ahead, what the pump dropped itself, what the
    /// system says it displayed and dropped (`AVVideoPerformanceMetrics`), the renderer's
    /// state and how the timebase followed the audio clock.
    ///
    /// Both end with the main-thread probe, this poll's cost and the stall test's count.
    private func logRenderStats(layer: KSPlayerLayer, player: KSMEPlayer) {
        let now = Date()
        guard now.timeIntervalSince(lastRenderLog) >= 10, let view = player.videoOutput as? MetalPlayView else { return }
        lastRenderLog = now
        let r = view.takeRenderStats()
        let dropped = player.dynamicInfo?.droppedVideoFrameCount ?? 0
        let newDrops = dropped >= lastDroppedFrames ? dropped - lastDroppedFrames : dropped
        lastDroppedFrames = dropped
        let worst = pollWorst
        pollWorst = 0; pollTotal = 0; pollCount = 0
        let main = mainProbe.take()
        let stalls = MainThreadStallTest.shared.takeCount()
        var tail = String(format: "main thread: worst wait %.0f ms, %d of %d probes over 50 ms · poll worst %.1f ms",
                          main.worst * 1000, main.over50, main.total, worst * 1000)
        if MainThreadStallTest.shared.isOn || stalls > 0 {
            tail += " · stall test: \(stalls) × \(MainThreadStallTest.stallMilliseconds) ms"
        }
        guard layer.state == .bufferFinished else { return }
        if view.activePresentationMode == .timestamped {
            view.takeTimestampedStats { [weak self] t in
                // Less than a second of running is the still shown before playback starts.
                guard let t, t.span >= 1 else { return }
                let system: String
                if let frames = t.systemFrames, let systemDropped = t.systemDropped {
                    system = String(format: "system: %d frames, %d dropped, %d corrupted, frame delay %+.1f ms",
                                    frames, systemDropped, t.systemCorrupted ?? 0, (t.systemFrameDelay ?? 0) * 1000)
                } else {
                    system = "system: no metrics"
                }
                let clock = t.followsAudio
                    ? String(format: "clock: audio, %d readings, error mean %+.1f ms, worst %+.1f ms, %d trims up to %.2f %%, %d resyncs",
                             t.clockSamples, t.clockErrorMean * 1000, t.clockErrorWorst * 1000, t.trims, t.maxTrim * 100, t.resyncs)
                    : "clock: free-running (no audio to follow)"
                let line = String(format: "render: mode timestamped · %d enqueued in %.1f s (%.1f/s) · lookahead %.0f–%.0f ms · pump: %d late dropped, %d late kept, %d out of order, %d unwrappable, not ready %d, longest gap %.0f ms · %@ · renderer %@%@, %d flushes, %d timeline resets · %@ · rate %.3f · ",
                                  t.enqueued, t.span, Double(t.enqueued) / t.span, t.lookaheadMin * 1000, t.lookaheadMax * 1000,
                                  t.lateDropped, t.lateKept, t.outOfOrder, t.unwrappable, t.notReady, t.longestPumpGap * 1000,
                                  system, t.rendererStatus, t.rendererError.map { " (\($0))" } ?? "", t.rendererFlushes, t.timelineResets,
                                  clock, t.timebaseRate) + tail
                self?.lastRenderLine = line
                DiagLog.log(line, "player")
            }
            return
        }
        guard r.ticks > 1, r.span > 0 else { return }
        let line = String(format: "render: mode display-link · %d ticks in %.1f s (%.1f/s, link %.0f Hz) · %d gaps over 25 ms, longest %.0f ms · longest draw %.1f ms · %d frames shown · %d dropped · sync %+.0f ms · ",
                          r.ticks, r.span, Double(r.ticks - 1) / r.span, r.linkInterval > 0 ? 1 / r.linkInterval : 0,
                          r.lateTicks, r.longestGap * 1000, r.longestDraw * 1000, r.presented, Int(newDrops),
                          (player.dynamicInfo?.audioVideoSyncDiff ?? 0) * 1000) + tail
        lastRenderLine = line
        DiagLog.log(line, "player")
    }

    private func poll() {
        guard let layer = coordinator?.playerLayer else { return }
        let player = layer.player
        let pollStart = CACurrentMediaTime()
        defer {
            let took = CACurrentMediaTime() - pollStart
            pollWorst = max(pollWorst, took)
            pollTotal += took
            pollCount += 1
        }
        // Publish only what changed: every assignment to a @Published property redraws the
        // views observing the session, changed or not.
        let backend = player is KSMEPlayer ? "FFmpeg" : "AVPlayer"
        if backendName != backend { backendName = backend }
        trackProgress(layer: layer)
        // SponsorBlock: jump over marked segments.
        if !sponsorSkipper.segments.isEmpty, layer.state == .bufferFinished || layer.state == .readyToPlay,
           let target = sponsorSkipper.skipTarget(at: player.currentPlaybackTime) {
            sponsorSkips += 1
            let snap = options.seekSnap
            options.seekSnap = nil          // snapping down would re-enter the sponsor segment
            layer.seek(time: target, autoPlay: true) { _ in }
            options.seekSnap = snap
        }
        guard let me = player as? KSMEPlayer else { return }
        if let view = me.videoOutput as? MetalPlayView { installFrameSink(on: view) }
        applyFramePacing()
        watchForVideoStall(layer: layer, player: me)
        logRenderStats(layer: layer, player: me)
        let mvc = me.tracks(mediaType: .video).contains { ($0 as? FFmpegAssetTrack)?.decodesStereoSideBySide == true }
        if mvc != mvcStereo {
            mvcStereo = mvc
            DiagLog.log("MVC stereo pair \(mvc ? "detected → full side-by-side" : "gone")", "player")
            setStereo(requestedStereo, immersiveStereo: requestedImmersiveStereo)
        }
        guard layer.state == .readyToPlay || layer.state == .bufferFinished || layer.state == .buffering || layer.state == .paused else { return }
        applyCrop()
        tap.attach(to: me.audioOutput)
        syncVideoDelay()
        if let engine = (me.audioOutput as? AudioEnginePlayer)?.engine {
            let f = engine.mainMixerNode.outputFormat(forBus: 0)
            if f.sampleRate > 0 {
                let format = "\(Int(f.sampleRate) / 1000) kHz · \(f.channelCount) ch"
                if audioFormat != format { audioFormat = format }
            }
        }
        // "Installed" means the mixer tap really exists; the level proves samples flow through it.
        let s = extractor.stats()
        if tapInstalled != tap.tapInstalled { tapInstalled = tap.tapInstalled }
        bassMeter.set(s.bassPeakDb)
        if Date().timeIntervalSince(lastBassLog) > 10 {
            lastBassLog = Date()
            DiagLog.log(String(format: "tap %@: %d buffers, %d frames, %d packets · input peak %.0f dB · bass peak %.0f dB · BLE %@ sent %d dropped %d queue peak %d · receiver buffer %d underruns %d dropped %d",
                               tap.tapInstalled ? "on" : "off", s.buffers, s.frames, s.packets, s.inputPeakDb, s.bassPeakDb,
                               bassLink.state.rawValue, bassLink.packetsSent, bassLink.packetsDropped, bassLink.sendQueuePeak,
                               bassLink.receiverBufferFill, bassLink.receiverUnderruns, bassLink.receiverDropped), "bass")
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
            BassTapLabel(installed: session.tapInstalled, audioFormat: session.audioFormat, meter: session.bassMeter)
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
    var pushFrame: ((PixelBufferProtocol, CMTime, MTLTexture?) -> Void)? {
        didSet {
            if (pushFrame == nil) != (oldValue == nil) { consumerChanged?() }
        }
    }

    /// Called on the main thread when the cinema screen starts or stops taking frames: the
    /// player must be in display-link mode while it does (see `FFmpegSession.applyFramePacing`).
    var consumerChanged: (() -> Void)?
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
