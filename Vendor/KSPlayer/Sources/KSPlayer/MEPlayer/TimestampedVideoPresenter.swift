//
//  TimestampedVideoPresenter.swift
//  KSPlayer
//
//  Bass Player patch (not upstream). The second way `MetalPlayView` can put frames on screen.
//
//  Upstream's loop decides each frame's moment inside a display-link callback on the main run
//  loop, so every main-thread stall longer than one refresh costs a frame. Here a pump on its
//  own queue takes decoded frames in order, wraps them with their media timestamps (no
//  display-immediately attachment) and hands them to the display layer's
//  `AVSampleBufferVideoRenderer` up to `Tuning.lookahead` ahead; the layer's control timebase,
//  which this class keeps on the player's audio clock, decides when each one appears. Once a
//  frame is enqueued, showing it needs nothing from this process's main thread.
//
//  Threads:
//  - Everything marked "pump queue" below is touched only on `queue`: the renderer, the
//    timebase's rate and time, the clock follower, the statistics.
//  - The decoded-frame queue is `MEPlayerItem`'s; its `CircularBuffer` has its own lock.
//  - The audio clock arrives as readings the audio render thread wrote under a lock
//    (`OutputRenderSourceDelegate.audioClockSamples`). Nothing here reads state that only
//    the main thread updates.
//  - The owner calls the `TimestampedPresenting` methods from the main thread (some from any
//    thread); each one hops to `queue`. `detach()` waits for the queue, so when it returns
//    the pump is no longer using the renderer.
//
//  API note (Xcode 27 SDK, checked against its headers 2026-11-21): the renderer's
//  `enqueue`, `isReadyForMoreMediaData`, `flush`, `status`, `error` and
//  `requiresFlushToResumeDecoding` are deprecated *as of* 27.0 in favour of
//  `AVSampleBufferVideoRenderer.Receiver`, which exists only from 27.0 and only through an
//  `AVSampleBufferRenderSynchronizer`. They are what a deployment target below 27 has to use,
//  and the compiler does not warn about them there. `controlTimebase` and
//  `sampleBufferRenderer` on the layer and `loadVideoPerformanceMetrics` are not deprecated.
//

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// What the pump did since the last `takeStats`. Times are in seconds.
public struct TimestampedPresentationStats: Sendable {
    /// Time the pump was running (playing) in this period.
    public var span = 0.0
    /// Frames handed to the renderer with their timestamps.
    public var enqueued = 0
    /// Frames the pump threw away because their time had already passed by more than one
    /// frame when they reached it (the decoder or the pump was behind).
    public var lateDropped = 0
    /// Late frames enqueued anyway because nothing had been enqueued for a quarter of a second.
    public var lateKept = 0
    /// Frames that came out of the decoder with a timestamp at or before the previous one.
    public var outOfOrder = 0
    /// Frames that could not be wrapped in a sample buffer.
    public var unwrappable = 0
    /// How far ahead of its display time a frame was when it was enqueued: smallest, largest.
    public var lookaheadMin = 0.0
    public var lookaheadMax = 0.0
    /// Times the pump stopped feeding because the renderer said it was not ready for more.
    public var notReady = 0
    /// Pump passes, and the longest time between two of them (5 ms when all is well).
    public var passes = 0
    public var longestPumpGap = 0.0
    /// Times the renderer had to be flushed because it failed or asked for a flush.
    public var rendererFlushes = 0
    /// "rendering", "idle" (nothing enqueued yet) or "failed".
    public var rendererStatus = "idle"
    public var rendererError: String?
    /// Seeks, reopens and timestamp discontinuities: the renderer was emptied and the
    /// timebase anchored again.
    public var timelineResets = 0
    /// Audio clock readings used, and video minus audio over the period (positive = picture
    /// ahead of where the audio clock, less `videoDelay`, says it should be).
    public var clockSamples = 0
    public var clockErrorMean: Double {
        clockSamples > 0 ? clockErrorSum / Double(clockSamples) : 0
    }

    var clockErrorSum = 0.0
    /// Largest half-second average of that difference, by size.
    public var clockErrorWorst = 0.0
    /// Changes of the timebase's rate trim, and the largest trim (0.01 = 1 %).
    public var trims = 0
    public var maxTrim = 0.0
    /// Times the timebase was set outright because it was more than `Tuning.resyncThreshold`
    /// from the audio clock.
    public var resyncs = 0
    /// True if the timebase was anchored to the audio clock, false if it runs from the first
    /// picture (no audio track, or the audio has ended).
    public var followsAudio = false
    public var timebaseRate = 0.0
    /// `AVVideoPerformanceMetrics` of the renderer, as changes since the last report. Nil if
    /// the system did not answer within a second.
    public var systemFrames: Int?
    public var systemDropped: Int?
    public var systemCorrupted: Int?
    public var systemOptimized: Int?
    public var systemFrameDelay: Double?
}

/// The part of the presenter `MetalPlayView` can name without an availability check.
protocol TimestampedPresenting: AnyObject {
    func setSource(_ source: OutputRenderSourceDelegate?, options: KSOptions)
    func setPlaying(_ playing: Bool)
    func setRate(_ rate: Double)
    func timelineJumped(removeImage: Bool)
    func showStill()
    func detach()
    func takeStats(completion: @escaping (TimestampedPresentationStats?) -> Void)
}

enum TimestampedPresentation {
    static var isAvailable: Bool {
        if #available(iOS 17.4, tvOS 17.4, macOS 14.4, visionOS 1.1, *) {
            return true
        }
        return false
    }
}

@available(iOS 17.4, tvOS 17.4, macOS 14.4, visionOS 1.1, *)
final class TimestampedVideoPresenter: TimestampedPresenting, @unchecked Sendable {
    enum Tuning {
        /// Real time a frame may be enqueued ahead of its display time. This is what a
        /// main-thread stall cannot hurt, and also what a decoded surface stays pinned for.
        /// WebKit keeps 100–166 ms.
        static let lookahead = 0.150
        static let pumpInterval = DispatchTimeInterval.milliseconds(5)
        /// The renderer's own back-pressure comes first; this only bounds one pass.
        static let maxFramesPerPass = 24
        /// A frame later than one frame duration is dropped, as VLC does; this is the
        /// duration assumed when the frame rate is unknown.
        static let unknownFrameDuration = 0.020
        /// …unless nothing has been enqueued for this long: a slow decoder then still shows
        /// about four pictures a second instead of none.
        static let starvation = 0.25
        /// A timestamp this far behind the previous frame, or this far ahead, is a new
        /// timeline (seek, loop, track change), not a late or early frame.
        static let reorderWindow = 0.5
        static let jumpForward = 1.0
        /// How long a start waits for the audio output's first clock reading before running
        /// from the first picture instead.
        static let audioWait = 0.5
        /// The clock follower: every `controlInterval` the average of (timebase − audio
        /// target) over that interval decides the rate trim.
        static let controlInterval = 0.5
        static let firstControlInterval = 0.15
        static let minimumSamples = 3
        /// Below this the timebase runs at exactly the playback rate.
        static let deadband = 0.002
        /// The trim removes the error with this time constant, up to `maxTrim` (3 %: 30 ms a
        /// second, a change in speed too small to see and no jump in position).
        static let trimTimeConstant = 1.5
        static let maxTrim = 0.03
        /// Beyond this the audio really moved (underrun, a seek that was not announced): set
        /// the timebase outright. Visible as one skip or hold.
        static let resyncThreshold = 0.100
        /// The pump may report the end of the video track once the last frame it enqueued is
        /// due within this time.
        static let finishMargin = 0.05
    }

    /// The display layer's control timebase while this presenter is attached. Host clock
    /// underneath; rate and time are set only on the pump queue.
    let timebase: CMTimebase

    private let queue = DispatchQueue(label: "bassplayer.frame-pump", qos: .userInteractive)
    // Set once; called on the pump queue.
    private let onFrame: @Sendable (VideoVTBFrame, CVPixelBuffer) -> Void
    private let onFormat: @Sendable (Float, Bool, CMFormatDescription) -> Void
    private let onIneligible: @Sendable (String) -> Void

    // MARK: Pump queue only

    private var renderer: AVSampleBufferVideoRenderer?
    private weak var source: OutputRenderSourceDelegate?
    private var options: KSOptions?
    private var timer: DispatchSourceTimer?
    private var detached = true
    /// A frame the layer cannot take was met; the owner is switching back to the display link.
    private var halted = false
    private var playing = false
    /// Playback rate asked for, and the follower's trim on top of it.
    private var rate = 1.0
    private var trim = 0.0
    /// The timebase is running on a clock for the current stretch of playback.
    private var anchored = false
    /// The timebase's time means something (a still was shown or it was anchored) since the
    /// renderer was last emptied.
    private var timelineValid = false
    private var followsAudio = false
    private var lastPTS: Double?
    private var lastEnqueueHost = 0.0
    /// Audio clock readings older than this belong to an earlier stretch (before the last
    /// start, seek, anchor or resync) and are ignored.
    private var epochHost = 0.0
    private var audioCursor = UInt64(0)
    private var freshSample: AudioClockSample?
    private var errorSum = 0.0
    private var errorCount = 0
    private var lastControlHost = 0.0
    private var controlInterval = Tuning.firstControlInterval
    private var formatDescription: CMVideoFormatDescription?
    private var lastFps = Float(-1)
    private var lastIsDovi = false
    private var stats = TimestampedPresentationStats()
    private var runningSince: Double?
    private var lastPassHost = 0.0
    private var hasLookahead = false
    private var metricsBase: (frames: Int, dropped: Int, corrupted: Int, optimized: Int, delay: Double)?

    init?(onFrame: @escaping @Sendable (VideoVTBFrame, CVPixelBuffer) -> Void,
          onFormat: @escaping @Sendable (Float, Bool, CMFormatDescription) -> Void,
          onIneligible: @escaping @Sendable (String) -> Void)
    {
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
        guard let created else {
            return nil
        }
        CMTimebaseSetTime(created, time: .zero)
        CMTimebaseSetRate(created, rate: 0)
        timebase = created
        self.onFrame = onFrame
        self.onFormat = onFormat
        self.onIneligible = onIneligible
    }

    // MARK: Owner's side (each call hops to the pump queue)

    /// Start presenting on `renderer`, whose layer already has `timebase` as its control
    /// timebase. Main thread.
    func attach(renderer: AVSampleBufferVideoRenderer, source: OutputRenderSourceDelegate?, options: KSOptions, rate: Double, playing: Bool) {
        queue.async {
            self.renderer = renderer
            self.source = source
            self.options = options
            self.rate = rate > 0 ? rate : 1
            self.detached = false
            self.halted = false
            self.audioCursor = 0
            self.formatDescription = nil
            self.lastFps = -1
            self.metricsBase = nil
            self.playing = false
            self.resetTimeline(removeImage: false)
            self.stats = TimestampedPresentationStats()
            self.hasLookahead = false
            self.applyPlaying(playing)
        }
    }

    /// Stop and let go of the renderer. Returns once the pump queue has done so.
    func detach() {
        queue.sync {
            guard !self.detached else { return }
            self.applyPlaying(false)
            self.detached = true
            self.renderer?.flush()
            CMTimebaseSetRate(self.timebase, rate: 0)
            self.renderer = nil
            self.source = nil
            self.options = nil
            self.anchored = false
            self.timelineValid = false
            self.lastPTS = nil
        }
    }

    /// The player opened another item (or the same one again): a new frame queue and a new
    /// audio clock. Any thread.
    func setSource(_ source: OutputRenderSourceDelegate?, options: KSOptions) {
        queue.async {
            guard !self.detached else { return }
            let changed = self.source !== source
            self.source = source
            self.options = options
            if changed {
                self.audioCursor = 0
                self.resetTimeline(removeImage: false)
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async {
            self.applyPlaying(playing)
        }
    }

    func setRate(_ rate: Double) {
        queue.async {
            let rate = rate > 0 ? rate : 1
            guard rate != self.rate else { return }
            self.rate = rate
            guard !self.detached, self.playing, self.anchored else { return }
            self.trim = 0
            CMTimebaseSetRate(self.timebase, rate: rate)
            self.restartFollower(hostNow: CACurrentMediaTime())
        }
    }

    /// A seek is starting, or the picture is to be cleared: what was enqueued ahead belongs to
    /// the old position. Any thread.
    func timelineJumped(removeImage: Bool) {
        queue.async {
            guard !self.detached else { return }
            self.resetTimeline(removeImage: removeImage)
        }
    }

    /// Show the first decoded frame while not playing (what the loop's `readNextFrame` does).
    func showStill() {
        queue.async {
            guard !self.detached, !self.halted, !self.playing else { return }
            autoreleasepool {
                self.showStillIfNeeded()
            }
        }
    }

    /// The statistics since the last call, on the main queue. The system's own counts are
    /// asked for first; if they do not arrive within a second the rest is delivered alone.
    func takeStats(completion: @escaping (TimestampedPresentationStats?) -> Void) {
        queue.async {
            let hostNow = CACurrentMediaTime()
            var snapshot = self.stats
            self.stats = TimestampedPresentationStats()
            self.hasLookahead = false
            if let since = self.runningSince {
                snapshot.span += hostNow - since
                self.runningSince = hostNow
            }
            snapshot.followsAudio = self.followsAudio
            snapshot.timebaseRate = CMTimebaseGetRate(self.timebase)
            guard !self.detached, let renderer = self.renderer else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            switch renderer.status {
            case .rendering:
                snapshot.rendererStatus = "rendering"
            case .failed:
                snapshot.rendererStatus = "failed"
            default:
                snapshot.rendererStatus = "idle"
            }
            if let error = renderer.error as NSError? {
                snapshot.rendererError = "\(error.domain) \(error.code)"
            }
            let pending = PendingStats(snapshot)
            let deliver: @Sendable (AVVideoPerformanceMetrics?) -> Void = { metrics in
                // Pump queue.
                guard !pending.delivered else { return }
                pending.delivered = true
                if let metrics {
                    let now = (frames: metrics.totalNumberOfFrames, dropped: metrics.numberOfDroppedFrames,
                               corrupted: metrics.numberOfCorruptedFrames,
                               optimized: metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
                               delay: metrics.totalAccumulatedFrameDelay)
                    // The counters restart when the renderer is flushed or replaced.
                    let base = self.metricsBase.flatMap { $0.frames <= now.frames && $0.dropped <= now.dropped ? $0 : nil }
                    pending.stats.systemFrames = now.frames - (base?.frames ?? 0)
                    pending.stats.systemDropped = now.dropped - (base?.dropped ?? 0)
                    pending.stats.systemCorrupted = now.corrupted - (base?.corrupted ?? 0)
                    pending.stats.systemOptimized = now.optimized - (base?.optimized ?? 0)
                    pending.stats.systemFrameDelay = now.delay - (base?.delay ?? 0)
                    self.metricsBase = now
                }
                let result = pending.stats
                DispatchQueue.main.async { completion(result) }
            }
            renderer.loadVideoPerformanceMetrics { metrics in
                self.queue.async { deliver(metrics) }
            }
            self.queue.asyncAfter(deadline: .now() + 1) { deliver(nil) }
        }
    }

    private final class PendingStats: @unchecked Sendable {
        var stats: TimestampedPresentationStats
        var delivered = false
        init(_ stats: TimestampedPresentationStats) {
            self.stats = stats
        }
    }

    // MARK: Pump queue: state changes

    private func applyPlaying(_ newValue: Bool) {
        guard newValue != playing else { return }
        playing = newValue
        guard !detached else { return }
        let hostNow = CACurrentMediaTime()
        if newValue {
            // Every start anchors afresh: the audio output is starting too, and its first
            // reading says where it really is. Frames already enqueued stay enqueued.
            anchored = false
            freshSample = nil
            epochHost = hostNow
            trim = 0
            lastPassHost = 0
            runningSince = hostNow
            startTimer()
        } else {
            stopTimer()
            CMTimebaseSetRate(timebase, rate: 0)
            anchored = false
            trim = 0
            if let since = runningSince {
                stats.span += hostNow - since
            }
            runningSince = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: Tuning.pumpInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            autoreleasepool {
                self?.pump()
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Empty the renderer and forget the timeline. The next start (or the next pass, if
    /// playing) anchors again.
    private func resetTimeline(removeImage: Bool) {
        if let renderer {
            if removeImage {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            } else {
                renderer.flush()
            }
        }
        CMTimebaseSetRate(timebase, rate: 0)
        anchored = false
        timelineValid = false
        followsAudio = false
        lastPTS = nil
        trim = 0
        freshSample = nil
        epochHost = CACurrentMediaTime()
        stats.timelineResets += 1
    }

    private func restartFollower(hostNow: Double) {
        errorSum = 0
        errorCount = 0
        lastControlHost = hostNow
        controlInterval = Tuning.firstControlInterval
        // Readings taken before this moment were measured against another anchor or rate.
        epochHost = hostNow
        freshSample = nil
    }

    // MARK: Pump queue: one pass

    private func pump() {
        guard !detached, !halted, playing, let renderer, let source else { return }
        let hostNow = CACurrentMediaTime()
        if lastPassHost > 0 {
            stats.longestPumpGap = max(stats.longestPumpGap, hostNow - lastPassHost)
        }
        lastPassHost = hostNow
        stats.passes += 1

        // The documented recovery: a failed renderer, or one whose decoder resources were
        // taken away, resumes after a flush. What was enqueued is gone; carry on from here.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            stats.rendererFlushes += 1
        }

        let clock = source.audioClockSamples(after: audioCursor)
        audioCursor = clock.cursor
        let delay = options?.videoDelay ?? 0
        if let newest = clock.samples.last(where: { $0.host >= epochHost }) {
            freshSample = newest
        }

        if !anchored {
            anchor(isAudioMaster: clock.isMaster, delay: delay, hostNow: hostNow)
        } else {
            follow(clock, delay: delay, hostNow: hostNow)
        }
        guard anchored, !halted else { return }
        feed(renderer: renderer, source: source, hostNow: hostNow)
    }

    /// Put the timebase on a clock: the audio clock if there is one (its newest reading,
    /// carried forward to now, less `videoDelay`), otherwise the first picture's timestamp.
    private func anchor(isAudioMaster: Bool, delay: Double, hostNow: Double) {
        if isAudioMaster {
            if let sample = freshSample {
                let target = sample.media + (hostNow - sample.host) * rate - delay
                CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 1_000_000))
                CMTimebaseSetRate(timebase, rate: rate)
                anchored = true
                timelineValid = true
                followsAudio = true
                restartFollower(hostNow: hostNow)
                return
            }
            if hostNow - epochHost < Tuning.audioWait {
                // The audio output has not reported yet. Keep a picture up meanwhile.
                showStillIfNeeded()
                return
            }
        }
        showStillIfNeeded()
        guard timelineValid else { return } // no frame decoded yet
        CMTimebaseSetRate(timebase, rate: rate)
        anchored = true
        followsAudio = false
        restartFollower(hostNow: hostNow)
    }

    /// Keep the timebase on the audio clock without stepping: measure, average, trim the rate.
    private func follow(_ clock: AudioClockSamples, delay: Double, hostNow: Double) {
        let effectiveRate = rate * (1 + trim)
        if clock.isMaster, !clock.samples.isEmpty {
            let timebaseNow = CMTimebaseGetTime(timebase).seconds
            for sample in clock.samples where sample.host >= epochHost {
                // Where the timebase was when the audio output took this reading.
                let timebaseThen = timebaseNow - (hostNow - sample.host) * effectiveRate
                let error = timebaseThen - (sample.media - delay)
                errorSum += error
                errorCount += 1
                stats.clockErrorSum += error
                stats.clockSamples += 1
            }
        }
        guard hostNow - lastControlHost >= controlInterval else { return }
        let count = errorCount
        let mean = count > 0 ? errorSum / Double(count) : 0
        errorSum = 0
        errorCount = 0
        lastControlHost = hostNow
        controlInterval = Tuning.controlInterval
        guard clock.isMaster, count >= Tuning.minimumSamples else {
            // Nothing to follow (no audio, or its output is not running): plain playback rate.
            setTrim(0)
            return
        }
        followsAudio = true
        if abs(mean) > abs(stats.clockErrorWorst) {
            stats.clockErrorWorst = mean
        }
        if abs(mean) >= Tuning.resyncThreshold {
            let corrected = CMTimebaseGetTime(timebase).seconds - mean
            CMTimebaseSetTime(timebase, time: CMTime(seconds: corrected, preferredTimescale: 1_000_000))
            trim = 0
            CMTimebaseSetRate(timebase, rate: rate)
            stats.resyncs += 1
            restartFollower(hostNow: hostNow)
            controlInterval = Tuning.controlInterval
        } else if abs(mean) <= Tuning.deadband {
            setTrim(0)
        } else {
            setTrim(max(-Tuning.maxTrim, min(Tuning.maxTrim, -mean / Tuning.trimTimeConstant)))
        }
    }

    private func setTrim(_ newTrim: Double) {
        guard abs(newTrim - trim) >= 0.0005 || (newTrim == 0 && trim != 0) else { return }
        trim = newTrim
        CMTimebaseSetRate(timebase, rate: rate * (1 + newTrim))
        stats.trims += 1
        stats.maxTrim = max(stats.maxTrim, abs(newTrim))
    }

    private enum Verdict {
        case none
        case enqueue
        case late
        case lateKept
        case outOfOrder
        case wait
        case jump
        case ineligible(String)
    }

    /// Why the display layer cannot take this frame, if it cannot.
    private static func ineligibility(of frame: VideoVTBFrame) -> String? {
        if frame.dovi?.needsMapping == true {
            return "Dolby Vision profile 5 needs the Metal shader"
        }
        if frame.corePixelBuffer?.cvPixelBuffer == nil {
            return "software frames in a format the display layer cannot take"
        }
        return nil
    }

    /// Hand over every frame that is due within the lookahead, oldest first.
    private func feed(renderer: AVSampleBufferVideoRenderer, source: OutputRenderSourceDelegate, hostNow: Double) {
        let effectiveRate = rate * (1 + trim)
        guard effectiveRate > 0 else { return }
        var taken = 0
        while taken < Tuning.maxFramesPerPass {
            // Back-pressure: the renderer says when it has enough; never enqueue past that.
            guard renderer.isReadyForMoreMediaData else {
                stats.notReady += 1
                return
            }
            let timebaseNow = CMTimebaseGetTime(timebase).seconds
            let last = lastPTS
            let starving = hostNow - lastEnqueueHost > Tuning.starvation
            let mayFinish = last.map { $0 <= timebaseNow + Tuning.finishMargin } ?? true
            var verdict = Verdict.none
            // The closure runs under the frame queue's lock and only decides.
            let frame = source.getVideoOutputRender(mayFinish: mayFinish) { candidate, _ in
                if let reason = Self.ineligibility(of: candidate) {
                    verdict = .ineligible(reason)
                    return false
                }
                let pts = candidate.seconds
                if let last {
                    if pts < last - Tuning.reorderWindow || pts > last + Tuning.jumpForward {
                        verdict = .jump
                        return false
                    }
                    if pts <= last {
                        verdict = .outOfOrder
                        return true
                    }
                }
                if (pts - timebaseNow) / effectiveRate > Tuning.lookahead {
                    verdict = .wait
                    return false
                }
                let duration = candidate.fps > 0 ? 1 / Double(candidate.fps) : Tuning.unknownFrameDuration
                if pts + duration < timebaseNow {
                    verdict = starving ? .lateKept : .late
                    return true
                }
                verdict = .enqueue
                return true
            }
            switch verdict {
            case .none, .wait:
                return
            case let .ineligible(reason):
                // Left in the queue for the display-link loop, which can draw it with Metal.
                halted = true
                stopTimer()
                onIneligible(reason)
                return
            case .jump:
                // A new timeline nobody announced (loop, track change): start over on it.
                resetTimeline(removeImage: false)
                return
            case .outOfOrder:
                stats.outOfOrder += 1
            case .late:
                stats.lateDropped += 1
                lastPTS = frame?.seconds ?? lastPTS
            case .enqueue, .lateKept:
                guard let frame else { return }
                if case .lateKept = verdict {
                    stats.lateKept += 1
                }
                enqueue(frame, renderer: renderer, source: source, lookahead: (frame.seconds - timebaseNow) / effectiveRate, hostNow: hostNow)
            }
            taken += 1
        }
    }

    /// While not running: put the first decoded frame on screen and start the timeline at it.
    private func showStillIfNeeded() {
        guard !timelineValid, !halted, let renderer, let source, renderer.isReadyForMoreMediaData else { return }
        var reason: String?
        let frame = source.getVideoOutputRender(mayFinish: false) { candidate, _ in
            reason = Self.ineligibility(of: candidate)
            return reason == nil
        }
        if let reason {
            halted = true
            stopTimer()
            onIneligible(reason)
            return
        }
        guard let frame else { return }
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseSetTime(timebase, time: frame.cmtime)
        timelineValid = true
        enqueue(frame, renderer: renderer, source: source, lookahead: 0, hostNow: CACurrentMediaTime())
    }

    private func enqueue(_ frame: VideoVTBFrame, renderer: AVSampleBufferVideoRenderer, source: OutputRenderSourceDelegate, lookahead: Double, hostNow: Double) {
        lastPTS = frame.seconds
        guard let pixelBuffer = frame.corePixelBuffer?.cvPixelBuffer else {
            stats.unwrappable += 1
            return
        }
        // Same aspect handling as the display-link loop (one eye of a packed 3D frame).
        let par = pixelBuffer.size
        let sar = pixelBuffer.aspectRatio
        if let dar = options?.customizeDar(sar: sar, par: par) {
            pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
        }
        var formatChanged = false
        if let current = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: pixelBuffer) {
            // unchanged
        } else {
            formatDescription = pixelBuffer.formatDescription
            formatChanged = true
        }
        guard let formatDescription else {
            stats.unwrappable += 1
            return
        }
        // The frame's own media time and no display-immediately attachment: the timebase
        // decides when it appears.
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.cmtime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription,
                                                 sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else {
            stats.unwrappable += 1
            return
        }
        renderer.enqueue(sampleBuffer)
        lastEnqueueHost = hostNow
        stats.enqueued += 1
        if hasLookahead {
            stats.lookaheadMin = min(stats.lookaheadMin, lookahead)
            stats.lookaheadMax = max(stats.lookaheadMax, lookahead)
        } else {
            hasLookahead = true
            stats.lookaheadMin = lookahead
            stats.lookaheadMax = lookahead
        }
        source.setVideoEnqueued(time: frame.cmtime, position: frame.position)
        onFrame(frame, pixelBuffer)
        if formatChanged || frame.fps != lastFps || frame.isDovi != lastIsDovi {
            lastFps = frame.fps
            lastIsDovi = frame.isDovi
            onFormat(frame.fps, frame.isDovi, formatDescription)
        }
    }
}
