//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: KSOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    init(options: KSOptions)
    func invalidate()
    func readNextFrame()
}

/// Bass Player patch: the part of `MetalPlayView`'s state that is not confined to the main
/// thread. The display-link loop writes it on the main thread; in timestamped mode the frame
/// pump writes it on its queue; the player reads and writes parts of it from wherever it is.
final class MetalPlayViewShared: @unchecked Sendable {
    private let lock = UnfairLock()
    private var _currentFrame: VideoVTBFrame?
    private var _pixelBuffer: PixelBufferProtocol?
    private var _framesHandedOver = 0
    private var _playbackRate = Float(1)
    private var _timestampedActive = false
    private var _presenter: AnyObject?

    var currentFrame: VideoVTBFrame? {
        lock.withLock { _currentFrame }
    }

    var pixelBuffer: PixelBufferProtocol? {
        get { lock.withLock { _pixelBuffer } }
        set { lock.withLock { _pixelBuffer = newValue } }
    }

    var framesHandedOver: Int {
        lock.withLock { _framesHandedOver }
    }

    var playbackRate: Float {
        get { lock.withLock { _playbackRate } }
        set { lock.withLock { _playbackRate = newValue } }
    }

    var timestampedActive: Bool {
        get { lock.withLock { _timestampedActive } }
        set { lock.withLock { _timestampedActive = newValue } }
    }

    /// The presenter, typed loosely because its class needs a newer OS than the package's
    /// minimum. Set once, on the main thread, the first time timestamped mode is entered.
    var presenter: TimestampedPresenting? {
        lock.withLock { _presenter } as? TimestampedPresenting
    }

    func setPresenter(_ presenter: AnyObject) {
        lock.withLock { _presenter = presenter }
    }

    /// A frame went to the renderer.
    func noteFrame(_ frame: VideoVTBFrame, pixelBuffer: PixelBufferProtocol?) {
        lock.withLock {
            _currentFrame = frame
            if let pixelBuffer {
                _pixelBuffer = pixelBuffer
            }
            _framesHandedOver &+= 1
        }
    }
}

public final class MetalPlayView: UIView, VideoOutput {
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    /// Bass Player patch: see `MetalPlayViewShared`.
    private nonisolated let shared = MetalPlayViewShared()
    /// Last frame handed to the renderer (lets hosts read per-frame Dolby Vision metadata).
    public var currentFrame: VideoVTBFrame? {
        shared.currentFrame
    }

    /// Bass Player patch: frames handed to the renderer since the view was created, in either
    /// presentation mode.
    public var framesHandedOver: Int {
        shared.framesHandedOver
    }

    /// Bass Player patch: called on the main thread with every frame handed to the renderer
    /// (hardware CVPixelBuffer or software planes), so a second consumer — the immersive
    /// cinema screen — can display the same frames. Display-link mode only: in timestamped
    /// mode frames are handed over ahead of their display time on another queue, so a
    /// consumer that needs them must keep the view in display-link mode.
    public var frameSink: ((VideoVTBFrame, PixelBufferProtocol, CMTime) -> Void)?
    /// Bass Player patch: what the display link did since the last `takeRenderStats()`. Tells a
    /// starved render loop (few ticks, long gaps between them) apart from frames that were
    /// simply late: the loop runs on the main thread and shows at most one frame per tick.
    public struct RenderStats {
        public var ticks = 0
        /// Frames handed to the renderer.
        public var presented = 0
        /// Seconds between the first and the last tick.
        public var span = 0.0
        public var longestGap = 0.0
        /// Ticks that arrived more than 25 ms after the previous one (two refreshes at 90 Hz).
        public var lateTicks = 0
        /// Longest single tick, i.e. time spent choosing and handing over a frame.
        public var longestDraw = 0.0
        /// Seconds per refresh as the display link reports it (0 where not available).
        public var linkInterval = 0.0
    }

    private var renderStats = RenderStats()
    private var firstTickTime = 0.0
    private var lastTickTime = 0.0
    public func takeRenderStats() -> RenderStats {
        var stats = renderStats
        stats.span = lastTickTime - firstTickTime
        renderStats = RenderStats()
        firstTickTime = lastTickTime
        return stats
    }
    /// Visible portion of the frame (unit rect, origin top-left). Used to show one eye of a
    /// side-by-side / top-bottom 3D frame on a flat display. Pair with `KSOptions.customizeDar`.
    public var contentsCrop = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            guard contentsCrop != oldValue else { return }
            displayView.displayLayer.contentsRect = contentsCrop
            metalView.metalLayer.contentsRect = contentsCrop
        }
    }
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                if KSOptions.preferredFrame {
                    let preferredFramesPerSecond = ceil(fps)
                    if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
                        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: preferredFramesPerSecond, maximum: 2 * preferredFramesPerSecond, __preferred: preferredFramesPerSecond)
                    } else {
                        displayLink.preferredFramesPerSecond = Int(preferredFramesPerSecond) << 1
                    }
                } else {
                    #if os(xrOS)
                    // Bass Player patch: let the link run at the panel's own rate and pick frames
                    // by clock (videoClockSync returns .remain when the next frame is not due).
                    // For film rates ask for a 4x multiple (96 Hz for 24p) in case the panel
                    // offers it; otherwise the native 90 Hz is still far better than 22.5.
                    let preferred = fps <= 31 ? ceil(fps) * 4 : (fps <= 61 ? ceil(fps) * 2 : ceil(fps))
                    displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, __preferred: preferred)
                    #endif
                }
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public private(set) var pixelBuffer: PixelBufferProtocol? {
        get { shared.pixelBuffer }
        set { shared.pixelBuffer = newValue }
    }

    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: KSOptions {
        didSet {
            // Bass Player patch: a reopened or replaced item gets a fresh decision.
            presentationFallbackReason = nil
            reconcilePresentationMode()
            shared.presenter?.setSource(renderSource, options: options)
        }
    }

    public weak var renderSource: OutputRenderSourceDelegate? {
        didSet {
            // Bass Player patch: the pump keeps its own reference (it runs off the main thread).
            shared.presenter?.setSource(renderSource, options: options)
        }
    }

    // MARK: Bass Player patch: timestamped presentation

    /// How frames reach the screen.
    public enum PresentationMode: String, Sendable {
        /// Upstream's loop: a display link on the main run loop picks at most one frame per
        /// tick and shows it at once.
        case displayLink = "display-link"
        /// A pump on its own queue hands frames to the display layer's renderer ahead of time
        /// with their media timestamps; a timebase that follows the audio clock decides when
        /// each one appears (`TimestampedVideoPresenter`).
        case timestamped
    }

    /// What the host asks for. Main thread. Takes effect at once, also during playback.
    /// Display link is the default and the fallback: timestamped mode only takes frames the
    /// display layer can show (see `presentationFallbackReason`).
    public var requestedPresentationMode = PresentationMode.displayLink {
        didSet {
            guard requestedPresentationMode != oldValue else { return }
            presentationFallbackReason = nil
            reconcilePresentationMode()
        }
    }

    /// The mode that is running. Main thread.
    public private(set) var activePresentationMode = PresentationMode.displayLink {
        didSet {
            shared.timestampedActive = activePresentationMode == .timestamped
        }
    }

    /// Why timestamped mode was asked for but is not running, for this item. Main thread.
    public private(set) var presentationFallbackReason: String?
    /// True while the display layer's control timebase is driven by the frame pump.
    public nonisolated var ownsControlTimebase: Bool {
        shared.timestampedActive
    }

    /// Playback rate of the player; the timestamped timebase runs at it.
    public nonisolated var playbackRate: Float {
        get { shared.playbackRate }
        set {
            shared.playbackRate = newValue
            shared.presenter?.setRate(Double(newValue))
        }
    }

    /// Whether the player wants frames to flow (`play()` / `pause()`). Main thread.
    private var wantsPlayback = false
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    public weak var displayLayerDelegate: DisplayLayerDelegate?
    public init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        metalView.isHidden = true
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        pause()
    }

    public func play() {
        wantsPlayback = true
        if activePresentationMode == .timestamped {
            shared.presenter?.setPlaying(true)
        } else {
            displayLink.isPaused = false
        }
    }

    public func pause() {
        wantsPlayback = false
        displayLink.isPaused = true
        shared.presenter?.setPlaying(false)
        // A pause is not a gap between ticks.
        lastTickTime = 0
        firstTickTime = 0
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override public func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #else
    override public func touchesMoved(with event: NSEvent) {
        if options.display == .plane {
            super.touchesMoved(with: event)
        } else {
            options.display.touchesMoved(touch: event.allTouches().first!)
        }
    }
    #endif

    public func flush() {
        pixelBuffer = nil
        if activePresentationMode == .timestamped {
            shared.presenter?.timelineJumped(removeImage: true)
            return
        }
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        displayLink.invalidate()
        shared.presenter?.detach()
    }

    public func readNextFrame() {
        if activePresentationMode == .timestamped {
            shared.presenter?.showStill()
            return
        }
        draw(force: true)
    }

//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    @objc private func renderFrame() {
        let now = CACurrentMediaTime()
        if lastTickTime > 0 {
            renderStats.longestGap = max(renderStats.longestGap, now - lastTickTime)
            if now - lastTickTime > 0.025 { renderStats.lateTicks += 1 }
        } else {
            firstTickTime = now
        }
        lastTickTime = now
        renderStats.ticks += 1
        #if !os(macOS)
        renderStats.linkInterval = displayLink.targetTimestamp - displayLink.timestamp
        #endif
        draw(force: false)
        renderStats.longestDraw = max(renderStats.longestDraw, CACurrentMediaTime() - now)
    }

    private func draw(force: Bool) {
        autoreleasepool {
            guard let frame = renderSource?.getVideoOutputRender(force: force) else {
                return
            }
            let pixelBuffer = frame.corePixelBuffer
            self.pixelBuffer = pixelBuffer
            guard let pixelBuffer else {
                return
            }
            isDovi = frame.isDovi
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            // Dolby Vision profile 5 must go through our Metal shader; the display layer can't map IPT.
            let dovi = frame.dovi?.needsMapping == true ? frame.dovi : nil
            shared.noteFrame(frame, pixelBuffer: nil)
            renderStats.presented += 1
            frameSink?(frame, pixelBuffer, cmtime)
            if dovi == nil, let pixelBuffer = pixelBuffer.cvPixelBuffer, options.isUseDisplayLayer() {
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                set(pixelBuffer: pixelBuffer, time: cmtime)
            } else {
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
                let size: CGSize
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = KSOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                #if !os(tvOS)
                if #available(iOS 16, *) {
                    metalView.metalLayer.edrMetadata = frame.edrMetadata
                }
                #endif
                metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size, dovi: dovi)
            }
            renderSource?.setVideo(time: cmtime, position: frame.position)
        }
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        if formatDescription == nil || !pixelBuffer.matche(formatDescription: formatDescription!) {
            if formatDescription != nil {
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.frame = frame
                displayView.displayLayer.contentsRect = contentsCrop
                addSubview(displayView)
            }
            formatDescription = pixelBuffer.formatDescription
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let formatDescription else { return }
        displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

// MARK: - Bass Player patch: timestamped presentation

public extension MetalPlayView {
    /// What the frame pump did since the last call, delivered on the main thread (nil when
    /// timestamped mode is not running). The system's own frame counts are fetched
    /// asynchronously, so the answer arrives a moment later. Main thread.
    func takeTimestampedStats(completion: @escaping (TimestampedPresentationStats?) -> Void) {
        if activePresentationMode == .timestamped, let presenter = shared.presenter {
            presenter.takeStats(completion: completion)
        } else {
            completion(nil)
        }
    }
}

extension MetalPlayView {
    /// A seek is starting: what was handed to the renderer ahead of time is stale. Any thread.
    nonisolated func timelineWillJump() {
        shared.presenter?.timelineJumped(removeImage: false)
    }

    /// Main thread. Decides which mode runs and hands the layer over.
    private func reconcilePresentationMode() {
        var want = requestedPresentationMode
        if want == .timestamped {
            if presentationFallbackReason != nil {
                want = .displayLink
            } else if !options.isUseDisplayLayer() {
                presentationFallbackReason = "the player is not using the display layer"
                want = .displayLink
            } else if !TimestampedPresentation.isAvailable {
                presentationFallbackReason = "it needs a newer OS"
                want = .displayLink
            }
        }
        guard want != activePresentationMode else { return }
        if want == .timestamped {
            if enterTimestampedMode() {
                activePresentationMode = .timestamped
            } else {
                presentationFallbackReason = "no timebase could be created"
            }
        } else {
            activePresentationMode = .displayLink
            leaveTimestampedMode()
        }
    }

    private func enterTimestampedMode() -> Bool {
        guard #available(iOS 17.4, tvOS 17.4, macOS 14.4, visionOS 1.1, *) else { return false }
        let presenter: TimestampedVideoPresenter
        if let existing = shared.presenter as? TimestampedVideoPresenter {
            presenter = existing
        } else {
            let sharedState = self.shared
            let created = TimestampedVideoPresenter(
                onFrame: { frame, pixelBuffer in
                    // Frame pump's queue.
                    sharedState.noteFrame(frame, pixelBuffer: pixelBuffer)
                },
                onFormat: { [weak self] fps, isDovi, formatDescription in
                    // Frame pump's queue. Display-mode matching is main-thread work and not
                    // urgent.
                    Task { @MainActor [weak self] in
                        guard let self, self.activePresentationMode == .timestamped else { return }
                        self.isDovi = isDovi
                        self.fps = fps
                        self.formatDescription = formatDescription
                    }
                },
                onIneligible: { [weak self] reason in
                    // Frame pump's queue: it met a frame the display layer cannot take and left
                    // it in the queue for the display-link loop.
                    Task { @MainActor [weak self] in
                        guard let self, self.activePresentationMode == .timestamped else { return }
                        self.presentationFallbackReason = reason
                        self.reconcilePresentationMode()
                    }
                }
            )
            guard let created else { return false }
            shared.setPresenter(created)
            presenter = created
        }
        displayLink.isPaused = true
        lastTickTime = 0
        firstTickTime = 0
        if displayView.isHidden {
            displayView.isHidden = false
            metalView.isHidden = true
            metalView.clear()
        }
        displayView.displayLayer.controlTimebase = presenter.timebase
        presenter.attach(renderer: displayView.displayLayer.sampleBufferRenderer, source: renderSource, options: options,
                         rate: Double(shared.playbackRate), playing: wantsPlayback)
        return true
    }

    private func leaveTimestampedMode() {
        // Waits for the pump's queue: after this line the pump no longer touches the renderer,
        // and the display-link loop is the only user of the layer again.
        shared.presenter?.detach()
        displayView.displayLayer.controlTimebase = AVSampleBufferDisplayView.makeImmediateTimebase()
        // The pump described the frames itself; let the loop decide afresh whether the layer
        // has to be rebuilt for the next one.
        formatDescription = nil
        displayLink.isPaused = !wantsPlayback
    }
}

class MetalView: UIView {
    private let render = MetalRender()
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        if let drawable = metalLayer.nextDrawable() {
            render.clear(drawable: drawable)
        }
    }

    func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize, dovi: DoviMetadata? = nil) {
        metalLayer.drawableSize = size
        metalLayer.pixelFormat = KSOptions.colorPixelFormat(bitDepth: dovi != nil ? 10 : pixelBuffer.bitDepth)
        // The Dolby Vision shader outputs PQ-encoded BT.2020, whatever the buffer claims.
        let colorspace = dovi != nil
            ? KSOptions.colorSpace(ycbcrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            : pixelBuffer.colorspace
        if colorspace != nil, metalLayer.colorspace != colorspace {
            metalLayer.colorspace = colorspace
            KSLog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                if let name = colorspace?.name, name != CGColorSpace.sRGB {
                    #if os(macOS)
                    metalLayer.wantsExtendedDynamicRangeContent = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0 > 1.0
                    #else
                    metalLayer.wantsExtendedDynamicRangeContent = true
                    #endif
                } else {
                    metalLayer.wantsExtendedDynamicRangeContent = false
                }
                KSLog("[video] CAMetalLayer wantsExtendedDynamicRangeContent \(metalLayer.wantsExtendedDynamicRangeContent)")
            }
            #endif
        }
        guard let drawable = metalLayer.nextDrawable() else {
            KSLog("[video] CAMetalLayer not readyForMoreMediaData")
            return
        }
        render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable, dovi: dovi)
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        displayLayer.controlTimebase = AVSampleBufferDisplayView.makeImmediateTimebase()
    }

    /// The timebase upstream gives the layer for display-immediately frames: host clock, from
    /// zero, running. (Bass Player patch: factored out so the layer can be given it back when
    /// timestamped mode ends.)
    static func makeImmediateTimebase() -> CMTimebase? {
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
        return controlTimebase
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) {
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            } else {
                KSLog("[video] AVSampleBufferDisplayLayer not readyForMoreMediaData. video time \(time), controlTime \(displayLayer.timebase.time) ")
                displayLayer.enqueue(sampleBuffer)
            }
            if #available(macOS 11.0, iOS 14, tvOS 14, *) {
                if displayLayer.requiresFlushToResumeDecoding {
                    KSLog("[video] AVSampleBufferDisplayLayer requiresFlushToResumeDecoding so flush")
                    displayLayer.flush()
                }
            }
            if displayLayer.status == .failed {
                KSLog("[video] AVSampleBufferDisplayLayer status failed so flush")
                displayLayer.flush()
                //                    if let error = displayLayer.error as NSError?, error.code == -11847 {
                //                        displayLayer.stopRequestingMediaData()
                //                    }
            }
        }
    }
}

#if os(macOS)
import CoreVideo

class CADisplayLink {
    private let displayLink: CVDisplayLink
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var preferredFramesPerSecond = 60
    @available(macOS 12.0, *)
    public var preferredFrameRateRange: CAFrameRateRange {
        get {
            CAFrameRateRange()
        }
        set {}
    }

    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector: Selector) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.runloop?.perform(selector, target: target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    public init(block: @escaping (() -> Void)) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { _, _, _, _, _ in
            block()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
        CVDisplayLinkSetOutputHandler(displayLink) { _, _, _, _, _ in
            kCVReturnError
        }
    }
}
#endif
