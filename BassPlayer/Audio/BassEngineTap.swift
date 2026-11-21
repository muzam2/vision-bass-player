import AVFoundation
import KSPlayer

/// Feeds `BassExtractor` from KSPlayer's AVAudioEngine (FFmpeg backend).
///
/// KSPlayer's `AudioEnginePlayer` exposes its engine, so we:
///   1. install a tap on `mainMixerNode` (post-mix, pre-output) → BassExtractor
///   2. set the lead on KSPlayer's own delay node (mixer → delay → output, wired by KSPlayer
///      when audio starts) so the headset's audio (and, via `KSOptions.videoDelay`, the
///      picture) plays `leadMs` later than the bass packets leave. That cancels the BLE +
///      receiver latency.
///
/// Works for stereo and multichannel (5.1/7.1) graphs: the tap sees whatever channel layout the
/// mixer runs at, and `BassExtractor` picks the LFE channel when there is one.
final class BassEngineTap {
    let extractor: BassExtractor
    private weak var engine: AVAudioEngine?
    private(set) var tapInstalled = false
    private var reportedWrongOutput = false
    private weak var enginePlayer: AudioEnginePlayer?
    private var reportedNoLead = false

    /// The lead that is really applied to the headset's audio, so the picture can be delayed by
    /// the same amount (0 when the audio format has no lead delay in its graph).
    var effectiveLeadSeconds: Double {
        guard let enginePlayer, enginePlayer.leadDelayInGraph else { return 0 }
        return Double(leadMs) / 1000
    }

    /// Milliseconds the main mix is held back so the bass can arrive in time. 0 = off.
    var leadMs: Int = 0 {
        didSet { applyLead() }
    }

    init(extractor: BassExtractor) {
        self.extractor = extractor
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
        self.engine = enginePlayer.engine
        if self.enginePlayer !== enginePlayer {
            self.enginePlayer = enginePlayer
            reportedNoLead = false
        }
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
        enginePlayer?.leadDelay = 0
        enginePlayer = nil
        engine = nil
    }

    private func installTapIfNeeded() {
        guard let engine, !tapInstalled else { return }
        // Before KSPlayer connects its graph the mixer reports a placeholder (44.1 kHz stereo);
        // installing then meant the extractor decimated 48 kHz 5.1 buffers with the wrong ratio
        // (packets 9 % too fast). Wait for the running graph, and re-read the format from every
        // buffer anyway: KSPlayer rebuilds the graph when the track's format changes.
        guard engine.isRunning else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }   // graph not connected yet
        extractor.configure(sampleRate: format.sampleRate, channels: Int(format.channelCount), interleaved: format.isInterleaved)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [extractor] buffer, _ in
            let f = buffer.format
            if f.sampleRate != extractor.sampleRate || Int(f.channelCount) != extractor.channels || f.isInterleaved != extractor.interleaved {
                extractor.configure(sampleRate: f.sampleRate, channels: Int(f.channelCount), interleaved: f.isInterleaved)
                DiagLog.log("tap format now \(Int(f.sampleRate)) Hz, \(f.channelCount) ch, \(f.isInterleaved ? "interleaved" : "planar")", "bass")
            }
            extractor.process(bufferList: buffer.mutableAudioBufferList, frames: Int(buffer.frameLength))
        }
        tapInstalled = true
        DiagLog.log("tap installed on the mixer: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.isInterleaved ? "interleaved" : "planar")", "bass")
    }

    /// Hand the lead to KSPlayer's own delay node (wired once, in its `prepare`). Never changes
    /// the engine's graph: doing that on a running engine crashed the app (2026-11-21).
    private func applyLead() {
        guard let enginePlayer else { return }
        enginePlayer.leadDelay = Double(leadMs) / 1000
        if leadMs > 0, !enginePlayer.leadDelayInGraph, !reportedNoLead {
            reportedNoLead = true
            DiagLog.log("lead \(leadMs) ms requested but this audio format has no lead delay; picture not delayed either", "bass")
        }
    }
}
