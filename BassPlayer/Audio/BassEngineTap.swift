import AVFoundation
import KSPlayer

/// Feeds `BassExtractor` from KSPlayer's AVAudioEngine (FFmpeg backend).
///
/// KSPlayer's `AudioEnginePlayer` exposes its engine, so we:
///   1. install a tap on `mainMixerNode` (post-mix, pre-output) → BassExtractor
///   2. optionally insert an `AVAudioUnitDelay` between the mixer and the output so the
///      headset's own audio (and, via `KSOptions.videoDelay`, the picture) plays `leadMs` later
///      than the bass packets leave. That cancels the BLE + receiver latency.
///
/// Works for stereo and multichannel (5.1/7.1) graphs: the tap sees whatever channel layout the
/// mixer runs at, and `BassExtractor` picks the LFE channel when there is one.
final class BassEngineTap {
    let extractor: BassExtractor
    private weak var engine: AVAudioEngine?
    private(set) var tapInstalled = false
    private var reportedWrongOutput = false
    private let delayUnit = AVAudioUnitDelay()
    private var delayInserted = false

    /// Milliseconds the main mix is held back so the bass can arrive in time. 0 = off.
    var leadMs: Int = 0 {
        didSet { applyLead() }
    }

    init(extractor: BassExtractor) {
        self.extractor = extractor
        delayUnit.feedback = 0
        delayUnit.wetDryMix = 100
        delayUnit.lowPassCutoff = 20_000
    }

    /// Call once the player reports ready/playing. Safe to call repeatedly.
    func attach(to output: AudioOutput) {
        guard let enginePlayer = output as? AudioEnginePlayer else {
            if !reportedWrongOutput {
                reportedWrongOutput = true
                DiagLog.log("audio output is \(type(of: output)), not AudioEnginePlayer — no bass tap possible", "bass")
            }
            return
        }
        let engine = enginePlayer.engine
        self.engine = engine
        installTapIfNeeded()
        applyLead()
    }

    func detach() {
        if let engine, tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            let s = extractor.stats()
            DiagLog.log("tap removed after \(s.buffers) buffers / \(s.packets) packets", "bass")
        }
        tapInstalled = false
        delayInserted = false
        engine = nil
    }

    private func installTapIfNeeded() {
        guard let engine, !tapInstalled else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }   // graph not connected yet
        extractor.configure(sampleRate: format.sampleRate, channels: Int(format.channelCount), interleaved: format.isInterleaved)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [extractor] buffer, _ in
            extractor.process(bufferList: buffer.mutableAudioBufferList, frames: Int(buffer.frameLength))
        }
        tapInstalled = true
        DiagLog.log("tap installed on the mixer: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.isInterleaved ? "interleaved" : "planar"), engine running: \(engine.isRunning)", "bass")
    }

    /// Rewire mixer → delay → output when a lead is requested; restore the direct link when not.
    private func applyLead() {
        guard let engine else { return }
        let mixer = engine.mainMixerNode
        let output = engine.outputNode
        let wantDelay = leadMs > 0
        delayUnit.delayTime = Double(leadMs) / 1000

        if wantDelay && !delayInserted {
            let format = mixer.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return }
            let wasRunning = engine.isRunning
            engine.attach(delayUnit)
            engine.disconnectNodeOutput(mixer)
            engine.connect(mixer, to: delayUnit, format: format)
            engine.connect(delayUnit, to: output, format: format)
            delayInserted = true
            if wasRunning { try? engine.start() }
        } else if !wantDelay && delayInserted {
            let format = mixer.outputFormat(forBus: 0)
            let wasRunning = engine.isRunning
            engine.disconnectNodeOutput(mixer)
            engine.disconnectNodeOutput(delayUnit)
            engine.detach(delayUnit)
            engine.connect(mixer, to: output, format: format)
            delayInserted = false
            if wasRunning { try? engine.start() }
        }
    }
}
